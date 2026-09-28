#!/bin/sh
# Assemble Better Teams.app from the SPM release binary. Rust first.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-rust.sh"
cd "$ROOT/swift"
swift build -c release --product OstMac
APP="$ROOT/swift/.build/release/Better Teams.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OstMac "$APP/Contents/MacOS/OstMac"
# teams-frame library shells `teams-cli tabs-all` (single auth, read-only);
# bundle it so the installed app never depends on a repo checkout.
cp "$ROOT/rust/ost/target/release/teams-cli" "$APP/Contents/Resources/teams-cli"
cp OstMac-Info.plist "$APP/Contents/Info.plist"
cp Resources/OstMac.icns "$APP/Contents/Resources/OstMac.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# TCC (mic/camera grants) sticks per signing identity: an unsigned demo
# build re-prompts every rebuild. Prefer the stable Apple Development
# identity (CODESIGN_IDENTITY wins); ad-hoc only as a loud fallback.
IDENT="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"' || true)}"
if [ -z "${IDENT:-}" ]; then
    echo "WARNING: no Apple Development identity found; signing ad-hoc (TCC will not stick)."
    codesign --force --deep --sign - "$APP"
else
    codesign --force --deep --sign "$IDENT" "$APP"
    echo "signed: $IDENT"
fi
echo "APP=$APP"
du -sh "$APP"
