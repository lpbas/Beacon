#!/usr/bin/env bash
#
# Build without a full Xcode install, using the Command Line Tools toolchain.
#
# Why this exists: the app target is SwiftUI, and SwiftUI's property wrappers are
# compiler macros. The macro plugin (libSwiftUIMacros.dylib) ships only inside Xcode,
# so the Command Line Tools alone cannot compile the app target. The engine and model
# layers have no SwiftUI dependency, and neither does the self-test CLI that drives
# them, so those build and run anywhere.
#
# This script therefore always builds `beacon-selftest`, and additionally builds
# Beacon.app when a full Xcode is available (delegating to xcodegen + xcodebuild, the
# project's normal path).
#
# Usage:
#   scripts/build-local.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
case "$CONFIG" in
  debug)   SWIFT_OPT=(-Onone -g) ;;
  release) SWIFT_OPT=(-O) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
DEPLOYMENT_TARGET="${BEACON_DEPLOYMENT_TARGET:-$(sed -n 's/^ *macOS: *"\(.*\)"/\1/p' project.yml | head -1)}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-14.0}"
OUT="build/local-$CONFIG"
mkdir -p "$OUT"

sources() { find "$@" -name '*.swift' | sort; }

echo "▶︎ Building beacon-selftest ($CONFIG, $ARCH-apple-macos$DEPLOYMENT_TARGET)…"
# Same file set as the beacon-selftest target in project.yml: the real engine and
# model layer plus the CLI, so the CLI exercises the exact code the app runs.
swiftc -swift-version 5 "${SWIFT_OPT[@]}" \
  -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" -sdk "$SDK" \
  -o "$OUT/beacon-selftest" \
  $(sources Beacon/Engine Beacon/Model) Beacon/Diagnostics.swift SelfTest/main.swift
echo "  → $OUT/beacon-selftest"

if xcrun --find xcodebuild >/dev/null 2>&1 && xcrun --find actool >/dev/null 2>&1; then
  echo "▶︎ Xcode found; building Beacon.app…"
  command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }
  xcodegen generate >/dev/null
  xcodebuild -project Beacon.xcodeproj -scheme Beacon -configuration "$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}" \
    -destination 'platform=macOS' -derivedDataPath build/local-xcode build >/dev/null
  echo "  → build/local-xcode/Build/Products/*/Beacon.app"
else
  cat <<'NOTE'
▶︎ Skipping Beacon.app: no full Xcode install was found.
  The app target is SwiftUI, whose property-wrapper macros need the macro plugin that
  ships inside Xcode (libSwiftUIMacros.dylib). Install Xcode, then either run this
  script again or follow "Building from source" in README.md.

  The CLI above is enough to exercise the DNS-SD engine, e.g.:
    build/local-debug/beacon-selftest interfaces
    build/local-debug/beacon-selftest mirror "My Service" _hap._tcp
    build/local-debug/beacon-selftest engine 30
NOTE
fi
