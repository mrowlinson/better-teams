#!/bin/bash
# Build Better Teams-<ver>.dmg from the signed release .app (installer for V1).
# Usage: scripts/make-dmg.sh
# Output: tmp/Better Teams-<ver>.dmg (ver = CFBundleShortVersionString).
# Builds tmp/Better Teams.app via package.sh first when missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/tmp/Better Teams.app"
if [[ ! -x "$APP/Contents/MacOS/OstMac" ]]; then
    "$ROOT/scripts/package.sh"
fi
VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
STAGE="$ROOT/tmp/dmg-staging"
DMG="$ROOT/tmp/Better Teams-$VER.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Better Teams.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Better Teams $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2>&1 | tail -3
rm -rf "$STAGE"
hdiutil verify "$DMG" 2>&1 | tail -2
echo "dmg: $DMG"
du -sh "$DMG"
