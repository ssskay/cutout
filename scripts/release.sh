#!/usr/bin/env bash
#
# release.sh - build, sign, notarize, staple, and publish Cutout.
#
# Modelled on ~/Code/Yaha-Pet/scripts/release.sh, with the beta-toolchain guard
# from ~/Code/osier/notarize_app.sh. Cutout is a plain Swift app with no bundled
# frameworks or helper binaries, so the inside-out signing walk Yaha-Pet needs
# for PyInstaller is replaced by `xcodebuild -exportArchive`, which signs the
# single bundle correctly on its own.
#
# The pipeline, in order:
#   preflight -> archive -> export (signed) -> verify -> zip
#     -> notarize app -> staple app -> Gatekeeper gate
#     -> build dmg -> sign dmg -> notarize dmg -> staple dmg -> gate dmg
#     -> sha256 -> gh release
#
# Flags:
#   --dry-run     Build and sign locally; never contact Apple, never publish.
#   --no-publish  Do the full Apple round-trip but skip `gh release create`.
#   -h|--help     Show usage.
#
set -euo pipefail

# ============================================================================
# CONFIG
# ============================================================================
APP_NAME="Cutout"
APP_BUNDLE="${APP_NAME}.app"
BUNDLE_ID="me.sarakay.cutout"
SCHEME="Cutout"
PROJECT="Cutout.xcodeproj"
ENTITLEMENTS="Cutout.entitlements"
NOTARY_PROFILE="AC_NOTARY"
DEVELOPMENT_TEAM="AH785WYH3F"
SIGN_NAME="Developer ID Application: Sara Kay (AH785WYH3F)"
BUILD_DIR="build"
DIST_DIR="dist"
DMG_BASENAME="${APP_NAME}-macOS"

# ---- logging helpers -------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi

phase() { printf '\n%s== %s ==%s\n' "$BOLD$BLU" "$1" "$RST"; }
log()   { printf '%s.%s %s\n' "$DIM" "$RST" "$1"; }
ok()    { printf '%s/%s %s\n' "$GRN" "$RST" "$1"; }
warn()  { printf '%s! %s%s\n' "$YLW" "$1" "$RST"; }
die()   { printf '%sx %s%s\n' "$RED" "$1" "$RST" >&2; exit 1; }

roundtrip_banner() {
  printf '\n%s+--------------------------------------------+%s\n' "$YLW" "$RST"
  printf '%s|  APPLE ROUND-TRIP: %-23s |%s\n' "$YLW" "$1" "$RST"
  printf '%s+--------------------------------------------+%s\n' "$YLW" "$RST"
}

# ---- args ------------------------------------------------------------------
DRY_RUN=0
PUBLISH=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-publish) PUBLISH=0 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done
[ "$DRY_RUN" -eq 1 ] && warn "DRY RUN - build and sign locally, nothing sent to Apple."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ============================================================================
phase "1/9  Preflight"
# ============================================================================
# Everything here is checked before a multi-minute build so a missing tool is a
# two-second error with the fix attached, not a failure fifteen minutes in.

# Releases MUST be built with a STABLE Xcode. Xcode 27 beta (Swift 6.4)
# miscompiles MainActor isolation across an await (swiftlang/swift#89214) —
# Osier 0.9.5 shipped from it and crashed on every button tap. Refuse a beta.
XCODE_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"
if [[ "${XCODE_DIR}" == *[Bb]eta* && "${ALLOW_BETA_XCODE:-0}" != "1" ]]; then
  echo "Refusing to build a release with a BETA Xcode:"
  echo "    ${XCODE_DIR}"
  echo "  Xcode 27 beta / Swift 6.4 miscompiles MainActor isolation (#89214)."
  echo "  Build with the stable Xcode instead:"
  echo "    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0"
  echo "  (Only override if you have confirmed the toolchain is fixed: ALLOW_BETA_XCODE=1 ...)"
  exit 1
fi
log "toolchain: ${XCODE_DIR}"
log "xcodebuild: $(xcodebuild -version | head -1)"

PREFLIGHT_FAIL=0
preflight_err() { echo "x $1"; echo "   fix: $2"; PREFLIGHT_FAIL=1; }

for tool in xcodebuild codesign xcrun ditto spctl shasum; do
  command -v "$tool" >/dev/null 2>&1 || preflight_err "missing required tool: $tool" "install Xcode command line tools"
done
command -v create-dmg >/dev/null 2>&1 || \
  preflight_err "create-dmg not found" "brew install create-dmg"
[ -f "$ENTITLEMENTS" ] || preflight_err "entitlements not found: $ENTITLEMENTS" "restore it from git"

# The entitlements file is the only thing standing between "offline by design"
# and "offline by good intentions". A network entitlement here would let the
# sandbox permit outbound connections, so the release refuses to ship one.
# Match a real <key>, not the prose in the comment explaining why there isn't one.
if grep -qE '<key>[[:space:]]*com\.apple\.security\.network' "$ENTITLEMENTS"; then
  preflight_err "a network entitlement is present in $ENTITLEMENTS" \
    "Cutout is offline by design - remove it, or knowingly edit this check"
fi

if [ "$PUBLISH" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || preflight_err "gh not found" "brew install gh  (or pass --no-publish)"
fi

# Signing identity must be present by its exact name.
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_NAME"; then
  preflight_err "signing identity not in the keychain: $SIGN_NAME" \
    "download the Developer ID Application cert from developer.apple.com and double-click it"
fi

# Verify the notary profile EXISTS rather than creating one. A second
# app-specific password is not needed and would be a mess to keep straight.
if [ "$DRY_RUN" -eq 0 ]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    preflight_err "notarytool profile '$NOTARY_PROFILE' is missing or invalid" \
      "it should already exist on this Mac; check with: xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
  fi
fi

[ "$PREFLIGHT_FAIL" -eq 0 ] || die "preflight failed - see above."
ok "preflight clean"

# ============================================================================
phase "2/9  Archive"
# ============================================================================
rm -rf "$BUILD_DIR/$APP_NAME.xcarchive" "$DIST_DIR"
mkdir -p "$DIST_DIR"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_NAME" \
  | grep -E '^(===|\*\*|error:|warning:)' || true

[ -d "$BUILD_DIR/$APP_NAME.xcarchive" ] || die "archive not produced"
ok "archived"

# ============================================================================
phase "3/9  Export (Developer ID, hardened runtime)"
# ============================================================================
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>${DEVELOPMENT_TEAM}</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
  -exportPath "$DIST_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  | grep -E '^(===|\*\*|error:)' || true

APP_PATH="$DIST_DIR/$APP_BUNDLE"
[ -d "$APP_PATH" ] || die "expected app not produced: $APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '0.0.0')"
TAG="v${VERSION}"
ok "exported $APP_PATH (version $VERSION)"

# ============================================================================
phase "4/9  Local verification"
# ============================================================================
# --deep is correct for VERIFICATION (walk everything); it is only wrong for
# signing. --strict catches what the notary service would otherwise reject.
codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  || die "codesign verification failed - fix before spending an Apple round-trip"
ok "codesign --verify --deep --strict passed"

codesign -dvv "$APP_PATH" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority|flags' | sed 's/^/    /' || true

# Capture before grepping. Under `set -o pipefail`, `codesign | grep -q` fails
# the whole pipeline: grep exits at the first match, codesign takes SIGPIPE, and
# a passing check reads as a failure.
SIGN_INFO="$(codesign -d --verbose=2 "$APP_PATH" 2>&1 || true)"

# Hardened runtime is required to notarize; confirm it actually got set.
grep -q 'flags=.*runtime' <<<"$SIGN_INFO" \
  || die "hardened runtime is NOT enabled on the exported app"
ok "hardened runtime enabled"

# Re-assert the offline guarantee against the BUILT bundle, not just the source
# entitlements file - this is what actually ships.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null || true)"
if grep -q "com.apple.security.network" <<<"$SIGNED_ENTITLEMENTS"; then
  die "the signed app carries a network entitlement - Cutout must ship offline"
fi
ok "no network entitlement in the signed bundle"

# Sandbox on is what turns "we never open a socket" into something the kernel
# enforces rather than something we promise.
grep -q "com.apple.security.app-sandbox" <<<"$SIGNED_ENTITLEMENTS" \
  || die "the signed app is NOT sandboxed - the offline guarantee is unenforced"
ok "app sandbox enabled"

# ============================================================================
phase "5/9  Package (ditto zip for notarization)"
# ============================================================================
# ditto -c -k --keepParent preserves symlinks and signatures. Plain `zip` can
# corrupt a signed .app - never use it here.
ZIP_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.zip"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
ok "wrote $ZIP_PATH"

notarize() {
  local file="$1" label="$2"
  roundtrip_banner "notarize $label"
  log "submitting $file (1-5 min)..."

  local out submission status
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  printf '%s\n' "$out"

  submission="$(printf '%s\n' "$out" | awk '/id:/ {print $2; exit}')"
  status="$(printf '%s\n' "$out" | awk -F': *' '/status:/ {print $2}' | tail -1)"

  if [ "$status" = "Accepted" ]; then
    ok "notarization ACCEPTED ($label, id $submission)"
    return 0
  fi

  warn "notarization NOT accepted (status: ${status:-unknown}). Fetching Apple's log..."
  if [ -n "$submission" ]; then
    xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" || true
  fi
  return 1
}

# ============================================================================
phase "6/9  Notarize + staple the app"
# ============================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  warn "[dry-run] skipping app notarization and stapling."
else
  notarize "$ZIP_PATH" "app" || die "app notarization failed (see Apple log above)."
  xcrun stapler staple "$APP_PATH" || die "stapler failed for the app"
  ok "stapled $APP_BUNDLE"

  # For a .app the correct assessment type is `exec`; `install` is for disk
  # images and installers, which we gate separately below.
  app_assess="$(spctl -a -t exec -vvv "$APP_PATH" 2>&1 || true)"
  printf '%s\n' "$app_assess" | sed 's/^/    /'
  printf '%s\n' "$app_assess" | grep -q 'source=Notarized Developer ID' \
    || die "app did NOT pass the notarized Gatekeeper gate"
  ok "app accepted as Notarized Developer ID"

  # Re-zip so the published archive contains the stapled ticket.
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
  log "re-zipped with the stapled ticket"
fi

# ============================================================================
phase "7/9  Build + sign the DMG"
# ============================================================================
DMG_PATH="$DIST_DIR/${DMG_BASENAME}-${VERSION}.dmg"
rm -f "$DMG_PATH"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$APP_PATH" "$STAGE_DIR/"

create-dmg \
  --volname "$APP_NAME" \
  --app-drop-link 480 170 \
  --icon "$APP_BUNDLE" 160 170 \
  --window-size 640 360 \
  --hide-extension "$APP_BUNDLE" \
  --no-internet-enable \
  "$DMG_PATH" "$STAGE_DIR" \
  || die "create-dmg failed"
ok "built $DMG_PATH"

# A disk image is not executable code: Developer ID signature only, no hardened
# runtime and no entitlements.
codesign --force --timestamp --sign "$SIGN_NAME" "$DMG_PATH"
ok "signed the DMG"

# ============================================================================
phase "8/9  Notarize + staple the DMG"
# ============================================================================
# Stapling the DMG (not just the app inside it) is what makes the very first
# open-from-download clean: Gatekeeper reads the ticket off the disk image
# without a network check.
if [ "$DRY_RUN" -eq 1 ]; then
  warn "[dry-run] skipping DMG notarization. Artifacts:"
  log  "  app: $APP_PATH (signed, hardened runtime, NOT notarized)"
  log  "  dmg: $DMG_PATH (signed, NOT notarized)"
  exit 0
fi

notarize "$DMG_PATH" "dmg" || die "DMG notarization failed (see Apple log above)."
xcrun stapler staple "$DMG_PATH" || die "stapler failed for the DMG"
ok "stapled the DMG"

dmg_assess="$(spctl -a -t install -vvv "$DMG_PATH" 2>&1 || true)"
printf '%s\n' "$dmg_assess" | sed 's/^/    /'
printf '%s\n' "$dmg_assess" | grep -q 'source=Notarized Developer ID' \
  || die "DMG did NOT pass the notarized Gatekeeper gate"
ok "DMG accepted as Notarized Developer ID"

# ============================================================================
phase "9/9  Checksum + GitHub release"
# ============================================================================
SHA_PATH="${DMG_PATH}.sha256"
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$SHA_PATH")" )
ok "wrote $SHA_PATH"
cat "$SHA_PATH" | sed 's/^/    /'

if [ "$PUBLISH" -eq 0 ]; then
  warn "--no-publish: stopping before gh release."
  log "Ship this: $DMG_PATH"
  exit 0
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  warn "tag $TAG already exists locally; reusing it"
else
  git tag -a "$TAG" -m "$APP_NAME $VERSION"
  git push origin "$TAG"
fi

gh release create "$TAG" \
  "$DMG_PATH" "$SHA_PATH" \
  --title "$APP_NAME $VERSION" \
  --notes "Local, offline background removal for macOS. Requires macOS 14 or later.

Verify the download:
\`\`\`
shasum -a 256 -c $(basename "$SHA_PATH")
\`\`\`" \
  || die "gh release create failed"

printf '\n%sRelease complete.%s\n' "$BOLD$GRN" "$RST"
log "Ship this: $DMG_PATH"
