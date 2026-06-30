#!/usr/bin/env bash
#
# Build, sign, package (and optionally notarize + staple) a Beacon release DMG.
#
# Signing details are read from a local, untracked .env file (copy .env.example
# to .env and fill it in).
#
# One-time notarization setup (stores credentials in the keychain):
#   xcrun notarytool store-credentials "beacon-notary" \
#       --apple-id "you@example.com" --team-id "YOURTEAMID"
#
# Omit --password so notarytool prompts securely. Do not store app-specific
# passwords in .env or shell history.
#
# Usage:
#   scripts/release.sh [version]        # e.g. scripts/release.sh 1.0.0
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Load local signing config (not committed).
if [ -f .env ]; then
  set -a; . ./.env; set +a
fi
: "${BEACON_TEAM_ID:?Set BEACON_TEAM_ID in .env (copy .env.example to .env)}"
: "${BEACON_SIGN_IDENTITY:?Set BEACON_SIGN_IDENTITY in .env (copy .env.example to .env)}"

VERSION="${1:-1.0.0}"
TEAM="$BEACON_TEAM_ID"
SIGN_ID="$BEACON_SIGN_IDENTITY"
NOTARY_PROFILE="${BEACON_NOTARY_PROFILE:-beacon-notary}"
APP="build/Build/Products/Release/Beacon.app"
DMG="dist/Beacon-${VERSION}.dmg"

echo "▶︎ Generating project…"
xcodegen generate >/dev/null

echo "▶︎ Building Release (Developer ID, hardened runtime)…"
xcodebuild -project Beacon.xcodeproj -scheme Beacon -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_DEBUG_DYLIB=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
  clean build >/dev/null

echo "▶︎ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"
if codesign -d --entitlements - "$APP/Contents/MacOS/Beacon" 2>/dev/null | grep -q "com.apple.security.get-task-allow"; then
  echo "Release build contains com.apple.security.get-task-allow; refusing to notarize."
  exit 1
fi

echo "▶︎ Building DMG…"
rm -rf dist && mkdir -p dist/dmgroot
cp -R "$APP" dist/dmgroot/
ln -s /Applications dist/dmgroot/Applications
hdiutil create -volname "Beacon" -srcfolder dist/dmgroot -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/dmgroot

echo "▶︎ Signing DMG…"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "▶︎ Notarizing (this uploads the DMG to Apple)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > dist/notary-submit.json
  NOTARY_STATUS="$(plutil -extract status raw -o - dist/notary-submit.json 2>/dev/null || true)"
  NOTARY_ID="$(plutil -extract id raw -o - dist/notary-submit.json 2>/dev/null || true)"
  if [ "$NOTARY_STATUS" != "Accepted" ]; then
    echo "Notarization failed with status: ${NOTARY_STATUS:-unknown}"
    if [ -n "$NOTARY_ID" ]; then
      echo "Fetching notarization log for $NOTARY_ID…"
      xcrun notarytool log "$NOTARY_ID" --keychain-profile "$NOTARY_PROFILE" > dist/notary-log.json || true
      echo "See dist/notary-log.json for details."
    else
      echo "See dist/notary-submit.json for details."
    fi
    exit 1
  fi
  echo "▶︎ Stapling…"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "✓ Notarized & stapled: $DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
else
  echo "Notary profile '$NOTARY_PROFILE' not found, skipping notarization."
  echo "   The DMG is signed but may be Gatekeeper-blocked on other Macs until notarized."
  echo "   See the setup comment at the top of this script."
fi

echo "✓ Done: $DMG"
