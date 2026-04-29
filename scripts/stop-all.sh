#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$ROOT/run"

stop_by_pid_file() {
  local name="$1"
  local pid_file="$2"

  if [[ ! -f "$pid_file" ]]; then
    echo "$name: pid file not found, skip."
    return
  fi

  local pid_text
  pid_text="$(tr -d '[:space:]' < "$pid_file" || true)"
  if [[ -z "$pid_text" ]] || ! [[ "$pid_text" =~ ^[0-9]+$ ]]; then
    echo "$name: invalid pid ($pid_text), skip."
    rm -f "$pid_file"
    return
  fi

  if kill -0 "$pid_text" >/dev/null 2>&1; then
    kill "$pid_text" >/dev/null 2>&1 || true
    sleep 0.2
    kill -9 "$pid_text" >/dev/null 2>&1 || true
    echo "$name: stopped PID=$pid_text"
  else
    echo "$name: process missing (PID=$pid_text)"
  fi

  rm -f "$pid_file"
}

stop_by_pid_file "UI" "$RUN_DIR/ui.pid"
stop_by_pid_file "Gateway" "$RUN_DIR/gateway.pid"
stop_by_pid_file "ZLM" "$RUN_DIR/zlm.pid"

RUNTIME_FILE="$RUN_DIR/runtime.json"
if [[ -f "$RUNTIME_FILE" ]]; then
  rm -f "$RUNTIME_FILE"
  echo "Runtime file removed: $RUNTIME_FILE"
fi
