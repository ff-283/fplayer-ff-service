#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS=(
  "$ROOT/ui/dist"
  "$ROOT/release"
  "$ROOT/run"
  "$ROOT/logs"
  "$ROOT/gateway/bin/gateway"
  "$ROOT/kernel-console/bin/FPlayerFFServiceKernel"
)

echo "Cleaning generated artifacts..."
for target in "${TARGETS[@]}"; do
  if [[ -e "$target" ]]; then
    rm -rf "$target"
    echo "  [Removed] $target"
  else
    echo "  [Skip]    $target"
  fi
done

echo
echo "Done."
echo "Note:"
echo "  - This script does NOT remove 3rd/, source files, or docs."
echo "  - If you also want to clean ui/node_modules, remove it manually."
