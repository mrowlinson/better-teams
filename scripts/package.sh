#!/bin/bash
# Build release + wrap in Better Teams.app (real identity, icon, signed).
# Usage: scripts/package.sh [--install]   (--install copies to /Applications)
#
# Signing: CODESIGN_IDENTITY env wins; else the first "Apple Development"
# identity from `security find-identity`; else ad-hoc (loud warning).
# Mirrors TeamsNotifier Scripts/package.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMac 2>&1 | tail -2

APP="$ROOT/tmp/Better Teams.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OstMac "$APP/Contents/MacOS/OstMac"
cp OstMac-Info.plist "$APP/Contents/Info.plist"
cp Resources/OstMac.icns "$APP/Contents/Resources/OstMac.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENT="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
if [[ -z "${IDENT:-}" ]]; then
    echo "WARNING: no Apple Development identity found; signing ad-hoc."
    echo "WARNING: set CODESIGN_IDENTITY to sign with a real identity."
    codesign --force --sign - "$APP/Contents/MacOS/OstMac"
    codesign --force --sign - "$APP"
else
    echo "signing with: $IDENT"
    codesign --force --sign "$IDENT" "$APP/Contents/MacOS/OstMac"
    codesign --force --sign "$IDENT" "$APP"
fi
codesign --verify --verbose=1 "$APP"

echo "built: $APP"
du -sh "$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Better Teams.app"
    cp -R "$APP" "/Applications/Better Teams.app"
    echo "installed: /Applications/Better Teams.app"
fi
