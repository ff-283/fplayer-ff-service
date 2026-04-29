#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_DIR="$ROOT/gateway"
GATEWAY_BIN="$GATEWAY_DIR/bin"
KERNEL_DIR="$ROOT/kernel-console"
KERNEL_BIN="$KERNEL_DIR/bin"
UI_DIR="$ROOT/ui"
CHECK_SCRIPT="$ROOT/scripts/check-env-linux.sh"
DIST_DIR="$UI_DIR/dist"

command -v go >/dev/null 2>&1 || { echo "go command not found. Please install Go and add it to PATH."; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "npm command not found. Please install Node.js and npm."; exit 1; }

retry() {
  local max_attempts="$1"
  shift
  local attempt=1
  until "$@"; do
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "Command failed after ${max_attempts} attempts: $*"
      return 1
    fi
    echo "Attempt ${attempt}/${max_attempts} failed, retrying in $((attempt * 2))s ..."
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

if [[ -x "$CHECK_SCRIPT" ]]; then
  "$CHECK_SCRIPT"
fi

mkdir -p "$GATEWAY_BIN" "$KERNEL_BIN"

echo "Building gateway ..."
(
  cd "$GATEWAY_DIR"
  go build -o "$GATEWAY_BIN/gateway" .
)

echo "Building kernel console launcher ..."
(
  cd "$KERNEL_DIR"
  go build -o "$KERNEL_BIN/FPlayerFFServiceKernel" .
)
[[ -f "$KERNEL_BIN/FPlayerFFServiceKernel" ]] || { echo "kernel console binary build failed."; exit 1; }

echo "Installing UI dependencies ..."
(
  cd "$UI_DIR"
  export npm_config_fetch_retries="${npm_config_fetch_retries:-5}"
  export npm_config_fetch_retry_factor="${npm_config_fetch_retry_factor:-2}"
  export npm_config_fetch_retry_mintimeout="${npm_config_fetch_retry_mintimeout:-20000}"
  export npm_config_fetch_retry_maxtimeout="${npm_config_fetch_retry_maxtimeout:-120000}"
  export npm_config_network_timeout="${npm_config_network_timeout:-120000}"

  # Optional acceleration for Electron binary download in CN network environments.
  # You can override this by exporting ELECTRON_MIRROR before running script.
  export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
  export ELECTRON_BUILDER_BINARIES_MIRROR="${ELECTRON_BUILDER_BINARIES_MIRROR:-https://npmmirror.com/mirrors/electron-builder-binaries/}"

  if [[ -f "$UI_DIR/package-lock.json" ]]; then
    echo "Using npm ci (lockfile detected) ..."
    retry 3 npm ci
  else
    echo "Using npm install (no lockfile) ..."
    retry 3 npm install
  fi
  echo "Building Linux package ..."
  retry 2 npm run dist:linux
)

echo
echo "Build done. Linux package output:"
echo "  $DIST_DIR"
