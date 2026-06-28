#!/usr/bin/env bash
#
# Build, sign, package (and optionally notarize + staple) a Beacon release DMG.
#
# Signing details are read from a local, untracked .env file (copy .env.example
# to .env and fill it in).
#
# One-time notarization setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials "$BEACON_NOTARY_PROFILE" \
#       --apple-id "$BEACON_APPLE_ID" --team-id "$BEACON_TEAM_ID" --password "<app-specific-password>"
#
# Usage:
#   scripts/release.sh [version]        # e.g. scripts/release.sh 0.1.0
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Load local signing config (not committed).
if [ -f .env ]; then
  set -a; . ./.env; set +a
fi
: "${BEACON_TEAM_ID:?Set BEACON_TEAM_ID in .env (copy .env.example to .env)}"
: "${BEACON_SIGN_IDENTITY:?Set BEACON_SIGN_IDENTITY in .env (copy .env.example to .env)}"

VERSION="${1:-0.1.0}"
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
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES \
  clean build >/dev/null

echo "▶︎ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▶︎ Building DMG…"
rm -rf dist && mkdir -p dist/dmgroot
cp -R "$APP" dist/dmgroot/
ln -s /Applications dist/dmgroot/Applications
hdiutil create -volname "Beacon" -srcfolder dist/dmgroot -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/dmgroot

if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "▶︎ Notarizing (this uploads the DMG to Apple)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▶︎ Stapling…"
  xcrun stapler staple "$DMG"
  echo "✓ Notarized & stapled: $DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG" || true
else
  echo "Notary profile '$NOTARY_PROFILE' not found, skipping notarization."
  echo "   The DMG is signed but will be Gatekeeper-blocked on other Macs until notarized."
  echo "   See the setup comment at the top of this script."
fi

echo "✓ Done: $DMG"
