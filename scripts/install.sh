#!/bin/bash
# Install release Better Teams.app to /Applications (builds first if missing).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/tmp/Better Teams.app"
if [[ ! -x "$APP/Contents/MacOS/OstMac" ]]; then
    "$ROOT/scripts/package.sh"
fi
rm -rf "/Applications/Better Teams.app"
cp -R "$APP" "/Applications/Better Teams.app"
codesign --verify --verbose=1 "/Applications/Better Teams.app"
echo "installed: /Applications/Better Teams.app"
du -sh "/Applications/Better Teams.app"
