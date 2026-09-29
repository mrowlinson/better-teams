#!/bin/sh
# Assemble Better Teams.app from the SPM release binary. Rust first.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMac
swift build -c release --product ostmac-mcp
APP="$ROOT/swift/.build/release/Better Teams.app"
# Assemble and sign in a per-invocation staging dir, then move the finished
# bundle into $APP: a concurrent build can no longer delete or overwrite this
# run's app mid-assembly (the old `rm -rf "$APP"` up front did exactly that).
mkdir -p "$ROOT/tmp"
STAGE="$(mktemp -d "$ROOT/tmp/build-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
FINAL="$APP"
APP="$STAGE/Better Teams.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OstMac "$APP/Contents/MacOS/OstMac"
# Settings ▸ Advanced looks this up via Bundle.main.url(forAuxiliaryExecutable:).
cp .build/release/ostmac-mcp "$APP/Contents/MacOS/ostmac-mcp"
# (teams-cli is no longer bundled: the `tabs-all` shell path is gone —
# the Rust ost core reads tabs natively, so nothing in the app runs it.)
cp OstMac-Info.plist "$APP/Contents/Info.plist"
cp Resources/OstMac.icns "$APP/Contents/Resources/OstMac.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# TCC (mic/camera grants) sticks per signing identity: an unsigned demo
# build re-prompts every rebuild. Prefer the stable Apple Development
# identity (CODESIGN_IDENTITY wins); ad-hoc only as a loud fallback.
IDENT="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
# ostmac-mcp is a loose executable in Contents/MacOS, not a nested bundle,
# so `codesign --deep` on the app won't sign it: sign it individually
# first, before the outer bundle signature.
if [ -z "${IDENT:-}" ]; then
    echo "WARNING: no Apple Development identity found; signing ad-hoc (TCC will not stick)."
    codesign --force --sign - "$APP/Contents/MacOS/ostmac-mcp"
    codesign --force --deep --sign - "$APP"
else
    # Communication notifications (sender-avatar banners) need a restricted
    # entitlement, which only launches with a matching embedded profile.
    PROFILE="$("$ROOT/scripts/find-profile.sh" "$IDENT")"
    if [ -n "$PROFILE" ]; then
        cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    fi
    codesign --force --sign "$IDENT" "$APP/Contents/MacOS/ostmac-mcp"
    codesign --force --deep --sign "$IDENT" "$APP"
    if [ -n "$PROFILE" ]; then
        codesign --force --sign "$IDENT" --entitlements OstMac.entitlements "$APP"
        echo "entitled: communication notifications"
    else
        echo "WARNING: no provisioning profile for dev.ostmac.OstMac; signing without entitlements."
    fi
    echo "signed: $IDENT"
fi
codesign --verify --deep --strict "$APP"
if [ ! -x "$APP/Contents/MacOS/ostmac-mcp" ]; then
    echo "ERROR: ostmac-mcp missing or not executable in bundle" >&2
    exit 1
fi
# Publish: two renames on one volume (old bundle aside, new bundle in), so the
# output path only ever holds a complete signed app.
if [ -e "$FINAL" ]; then
    mv "$FINAL" "$STAGE/previous.app"
fi
# A concurrent publisher may have landed in between: last complete bundle
# wins (never nest inside its directory).
rm -rf "$FINAL"
mv "$APP" "$FINAL"
APP="$FINAL"
codesign --verify --deep --strict "$APP"
echo "APP=$APP"
du -sh "$APP"
