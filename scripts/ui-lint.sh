#!/bin/sh
# ui-lint.sh — enforce the UI-SPEC §3 [lint] rules over the UI target.
#
# Usage: scripts/ui-lint.sh [dir]   (default: swift/Sources/BetterTeamsUI)
# Prints one "[Rn] path:line: text" per hit; exits 1 on any hit, 0 clean.
# Allowlists are the exact files the spec names (R7 Debounce + RelativeTime/CallSession for Timer, R8 RailView,
# R14 Palette/AppFont, R16 FrameHost, R22 Hosting, R27 Call/, R1/R7+/R15 Timeline/ImageViewerChrome).
# P1 adds R4+ R7+ R9+ R10+ R21-R28.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT/swift/Sources/BetterTeamsUI}"
GREP=/usr/bin/grep
HITS=0

if [ ! -d "$DIR" ]; then
    echo "ui-lint: no such directory: $DIR" >&2
    exit 2
fi

# check RULE PATTERN [INCLUDE_GLOB] [ALLOW_PATH_REGEX]
check() {
    rule="$1"; pat="$2"; include="${3:-*.swift}"; allow="${4:-}"
    out=$("$GREP" -rnE --include="$include" -e "$pat" "$DIR" 2>/dev/null)
    if [ -n "$out" ] && [ -n "$allow" ]; then
        out=$(printf '%s\n' "$out" | "$GREP" -vE "^[^:]*($allow):" || true)
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed "s/^/[$rule] /"
        n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
        HITS=$((HITS + n))
    fi
}

# R1 no custom window chrome (the image viewer's media window is the one exception)
check R1 'titlebarAppearsTransparent|standardWindowButton\(|titleVisibility *= *\.hidden|styleMask[^/]*\.borderless' '*.swift' '/Timeline/ImageViewerChrome\.swift'
# R4 stable identity
check R4 '\.id\(UUID|\.id\(Date'
# R6 no scroll views inside rows
check R6 'ScrollView' '*Row.swift'
# R7 no timing hacks (Search/Debounce.swift is the one exception)
check R7 'DispatchQueue\.main\.asyncAfter|Task\.sleep|RunLoop\.(current|main)\.run|CFRunLoopRunInMode' '*.swift' '/Search/Debounce\.swift'
# R8 geometry readers only in RailView
check R8 'GeometryReader|onGeometryChange' '*.swift' '/Rail/RailView\.swift'
# R10 keys come from menu key equivalents, never event monitors
check R10 'addLocalMonitor|addGlobalMonitor'
# R11 views never call the FFI
check R11 'RustCore\.|ReadCore\.'
# R14 literal colors only in Palette.swift, literal sizes only in AppFont.swift
check R14 'Color\(red:|NSColor\(red:|calibratedRed' '*.swift' '/Shared/Palette\.swift'
check R14 '\.system\(size:' '*.swift' '/Shared/AppFont\.swift'
# R15 no Liquid Glass / visual-effect views in the content layer (image viewer HUD bar excepted)
check R15 '\.glassEffect|NSVisualEffectView' '*.swift' '/Timeline/ImageViewerChrome\.swift'
# R16 web views are created only by FrameHost
check R16 'WKWebView\(' '*.swift' '/Frame/FrameHost\.swift'
# R20 no deleted modules
check R20 'import +(BTDesign|OstMacChatList)([^A-Za-z0-9_]|$)'

# --- [lint+] patterns (P1, 2026-09-27 review) ---
# R4+ no .id( modifier, no id: \.self, no ForEach over indices/enumerated()
check R4 '\.id\('
check R4 'id: *\\\.self'
check R4 'ForEach\([^)]*\.(indices|enumerated\(\))'
# R7+ Timer only in the shared relative-time ticker, CallSession and the viewer's GIF frame stepper
check R7 '(^|[^A-Za-z0-9_])Timer *(\.|\()' '*.swift' '/Shared/RelativeTime\.swift|/Call/CallSession\.swift|/Timeline/ImageViewerChrome\.swift'
# R9+ .animation( always takes value:
check R9 '\.animation\([^,)]*\)'
# R10+ no .focusable( additions
check R10 '\.focusable\('
# R21 AppKit never observes NavigationModel asynchronously
check R21 'withObservationTracking|Observations *[({]'
# R22 one hosting factory
check R22 'NSHostingController\(|NSHostingView\(' '*.swift' '/Shared/Hosting\.swift'
# R23 no SwiftUI scene chrome
check R23 '\.toolbar *[({]|\.navigationTitle\(|\.navigationSubtitle\(|\.searchable\(|NavigationSplitView|NavigationStack|\.inspector\(isPresented|\.sheet\((isPresented|item):|\.alert\(|\.confirmationDialog\(|\.listStyle\(\.sidebar\)|@EnvironmentObject'
# R27 .ignoresSafeArea only in Call/ (video stage)
check R27 '\.ignoresSafeArea' '*.swift' '/Call/'
# R28 views never observe AppState/AccountGraph wholesale
check R28 '@(ObservedObject|StateObject)[^:]*: *(any +)?(AppState|AccountGraph)([^A-Za-z0-9_]|$)'
# R18+ no build-process names in user-visible strings: a lane name
# ("lane P3b") inside a string literal is dev placeholder copy.
check R18 '"[^"]*[Ll]ane +P[0-9]'

if [ "$HITS" -gt 0 ]; then
    echo "ui-lint: $HITS hit(s) in $DIR" >&2
    exit 1
fi
echo "ui-lint: 0 hits in $DIR"
