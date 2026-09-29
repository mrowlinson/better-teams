#!/bin/bash
# Build release + wrap in Better Teams.app (real identity, icon, signed).
# Usage: scripts/package.sh [--install]   (--install copies to /Applications)
# PACKAGE_OUT_DIR overrides where the .app is built (default <repo>/tmp).
#
# Signing: CODESIGN_IDENTITY env wins; else the first "Apple Development"
# identity from `security find-identity`; else ad-hoc (loud warning).
# Mirrors TeamsNotifier Scripts/package.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMac 2>&1 | tail -2
swift build -c release --product ostmac-mcp 2>&1 | tail -2

OUT_DIR="${PACKAGE_OUT_DIR:-$ROOT/tmp}"
mkdir -p "$OUT_DIR"
APP="$OUT_DIR/Better Teams.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OstMac "$APP/Contents/MacOS/OstMac"
# Settings > Advanced looks this up via Bundle.main.url(forAuxiliaryExecutable:).
cp .build/release/ostmac-mcp "$APP/Contents/MacOS/ostmac-mcp"
cp OstMac-Info.plist "$APP/Contents/Info.plist"
cp Resources/OstMac.icns "$APP/Contents/Resources/OstMac.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENT="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
if [[ -z "${IDENT:-}" ]]; then
    echo "WARNING: no Apple Development identity found; signing ad-hoc."
    echo "WARNING: set CODESIGN_IDENTITY to sign with a real identity."
    # ostmac-mcp is a loose executable in Contents/MacOS: sign it on its own
    # before the outer bundle signature (same order as build-app.sh).
    codesign --force --sign - "$APP/Contents/MacOS/ostmac-mcp"
    codesign --force --sign - "$APP/Contents/MacOS/OstMac"
    codesign --force --sign - "$APP"
else
    echo "signing with: $IDENT"
    # Communication notifications (sender-avatar banners) need a restricted
    # entitlement, which only launches with a matching embedded profile.
    PROFILE="$("$ROOT/scripts/find-profile.sh" "$IDENT")"
    ENT=()
    if [[ -n "$PROFILE" ]]; then
        cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
        ENT=(--entitlements OstMac.entitlements)
        echo "entitled: communication notifications"
    else
        echo "WARNING: no provisioning profile for dev.ostmac.OstMac; signing without entitlements."
    fi
    codesign --force --sign "$IDENT" "$APP/Contents/MacOS/ostmac-mcp"
    codesign --force --sign "$IDENT" "$APP/Contents/MacOS/OstMac"
    codesign --force --sign "$IDENT" ${ENT[@]+"${ENT[@]}"} "$APP"
fi
codesign --verify --deep --strict --verbose=1 "$APP"
if [ ! -x "$APP/Contents/MacOS/ostmac-mcp" ]; then
    echo "ERROR: ostmac-mcp missing or not executable in bundle" >&2
    exit 1
fi

echo "built: $APP"
du -sh "$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Better Teams.app"
    cp -R "$APP" "/Applications/Better Teams.app"
    echo "installed: /Applications/Better Teams.app"
fi
