#!/usr/bin/env bash
#
# uninstall-automation.sh — remove everything install-automation.sh put in place.
#
# Leaves ~/Cutout/In and ~/Cutout/Out alone: they may contain images, and this
# script has no business deleting those.
#
set -euo pipefail

LABEL="me.sarakay.cutout.watch"
AGENT_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SERVICE_DIR="$HOME/Library/Services/Remove Background (Cutout).workflow"
BIN="$HOME/.local/bin/cutout"

echo "== Stopping the watch agent =="
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null && echo "  stopped" || echo "  was not running"
rm -f "$AGENT_PLIST" && echo "  removed $AGENT_PLIST"

echo "== Removing the Quick Action =="
if [ -d "$SERVICE_DIR" ]; then
  rm -rf "$SERVICE_DIR"
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
  echo "  removed $SERVICE_DIR"
else
  echo "  not installed"
fi

echo "== Removing the CLI =="
if [ -f "$BIN" ]; then
  rm -f "$BIN"
  echo "  removed $BIN"
else
  echo "  not installed"
fi

echo
echo "Done. Your images in ~/Cutout were left untouched."
echo "Logs, if you want them gone: rm -rf ~/Library/Logs/Cutout"
