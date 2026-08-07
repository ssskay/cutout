#!/usr/bin/env bash
#
# install-automation.sh — install the `cutout` CLI plus its two automation surfaces.
#
#   1. a watch folder      ~/Cutout/In  ->  ~/Cutout/Out   (LaunchAgent, starts at login)
#   2. a Finder Quick Action   right-click images -> "Remove Background (Cutout)"
#
# Both call the same binary, which is compiled from the app's own Core/ sources.
#
#   scripts/install-automation.sh                    # both surfaces, eBay preset
#   scripts/install-automation.sh --preset id        # ID photos instead
#   scripts/install-automation.sh --no-watch         # Quick Action only
#   scripts/install-automation.sh --no-quick-action  # watch folder only
#   scripts/uninstall-automation.sh                  # remove everything
#
set -euo pipefail

PRESET="ebay"
INSTALL_WATCH=1
INSTALL_QUICK_ACTION=1
IN_DIR="$HOME/Cutout/In"
OUT_DIR="$HOME/Cutout/Out"
BIN_DIR="$HOME/.local/bin"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --preset) PRESET="$2"; shift 2 ;;
    --in) IN_DIR="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --no-watch) INSTALL_WATCH=0; shift ;;
    --no-quick-action) INSTALL_QUICK_ACTION=0; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$PRESET" in
  transparent|ebay|id|custom) ;;
  *) echo "--preset must be transparent|ebay|id|custom (got '$PRESET')" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LABEL="me.sarakay.cutout.watch"
AGENT_PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/Cutout"
SERVICE_DIR="$HOME/Library/Services/Remove Background (Cutout).workflow"

# ---------------------------------------------------------------------------
echo "== Building the CLI =="
# ---------------------------------------------------------------------------
scripts/build-cli.sh

mkdir -p "$BIN_DIR"
install -m 755 build/cutout "$BIN_DIR/cutout"
echo "  installed $BIN_DIR/cutout"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  NOTE: $BIN_DIR is not on your PATH. Add this to ~/.zshrc:"
     echo "        export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ---------------------------------------------------------------------------
if [ "$INSTALL_WATCH" -eq 1 ]; then
echo
echo "== Watch folder =="
# ---------------------------------------------------------------------------
mkdir -p "$IN_DIR" "$OUT_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

# Unload an existing agent first so a re-run reinstalls cleanly rather than
# leaving the old binary running against the new plist.
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>

	<key>ProgramArguments</key>
	<array>
		<string>${BIN_DIR}/cutout</string>
		<string>watch</string>
		<string>--in</string>
		<string>${IN_DIR}</string>
		<string>--out</string>
		<string>${OUT_DIR}</string>
		<string>--preset</string>
		<string>${PRESET}</string>
	</array>

	<key>RunAtLoad</key>
	<true/>
	<!-- Restart if it ever dies. It is a poll loop, so it should not, but an
	     unattended folder watcher that silently stopped would be worse than one
	     that flaps visibly in the log. -->
	<key>KeepAlive</key>
	<true/>

	<key>StandardOutPath</key>
	<string>${LOG_DIR}/watch.log</string>
	<key>StandardErrorPath</key>
	<string>${LOG_DIR}/watch.log</string>

	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
</dict>
</plist>
PLIST

plutil -lint "$AGENT_PLIST" >/dev/null || { echo "generated LaunchAgent plist is malformed" >&2; exit 1; }
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
launchctl enable "gui/$(id -u)/${LABEL}"

echo "  watching  $IN_DIR"
echo "  output    $OUT_DIR"
echo "  preset    $PRESET"
echo "  log       $LOG_DIR/watch.log"
fi

# ---------------------------------------------------------------------------
if [ "$INSTALL_QUICK_ACTION" -eq 1 ]; then
echo
echo "== Finder Quick Action =="
# ---------------------------------------------------------------------------
rm -rf "$SERVICE_DIR"
mkdir -p "$SERVICE_DIR/Contents"

cat > "$SERVICE_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Remove Background (Cutout)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Remove Background (Cutout)</string>
			</dict>
			<key>NSMessage</key>
			<string>runWorkflowAsService</string>
			<key>NSRequiredContext</key>
			<dict>
				<key>NSApplicationIdentifier</key>
				<string>com.apple.finder</string>
			</dict>
			<key>NSSendFileTypes</key>
			<array>
				<string>public.image</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# The shell script the action runs. Written to its own file and referenced from
# the workflow so the quoting only has to be right once.
QA_SCRIPT="for f in \"\$@\"; do
  \"${BIN_DIR}/cutout\" --preset ${PRESET} --out \"${OUT_DIR}\" \"\$f\"
done
open \"${OUT_DIR}\""

cat > "$SERVICE_DIR/Contents/document.wflow" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key><string>528</string>
	<key>AMApplicationVersion</key><string>2.10</string>
	<key>AMDocumentVersion</key><string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Optional</key><true/>
					<key>Types</key><array><string>com.apple.cocoa.string</string></array>
				</dict>
				<key>AMActionVersion</key><string>2.0.3</string>
				<key>AMApplication</key><array><string>Automator</string></array>
				<key>AMParameterProperties</key>
				<dict>
					<key>COMMAND_STRING</key><dict/>
					<key>CheckedForUserDefaultShell</key><dict/>
					<key>inputMethod</key><dict/>
					<key>shell</key><dict/>
					<key>source</key><dict/>
				</dict>
				<key>AMProvides</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Types</key><array><string>com.apple.cocoa.string</string></array>
				</dict>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key><string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>${QA_SCRIPT}</string>
					<key>CheckedForUserDefaultShell</key><true/>
					<!-- 1 = pass the selected files as arguments, not on stdin. -->
					<key>inputMethod</key><integer>1</integer>
					<key>shell</key><string>/bin/zsh</string>
					<key>source</key><string></string>
				</dict>
				<key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key><string>2.0.3</string>
				<key>CanShowSelectedItemsWhenRun</key><false/>
				<key>CanShowWhenRun</key><true/>
				<key>Category</key><array><string>AMCategoryUtilities</string></array>
				<key>Class Name</key><string>RunShellScriptAction</string>
				<key>InputUUID</key><string>9F1B2C3D-4E5F-4A6B-8C9D-0E1F2A3B4C5D</string>
				<key>Keywords</key><array><string>Shell</string><string>Script</string><string>Command</string><string>Run</string><string>Unix</string></array>
				<key>OutputUUID</key><string>1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5E</string>
				<key>UUID</key><string>2B3C4D5E-6F7A-4B8C-9D0E-1F2A3B4C5D6F</string>
				<key>UnlocalizedApplications</key><array><string>Automator</string></array>
				<key>arguments</key><dict/>
				<key>isViewVisible</key><integer>1</integer>
				<key>location</key><string>309.000000:253.000000</string>
				<key>nibPath</key>
				<string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
			</dict>
			<key>isViewVisible</key><integer>1</integer>
		</dict>
	</array>
	<key>connectors</key><dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>serviceInputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject.image</string>
		<key>serviceOutputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>serviceApplicationBundleID</key><string>com.apple.finder</string>
		<key>serviceApplicationPath</key>
		<string>/System/Library/CoreServices/Finder.app</string>
		<key>presentationMode</key><integer>11</integer>
		<key>processesInput</key><integer>0</integer>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
PLIST

plutil -lint "$SERVICE_DIR/Contents/Info.plist" >/dev/null || { echo "Quick Action Info.plist is malformed" >&2; exit 1; }
plutil -lint "$SERVICE_DIR/Contents/document.wflow" >/dev/null || { echo "Quick Action workflow is malformed" >&2; exit 1; }

# Tell the Services system something changed, otherwise the menu item can take
# until the next login to appear.
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

echo "  installed $SERVICE_DIR"
echo "  right-click images in Finder -> Quick Actions -> Remove Background (Cutout)"
fi

echo
echo "Done."
if [ "$INSTALL_WATCH" -eq 1 ]; then
  echo "  Try it:  cp some-photo.jpg \"$IN_DIR\"  &&  sleep 5  &&  open \"$OUT_DIR\""
fi
echo "  Remove:  scripts/uninstall-automation.sh"
