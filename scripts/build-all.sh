#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$ROOT/bin"

mkdir -p "$BIN_DIR"

declare -A TARGETS=(
  ["x86_64-windows-gnu"]="wu-win32-x64.exe"
  ["x86_64-linux-gnu"]="wu-linux-x64"
  ["x86_64-macos-none"]="wu-darwin-x64"
  ["aarch64-macos-none"]="wu-darwin-arm64"
)

echo "Building wu-cli for all platforms..."
echo ""

for target in "${!TARGETS[@]}"; do
  binary="${TARGETS[$target]}"
  echo "  [$target] → $binary"

  cd "$ROOT"
  zig build -Dtarget="$target" -Doptimize=ReleaseSmall 2>&1 | sed 's/^/    /'

  # Zig outputs to zig-out/bin/wu (or wu.exe on windows)
  if [[ "$target" == *"windows"* ]]; then
    src="$ROOT/zig-out/bin/wu.exe"
  else
    src="$ROOT/zig-out/bin/wu"
  fi

  cp "$src" "$BIN_DIR/$binary"
  chmod +x "$BIN_DIR/$binary"

  size=$(wc -c < "$BIN_DIR/$binary" | tr -d ' ')
  size_kb=$((size / 1024))
  echo "    → ${size_kb} KB"
  echo ""
done

echo "All binaries built in $BIN_DIR:"
ls -lh "$BIN_DIR"/wu-*
