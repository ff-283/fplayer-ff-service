#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT/run"
LOG_DIR="$ROOT/logs"
mkdir -p "$RUN_DIR" "$LOG_DIR"

resolve_zlm_linux_dir() {
  if [[ -d "$ROOT/3rd/zlm/linux" ]]; then
    echo "$ROOT/3rd/zlm/linux"
    return
  fi
  if [[ -d "$ROOT/3rd/zlm/Linux" ]]; then
    echo "$ROOT/3rd/zlm/Linux"
    return
  fi
  echo ""
}

ZLM_DIR="$(resolve_zlm_linux_dir)"
[[ -n "$ZLM_DIR" ]] || { echo "ZLM Linux directory not found: $ROOT/3rd/zlm/{linux|Linux}"; exit 1; }
ZLM_EXE="$ZLM_DIR/MediaServer"
ZLM_CFG="$ZLM_DIR/config.ini"
ZLM_RUNTIME_CFG="$RUN_DIR/zlm.runtime.ini"
GATEWAY_DIR="$ROOT/gateway"
GATEWAY_EXE="$GATEWAY_DIR/bin/gateway"
SKIP_UI="${SERVICE_SKIP_UI:-0}"

[[ -f "$ZLM_EXE" ]] || { echo "ZLM executable not found: $ZLM_EXE"; exit 1; }
[[ -f "$ZLM_CFG" ]] || { echo "ZLM config not found: $ZLM_CFG"; exit 1; }
chmod +x "$ZLM_EXE" || { echo "Failed to set executable permission: $ZLM_EXE"; exit 1; }

port_in_use() {
  local p="$1"
  ss -ltn "( sport = :$p )" 2>/dev/null | awk -v port=":$p" 'NR>1 { if (index($4, port) > 0) found=1 } END { exit found ? 0 : 1 }'
}

get_free_port() {
  local preferred="${1:-0}"
  if [[ "$preferred" -gt 0 ]] && ! port_in_use "$preferred"; then
    echo "$preferred"
    return
  fi
  for _ in {1..80}; do
    local candidate
    candidate="$(shuf -i 20000-45000 -n 1)"
    if ! port_in_use "$candidate"; then
      echo "$candidate"
      return
    fi
  done
  echo "Failed to find free TCP port" >&2
  exit 1
}

set_ini_key_value() {
  local src="$1"
  local dst="$2"
  local section="$3"
  local key="$4"
  local value="$5"
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section = 0 }
    /^\s*\[[^]]+\]\s*$/ {
      in_section = ($0 == "[" section "]")
      print
      next
    }
    {
      if (in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        print key "=" value
      } else {
        print
      }
    }
  ' "$src" > "$dst"
}

test_gateway_health() {
  local port="$1"
  for _ in {1..15}; do
    if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

get_lan_ipv4() {
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

ZLM_RTMP_PORT="$(get_free_port 1935)"
ZLM_HTTP_PORT="$(get_free_port 8080)"
ZLM_HTTPS_PORT="$(get_free_port 8443)"
ZLM_RTSP_PORT="$(get_free_port 8554)"
GATEWAY_PORT="-1"

cp "$ZLM_CFG" "$ZLM_RUNTIME_CFG"
tmp_cfg="$RUN_DIR/zlm.runtime.tmp.ini"
set_ini_key_value "$ZLM_RUNTIME_CFG" "$tmp_cfg" "http" "port" "$ZLM_HTTP_PORT" && mv "$tmp_cfg" "$ZLM_RUNTIME_CFG"
set_ini_key_value "$ZLM_RUNTIME_CFG" "$tmp_cfg" "http" "sslport" "$ZLM_HTTPS_PORT" && mv "$tmp_cfg" "$ZLM_RUNTIME_CFG"
set_ini_key_value "$ZLM_RUNTIME_CFG" "$tmp_cfg" "rtmp" "port" "$ZLM_RTMP_PORT" && mv "$tmp_cfg" "$ZLM_RUNTIME_CFG"
set_ini_key_value "$ZLM_RUNTIME_CFG" "$tmp_cfg" "rtsp" "port" "$ZLM_RTSP_PORT" && mv "$tmp_cfg" "$ZLM_RUNTIME_CFG"

nohup "$ZLM_EXE" -c "$ZLM_RUNTIME_CFG" >"$LOG_DIR/zlm.log" 2>"$LOG_DIR/zlm.err.log" &
ZLM_PID="$!"
echo "$ZLM_PID" > "$RUN_DIR/zlm.pid"

if [[ ! -x "$GATEWAY_EXE" ]] && ! command -v go >/dev/null 2>&1; then
  echo "go command not found and gateway binary not found. Please install Go or build gateway/bin/gateway."
  exit 1
fi

GW_PID=""
for attempt in {0..7}; do
  preferred=0
  if [[ "$attempt" -eq 0 ]]; then
    preferred=9000
  fi
  candidate_port="$(get_free_port "$preferred")"

  if [[ -x "$GATEWAY_EXE" ]]; then
    (
      cd "$GATEWAY_DIR"
      ZLM_RTMP_PORT="$ZLM_RTMP_PORT" \
      ZLM_HTTP_PORT="$ZLM_HTTP_PORT" \
      SERVICE_GATEWAY_PORT="$candidate_port" \
      SERVICE_LOG_DIR="$LOG_DIR" \
      nohup "$GATEWAY_EXE" >"$LOG_DIR/gateway.log" 2>"$LOG_DIR/gateway.err.log" &
      echo $! > "$RUN_DIR/gateway.pid"
    )
  else
    (
      cd "$GATEWAY_DIR"
      ZLM_RTMP_PORT="$ZLM_RTMP_PORT" \
      ZLM_HTTP_PORT="$ZLM_HTTP_PORT" \
      SERVICE_GATEWAY_PORT="$candidate_port" \
      SERVICE_LOG_DIR="$LOG_DIR" \
      nohup go run . >"$LOG_DIR/gateway.log" 2>"$LOG_DIR/gateway.err.log" &
      echo $! > "$RUN_DIR/gateway.pid"
    )
  fi

  GW_PID="$(tr -d '[:space:]' < "$RUN_DIR/gateway.pid")"
  if test_gateway_health "$candidate_port"; then
    GATEWAY_PORT="$candidate_port"
    break
  fi
  kill -9 "$GW_PID" >/dev/null 2>&1 || true
  rm -f "$RUN_DIR/gateway.pid"
done

if [[ "$GATEWAY_PORT" -le 0 ]] || [[ -z "$GW_PID" ]]; then
  echo "gateway failed to start on dynamic ports. See logs/gateway.err.log"
  exit 1
fi

LAN_IP="$(get_lan_ipv4)"
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="127.0.0.1"
fi
UI_GATEWAY_URL="http://$LAN_IP:$GATEWAY_PORT"

if [[ "$SKIP_UI" != "1" ]]; then
  command -v npm >/dev/null 2>&1 || { echo "npm command not found. Please install Node.js."; exit 1; }
  (
    cd "$ROOT/ui"
    SERVICE_GATEWAY_URL="$UI_GATEWAY_URL" \
    SERVICE_MANAGED_MODE="1" \
    nohup npm start >"$LOG_DIR/ui.log" 2>"$LOG_DIR/ui.err.log" &
    echo $! > "$RUN_DIR/ui.pid"
  )
fi

cat > "$RUN_DIR/runtime.json" <<EOF
{
  "startedAt": "$(date +%Y-%m-%dT%H:%M:%S)",
  "gateway": {
    "host": "$LAN_IP",
    "port": $GATEWAY_PORT,
    "url": "http://$LAN_IP:$GATEWAY_PORT"
  },
  "zlm": {
    "rtmpPort": $ZLM_RTMP_PORT,
    "httpPort": $ZLM_HTTP_PORT,
    "httpsPort": $ZLM_HTTPS_PORT,
    "rtspPort": $ZLM_RTSP_PORT
  },
  "endpoints": {
    "publishRtmp": "rtmp://127.0.0.1:$ZLM_RTMP_PORT/live/stream001",
    "playHttpFlv": "http://127.0.0.1:$ZLM_HTTP_PORT/live/stream001.flv"
  }
}
EOF

echo "Started:"
echo "  ZLM:      PID=$ZLM_PID"
echo "  Gateway:  PID=$GW_PID"
if [[ "$SKIP_UI" != "1" ]]; then
  UI_PID="$(tr -d '[:space:]' < "$RUN_DIR/ui.pid")"
  echo "  UI:       PID=$UI_PID"
fi
echo
echo "Service endpoints:"
echo "  Gateway:  http://$LAN_IP:$GATEWAY_PORT"
echo "  RTMP:     rtmp://$LAN_IP:$ZLM_RTMP_PORT/live/stream001"
echo "  HTTP-FLV: http://$LAN_IP:$ZLM_HTTP_PORT/live/stream001.flv"
echo
echo "Runtime file: $RUN_DIR/runtime.json"
