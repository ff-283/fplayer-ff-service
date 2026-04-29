#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_DIR="$ROOT/ui"
DIST_DIR="$UI_DIR/dist"
RELEASE_DIR="$ROOT/release"
LINUX_UNPACKED_DIR="$DIST_DIR/linux-unpacked"
GATEWAY_BIN="$ROOT/gateway/bin/gateway"
KERNEL_BIN="$ROOT/kernel-console/bin/FPlayerFFServiceKernel"
CHECK_SCRIPT="$ROOT/scripts/check-env-linux.sh"
PORTABLE_BASE=""

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

ZLM_SRC_DIR="$(resolve_zlm_linux_dir)"
[[ -n "$ZLM_SRC_DIR" ]] || { echo "ZLM Linux directory not found: $ROOT/3rd/zlm/{linux|Linux}"; exit 1; }
ZLM_DIR_NAME="$(basename "$ZLM_SRC_DIR")"

remove_dir_if_exists() {
  local target="$1"
  if [[ -d "$target" ]]; then
    rm -rf "$target"
  fi
}

cleanup() {
  if [[ -n "${PORTABLE_BASE:-}" ]] && [[ -d "$PORTABLE_BASE" ]]; then
    rm -rf "$PORTABLE_BASE"
  fi
}
trap cleanup EXIT

detect_ui_binary_name() {
  local unpacked_dir="$1"
  local preferred="fplayer-ff-service-ui"
  if [[ -x "$unpacked_dir/$preferred" ]]; then
    echo "$preferred"
    return
  fi

  # Fallback: pick the largest executable that is not a helper binary.
  local candidate
  candidate="$(ls -1 "$unpacked_dir" 2>/dev/null | while read -r f; do
    [[ -f "$unpacked_dir/$f" ]] || continue
    [[ -x "$unpacked_dir/$f" ]] || continue
    case "$f" in
      chrome-sandbox|chrome_crashpad_handler|AppRun|*.so|*.pak|*.bin|*.json|*.txt|*.yaml|*.yml|*.dat|*.png|*.svg)
        continue
        ;;
    esac
    stat -c "%s $f" "$unpacked_dir/$f" 2>/dev/null || true
  done | sort -nr | awk 'NR==1{print $2}')"
  echo "${candidate:-}"
}

echo "Step 1/3: build Linux package ..."
if [[ -x "$CHECK_SCRIPT" ]]; then
  "$CHECK_SCRIPT"
fi
"$ROOT/scripts/build-linux-package.sh"

echo "Step 2/3: collect artifacts ..."
"$ROOT/scripts/stop-all.sh" || true

remove_dir_if_exists "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

APPIMAGE="$(ls -1t "$DIST_DIR"/*.AppImage 2>/dev/null | head -n 1 || true)"
if [[ -z "$APPIMAGE" ]]; then
  echo "No AppImage found in: $DIST_DIR"
  exit 1
fi

cp -f "$APPIMAGE" "$RELEASE_DIR/$(basename "$APPIMAGE")"

[[ -d "$LINUX_UNPACKED_DIR" ]] || { echo "linux-unpacked directory not found: $LINUX_UNPACKED_DIR"; exit 1; }
[[ -f "$GATEWAY_BIN" ]] || { echo "gateway binary not found: $GATEWAY_BIN"; exit 1; }
[[ -f "$KERNEL_BIN" ]] || { echo "kernel launcher not found: $KERNEL_BIN"; exit 1; }

PACKAGED_DIR="$RELEASE_DIR/linux-unpacked"
remove_dir_if_exists "$PACKAGED_DIR"
cp -R "$LINUX_UNPACKED_DIR" "$PACKAGED_DIR"

PORTABLE_BASE="$RELEASE_DIR/_portable-base"
PORTABLE_UI="$RELEASE_DIR/portable-ui"
PORTABLE_KERNEL="$RELEASE_DIR/portable-kernel"
remove_dir_if_exists "$PORTABLE_BASE"
remove_dir_if_exists "$PORTABLE_UI"
remove_dir_if_exists "$PORTABLE_KERNEL"

mkdir -p "$PORTABLE_BASE"
cp -a "$LINUX_UNPACKED_DIR"/. "$PORTABLE_BASE/"
UI_BIN_NAME="$(detect_ui_binary_name "$PORTABLE_BASE")"
if [[ -z "$UI_BIN_NAME" ]]; then
  echo "Cannot detect UI executable in: $PORTABLE_BASE"
  exit 1
fi

if [[ -d "$ROOT/3rd" ]]; then
  cp -a "$ROOT/3rd" "$PORTABLE_BASE/3rd"
fi
mkdir -p "$PORTABLE_BASE/gateway/bin"
cp -f "$GATEWAY_BIN" "$PORTABLE_BASE/gateway/bin/gateway"
cp -a "$ROOT/scripts" "$PORTABLE_BASE/scripts"

mkdir -p "$PORTABLE_UI" "$PORTABLE_KERNEL"
cp -a "$PORTABLE_BASE"/. "$PORTABLE_UI/"
cp -a "$PORTABLE_BASE"/. "$PORTABLE_KERNEL/"

rm -f "$PORTABLE_UI/FPlayerFFServiceKernel"
rm -f "$PORTABLE_KERNEL/FPlayerFFService"
cp -f "$KERNEL_BIN" "$PORTABLE_KERNEL/FPlayerFFServiceKernel"

# Linux portable launcher: avoid requiring root-owned chrome-sandbox in user-space distribution.
cat > "$PORTABLE_UI/FPlayerFFService" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SELF_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "\$SELF_DIR/$UI_BIN_NAME" --no-sandbox "\$@"
EOF
chmod +x "$PORTABLE_UI/FPlayerFFService"

REQUIRED_BASE=(
  "$PORTABLE_BASE/$UI_BIN_NAME"
  "$PORTABLE_BASE/3rd/zlm/$ZLM_DIR_NAME"
  "$PORTABLE_BASE/3rd/zlm/$ZLM_DIR_NAME/MediaServer"
  "$PORTABLE_BASE/3rd/zlm/$ZLM_DIR_NAME/config.ini"
  "$PORTABLE_BASE/gateway/bin/gateway"
  "$PORTABLE_BASE/kernel-console/bin/FPlayerFFServiceKernel"
  "$PORTABLE_BASE/scripts/start-all.sh"
  "$PORTABLE_BASE/scripts/stop-all.sh"
  "$PORTABLE_BASE/resources/app.asar"
)
for path_item in "${REQUIRED_BASE[@]}"; do
  [[ -e "$path_item" ]] || { echo "Release package missing required dependency: $path_item"; exit 1; }
done

REQUIRED_SPLIT=(
  "$PORTABLE_UI/FPlayerFFService"
  "$PORTABLE_UI/$UI_BIN_NAME"
  "$PORTABLE_KERNEL/FPlayerFFServiceKernel"
)
for path_item in "${REQUIRED_SPLIT[@]}"; do
  [[ -e "$path_item" ]] || { echo "Release package missing split artifact: $path_item"; exit 1; }
done

echo "Step 3/3: done"
echo "Release directory: $RELEASE_DIR"
echo "AppImage: $RELEASE_DIR/$(basename "$APPIMAGE")"
echo "Portable UI directory: $PORTABLE_UI"
echo "Portable Kernel directory: $PORTABLE_KERNEL"
echo "Packaged directory: $PACKAGED_DIR"
