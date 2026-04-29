#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

check_cmd() {
  local cmd="$1"
  local hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[FAIL] Missing command: $cmd ($hint)"
    return 1
  fi
  echo "[OK] command: $cmd -> $(command -v "$cmd")"
}

echo "Checking Linux build/runtime environment..."

check_cmd go "install Go 1.22+"
check_cmd node "install Node.js 20 LTS+"
check_cmd npm "install npm 10+"
check_cmd curl "required by start-all.sh health check"
check_cmd ss "required by start-all.sh port probing (iproute2)"

ZLM_DIR="$(resolve_zlm_linux_dir)"
if [[ -z "$ZLM_DIR" ]]; then
  echo "[FAIL] Missing directory: $ROOT/3rd/zlm/linux or $ROOT/3rd/zlm/Linux"
  exit 1
fi
echo "[OK] ZLM directory: $ZLM_DIR"

ZLM_EXE="$ZLM_DIR/MediaServer"
ZLM_CFG="$ZLM_DIR/config.ini"
[[ -f "$ZLM_EXE" ]] || { echo "[FAIL] Missing file: $ZLM_EXE"; exit 1; }
[[ -f "$ZLM_CFG" ]] || { echo "[FAIL] Missing file: $ZLM_CFG"; exit 1; }

chmod +x "$ZLM_EXE" || { echo "[FAIL] Cannot set executable permission: $ZLM_EXE"; exit 1; }
echo "[OK] MediaServer executable permission ensured: $ZLM_EXE"

echo "[OK] Linux env check passed."
