#!/bin/bash
# Render swift/Resources/OstMac.icns (chat-bubble motif) via iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/swift/Resources/OstMac.icns"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
ICONSET="$TMPD/OstMac.iconset"
mkdir -p "$ICONSET" "$ROOT/swift/Resources"
swift "$ROOT/scripts/make-icon.swift" "$TMPD/icon-1024.png"
sips -z 16 16     "$TMPD/icon-1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$TMPD/icon-1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$TMPD/icon-1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$TMPD/icon-1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$TMPD/icon-1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$TMPD/icon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$TMPD/icon-1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$TMPD/icon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$TMPD/icon-1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$TMPD/icon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$OUT"
ls -lh "$OUT"
