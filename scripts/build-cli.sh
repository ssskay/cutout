#!/usr/bin/env bash
#
# build-cli.sh — compile the `cutout` CLI against the app's own Core/ sources.
#
# Deliberately not an Xcode target: the CLI and the app share the exact same
# files on disk, so there is no chance of shipping a stale copy of the engine.
# Vision and Core Image are system frameworks, so swiftc alone is enough.
#
#   scripts/build-cli.sh                    # build only
#   scripts/build-cli.sh photo.jpg -o out   # build, then run with these args
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="build"
BIN="$BUILD_DIR/cutout"
mkdir -p "$BUILD_DIR"

# Core/ only. App/ is SwiftUI and has no business in a CLI.
CORE_SOURCES=(Cutout/Core/*.swift)
CLI_SOURCES=(Tools/cutout/*.swift)

echo "• compiling ${#CORE_SOURCES[@]} core + ${#CLI_SOURCES[@]} CLI sources" >&2
swiftc -O \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target "$(uname -m)-apple-macos14.0" \
  -framework Vision -framework CoreImage -framework AppKit \
  -o "$BIN" \
  "${CORE_SOURCES[@]}" "${CLI_SOURCES[@]}"

echo "✓ built $BIN" >&2

if [ "$#" -gt 0 ]; then
  exec "$BIN" "$@"
fi
