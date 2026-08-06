#!/usr/bin/env bash
#
# masktest.sh — compile Tools/masktest against the app's Core/ sources.
#
# Deliberately not an Xcode target: the CLI and the app share the exact same
# files on disk, so there is no chance of the harness testing a stale copy of
# the engine. Vision and Core Image are system frameworks, so swiftc alone is
# enough.
#
#   scripts/masktest.sh                     # build only
#   scripts/masktest.sh photo.jpg --sweep   # build, then run with these args
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="build"
BIN="$BUILD_DIR/masktest"
mkdir -p "$BUILD_DIR"

# Core/ only. App/ is SwiftUI and has no business in a CLI.
CORE_SOURCES=(Cutout/Core/*.swift)

echo "• compiling ${#CORE_SOURCES[@]} core sources + masktest" >&2
swiftc -O \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -target "$(uname -m)-apple-macos14.0" \
  -framework Vision -framework CoreImage -framework AppKit \
  -o "$BIN" \
  "${CORE_SOURCES[@]}" Tools/masktest/main.swift

echo "✓ built $BIN" >&2

if [ "$#" -gt 0 ]; then
  exec "$BIN" "$@"
fi
