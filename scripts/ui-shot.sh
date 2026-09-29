#!/bin/sh
# ui-shot.sh — capture one evidence route (UI-SPEC §11.4).
#
# Usage: scripts/ui-shot.sh <route> <light|dark> <out.png> [extra app flags…]
# Env:   APP=<path to Better Teams.app>  (default: release bundle from
#        scripts/build-app.sh)
#        SIZE=1280x820                   (window size)
#        INPROC=1                        in-process snapshot instead of
#                                        screencapture (no Screen Recording
#                                        permission needed; misses glass)
#        DELAY=0.4                       seconds to wait after READY
#                                        (popover/sheet animations)
#        ACTIVE=1                        activate the app and make the window
#                                        key (active appearance). Only when
#                                        nobody is using the Mac: it takes
#                                        focus. Default stays non-activating.
#        SHADOW=1                        keep the window shadow (single-window
#                                        captures; README screenshots)
#
# Launches the bundle in the BACKGROUND (`open -g`) with --demo --evidence
# (capture refuses to run without --demo); in evidence mode the app orders
# its window in without activating or taking key, so the owner's
# keystrokes never land in it while lanes capture. Waits for
# "EVIDENCE READY", finds the app's main window by PID in the window list
# (layer 0, largest), and captures only that app's pixels, whatever other
# windows cover it:
#   - one window: `screencapture -l <id> -o -x` (bounds x backing scale);
#   - window + sheets/popovers/menus of the same PID: ScreenCaptureKit,
#     display filter including only those windows, cropped to their union.
# Never a screen-region capture (it picks up foreign windows). Fails if
# the app is frontmost after the capture. Rejects captures under 20 KB, then quits
# the app. Prints "shot: <out> settled=<bool> mode=<window|composite> <w>x<h>".
#
# Demo routes, app frame + Apps library (P3a, UI-SPEC §7):
#   apps                               library, no selection
#   apps/web-demo                      app card (channel tab)
#   apps/web-demo-status               app card, opens in browser (pin disabled)
#   apps?state=loading|error|empty     channel scan: scanning / failed / none
#   apps?sheet=customizeTabBar&pins=6  Customize Tab Bar sheet
#   apps?sheet=addWebLink              Add Web Link sheet
#   apps/detail?id=<appID>             Apps store detail (APPHOST-B2)
#   apps/store?category=<name>         Apps store category
#   app/web-demo                       web app in-window (transient rail item)
#   app/web-demo-1?pins=6              pinned web app in-window
#   app/web-demo?pins=8                pins overflow into More (min height)
#   app/web-demo?state=loading         loading
#   app/web-demo?state=error           Couldn't Load ‹App›
#   app/web-demo?connection=offline    offline
#   app/web-demo?find=1                ⌘F Find in Page (toolbar field)
#   app/web-demo-status                opens-in-browser app
#
# Demo routes, Calendar + Calls + call hosts (P3b, UI-SPEC §6.4, §6.5, §8, DL1):
#   calendar                                   Agenda, no selection
#   calendar/demo-meeting                      Agenda + meeting detail
#   calendar?view=week                         Week grid (full layout)
#   calendar/demo-meeting?view=week&inspector=1  Week + meeting in inspector
#   calendar?state=empty                       No Meetings This Week + New Meeting…
#   calendar?state=loading                     loading
#   calendar?state=error                       Couldn't Load Calendar (offline)
#   calendar?sheet=newMeeting                  New Meeting sheet
#   calendar?sheet=joinMeeting                 Join with ID or Link sheet
#   calls                                      history (Recent), no selection
#   calls/demo-person                          missed call (realtime row, caller id)
#   calls?state=empty                          No Recent Calls + New Call
#   calls?sheet=newCall                        New Call sheet
#   settings/general                           Settings ▸ General (own window)
#   settings/accounts                          Settings ▸ Accounts
#   settings/notifications                     Settings ▸ Notifications
#   settings/chats                             Settings ▸ Chats
#   settings/calls                             Settings ▸ Calls (devices, meter, preview, Test Call)
#   settings/apps                              Settings ▸ Apps
#   settings/ai                                Settings ▸ AI
#   settings/advanced                          Settings ▸ Advanced
#   call?state=incoming                        incoming ring (CALL notification content in geometry; no banner in demo)
#   call?state=incoming&accept=1&presentation=main    Accept → call in the main window (DL1)
#   call?state=incoming&accept=1&presentation=window  Accept → call window (DL1)
#   call?state=prejoin&presentation=main       pre-join in the main window
#   call?state=active&presentation=main        call stage in the main window
#   call?state=prejoin&presentation=window     pre-join in the call window
#   call?state=active&presentation=window      call stage in its own window
#
# Demo routes, call experience (P4a, UI-SPEC §8, DL1; state × presentation):
#   call?state=prejoin&presentation=main       pre-join: preview, level, pickers, toggles, Join Now
#   call?state=prejoin&presentation=window
#   call?state=active&presentation=main        4 people (1 speaking, 2 muted) + self view
#   call?state=active&presentation=window
#   call?state=active&presentation=main&inspector=1       People inspector
#   call?state=active&presentation=window&inspector=1
#   call?state=active&presentation=main&inspector=chat    meeting Chat inspector
#   call?state=muted&presentation=main         self muted (toolbar Unmute, tile glyph)
#   call?state=muted&presentation=window
#   call?state=sharing&presentation=main       share tile + Stop Sharing
#   call?state=sharing&presentation=window
#   call?state=ended&presentation=main         remote end: back to previous section
#   call?state=ended&presentation=window       remote end: call window closed
#   call?state=active&presentation=main&popover=devices    Devices popover (pickers + level)
#   call?state=video&presentation=main         1:1 video: demo remote video + self view PiP
#   call?state=active&presentation=window&popover=devices
#   chat/demo-rich?call=active&presentation=main    call behind a route: rail + toolbar call items
#   chat/demo-rich?call=active&presentation=window  toolbar call item only
#
# Demo routes, Join a Team public search (WIRE, UI-SPEC §6.3):
#   teams?sheet=joinTeam                       search prompt (no query)
#   teams?sheet=joinTeam&q=re                  results (public + joined demo teams)
#   teams?sheet=joinTeam&q=zzqx                No Teams Found
#   teams?sheet=joinTeam&q=re&search=loading   searching
#   teams?sheet=joinTeam&q=re&search=error     Couldn't Search Teams + Try Again
# Demo routes, channel/team menus + tree sync (TEAMSYNC):
#   teams/demo-team-eng/demo-chan-shipping?sheet=editChannel   Edit Channel sheet
#   teams/demo-team-eng/demo-chan-shipping?deleted=1           This channel was deleted
# Demo routes, Files (P3c, UI-SPEC §6.6):
#   files/recent                               Recent (all sources), Location links
#   files/onedrive                             My Files (OneDrive)
#   files/shared                               Shared in Chats
#   files/channel:demo-chan-general            Teams › Engineering › General library
#   files/downloads                            Downloads (web app, chat, Files)
#   files?state=empty                          No Files + Upload… inside the table
#   files?state=loading                        loading
#   files?state=error                          Couldn't Load Files (offline)
#   files?state=offline                        You're offline + toolbar Offline item
#   files?popover=transfers                    Transfers popover (determinate progress)
#   files?select=demo-u-chan1                  row selected
#   files/recent/demo-file?inspector=1         inspector: info + Versions
#   files/recent/demo-file?quicklook=1         Quick Look panel
#   chat/demo-rich?tab=files                   a chat's Files tab (same table)
#   chat/demo?apptab=demo-tab-plan             a chat's pinned tab (file tab: placeholder; CHATTABS)
#   chat/demo-3?tab=recap                      a meeting chat's Recap tab (placeholder)
# Settings and presentation=window routes order the main window out, so
# the app's largest window is the one captured.
#
# Demo routes, native apps (P4b, UI-SPEC §6.7, §6.2 Notes tab):
#   app/planner                                  plans by team, No Plan Selected
#   app/planner/demo-plan-sprint                 buckets: checkbox rows, due, Add Task
#   app/planner/demo-plan-sprint/demo-ptask-1?inspector=1   task inspector
#   app/planner?state=empty|loading              No Plans / loading
#   app/planner?state=error                      You're Offline (evidence error = offline)
#   app/shifts                                   week Table (people x days, time off rows)
#   app/shifts/demo-u-megan?inspector=1          shift inspector
#   app/shifts?state=empty                       Shifts isn't set up for your teams
#   app/shifts?state=loading|error               loading / You're Offline
#   app/onenote                                  notebook outline + page + Append
#   app/onenote?state=empty|loading|error        No Notebooks / loading / You're Offline
#   app/planner/demo-plan-sprint/demo-ptask-2?inspector=1   assignees + Assign To
#   app/todo                                     lists, No List Selected
#   app/todo/demo-list-tasks                     add field, Show Completed, checkbox rows
#   app/todo?state=empty|loading|error           No Lists / loading / You're Offline
#   app/recaps                                   recaps list + filter, No Recap Selected
#   app/recaps/demo-rec-1?inspector=1            player + transcript turns + Action Items
#   app/recaps?state=empty|loading|error         No Recaps / loading / You're Offline
#   chat/demo-rich?tab=notes                     conversation Notes tab (page list, page, Append)
#
# Demo routes, Catch Up (CATCHQA; canned summaries, never the live model):
#   <any route>?catchup=off|onclick|always       the Catch Up setting (off hides the AI button)
#   settings/ai?catchup=onclick&ai=ready|unsupported|disabled|downloading   Catch Up pane + status row
#   chat/demo-3?inspector=catchup&catchup=onclick&summary=loaded|streaming|updating
#                                                inspector: mentions first, then summary states
#   chat/demo-3?catchup=always&window=catchup[&digest=updating]
#                                                Catch Up window: mentions + several chats
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 3 ] || { echo "usage: $0 <route> <light|dark> <out.png> [flags…]" >&2; exit 2; }
ROUTE="$1"; LOOK="$2"; OUT="$3"; shift 3
APP="${APP:-$ROOT/swift/.build/release/Better Teams.app}"
# Resolve symlinks (`.build/release` → `.build/out/Products/Release`):
# the running process reports its physical executable path.
[ -d "$APP" ] || { echo "ui-shot: no app bundle at $APP (run scripts/build-app.sh)" >&2; exit 2; }
APP="$(cd -P "$APP" && pwd)"
BIN="$APP/Contents/MacOS/OstMac"
[ -x "$BIN" ] || { echo "ui-shot: no app binary at $BIN (run scripts/build-app.sh)" >&2; exit 2; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
mkdir -p "$ROOT/tmp" "$(dirname "$OUT")"
LOG="$ROOT/tmp/ui-shot.$$.log"
EXTRA=""
if [ "${INPROC:-0}" = 1 ]; then EXTRA="--evidence-out $OUT"; fi

# Launched through LaunchServices (`open -g -n`): never activated, so the
# capture shows the inactive window appearance (accepted: no focus theft).
: >"$LOG"
# PIDs of this bundle already running, so the new instance is the one
# not in this list (robust to `open -n` and to path spelling).
pids_now() {
    { pgrep -f "^$BIN( |\$)" 2>/dev/null
      [ -n "$BUNDLE_ID" ] && lsappinfo list 2>/dev/null | awk -v id="\"$BUNDLE_ID\"" \
          '/bundleID=/ { f = (index($0, "bundleID=" id) > 0) } f && /pid = / { sub(/.*pid = /, ""); sub(/[^0-9].*/, ""); print; f = 0 }'
    } | sort -u
}
BEFORE=" $(pids_now | tr '\n' ' ') "
front_pid() { lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*pid = \([0-9][0-9]*\).*/\1/p'; }
BG="-g"
if [ "${ACTIVE:-0}" = 1 ]; then BG=""; EXTRA="$EXTRA --evidence-active"; fi
# shellcheck disable=SC2086
open $BG -n -a "$APP" --stdout "$LOG" --stderr "$LOG" --args --demo --evidence --route "$ROUTE" \
    --appearance "$LOOK" --window-size "${SIZE:-1280x820}" $EXTRA "$@" -ApplePersistenceIgnoreState YES
PID=""
DEADLINE=$((SECONDS + 10))
while [ -z "$PID" ] && [ $SECONDS -lt $DEADLINE ]; do
    for p in $(pids_now); do
        case "$BEFORE" in *" $p "*) ;; *) PID=$p ;; esac
    done
    [ -z "$PID" ] && sleep 0.2
done
[ -n "$PID" ] || { echo "ui-shot: app did not start ($ROUTE)" >&2; exit 1; }

READY=""
DEADLINE=$((SECONDS + 40))
while [ $SECONDS -lt $DEADLINE ]; do
    READY=$(grep -m1 '^EVIDENCE READY' "$LOG" 2>/dev/null || true)
    [ -n "$READY" ] && break
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.25
done

status=0
if [ -z "$READY" ]; then
    echo "ui-shot: no READY line for $ROUTE ($LOOK); log: $LOG" >&2
    status=1
else
    SETTLED=$(printf '%s\n' "$READY" | sed -n 's/.*settled=\([a-z]*\).*/\1/p')
    MODE=""
    if [ "${INPROC:-0}" != 1 ]; then
        sleep "${DELAY:-0.4}"
        rm -f "$OUT"
        # Writes $OUT and prints "window <id> <w> <h>" (screencapture -l)
        # or "composite <n> <w> <h>" (ScreenCaptureKit).
        RECT=$(printf '%s\n' "$READY" | sed -n 's/.*rect=\([0-9,-]*\).*/\1/p')
        MODE=$(UI_SHOT_PID="$PID" UI_SHOT_OUT="$OUT" UI_SHOT_RECT="$RECT" UI_SHOT_SHADOW="${SHADOW:-0}" swift - 2>>"$LOG" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let env = ProcessInfo.processInfo.environment
guard let pid = Int32(env["UI_SHOT_PID"] ?? ""), let out = env["UI_SHOT_OUT"] else { exit(2) }
_ = CGMainDisplayID()
struct Win { let id: CGWindowID; let layer: Int; let rect: CGRect }
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]) ?? []
let mine: [Win] = list.compactMap { d in
    guard (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          let id = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
          let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue,
          let b = d[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: b as CFDictionary),
          r.width > 1, r.height > 1, (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0
    else { return nil }
    return Win(id: id, layer: layer, rect: r)
}
guard let main = mine.filter({ $0.layer == 0 })
    .max(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })
else { fputs("ui-shot: no on-screen window for pid \(pid)\n", stderr); exit(1) }
// Sheets, popovers and menus of the app over its main window: menus and
// popups (layer > 0, not the menu bar / status layers 24-25), and layer-0
// windows inside the window+popover+sheet rect the app reports in READY (a
// transparent helper window hangs below the window when inactive).
let r = (env["UI_SHOT_RECT"] ?? "").split(separator: ",").compactMap { Double($0) }
let ready = r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : main.rect
let floats = mine.filter {
    guard $0.id != main.id, $0.rect.intersects(main.rect) else { return false }
    return $0.layer == 0 ? ready.insetBy(dx: -1, dy: -1).contains($0.rect) : !(24...25).contains($0.layer)
}
func writePNG(_ image: CGImage, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
}
if floats.isEmpty, env["UI_SHOT_CHILDREN"] != "1",
   let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
   let win = content.windows.first(where: { $0.windowID == main.id }) {
    // The window alone, without its child windows: AppKit parents the
    // system input-source indicator (NSCampoLightweightUIHostWindow) to
    // the window once a text view exists, and `screencapture -l` would
    // shoot that bubble over the composer. UI_SHOT_CHILDREN=1 keeps them.
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let cfg = SCStreamConfiguration()
    // SHADOW=1 keeps the window shadow (README shots); else window pixels only.
    cfg.ignoreShadowsSingleWindow = env["UI_SHOT_SHADOW"] != "1"
    let scale = CGFloat(filter.pointPixelScale)
    // The shadow is fitted into the output size: pad by the 23 pt margin
    // `screencapture -l` gives the shadow on each side so pixels stay 1:1.
    let pad: CGFloat = cfg.ignoreShadowsSingleWindow ? 0 : 46
    cfg.width = Int(((filter.contentRect.width + pad) * scale).rounded())
    cfg.height = Int(((filter.contentRect.height + pad) * scale).rounded())
    cfg.includeChildWindows = false
    cfg.showsCursor = false
    cfg.backgroundColor = .clear
    do {
        let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        writePNG(image, to: out)
        print("window \(main.id) \(Int(main.rect.width)) \(Int(main.rect.height))")
        exit(0)
    } catch {
        fputs("ui-shot: ScreenCaptureKit window: \(error); falling back to screencapture -l\n", stderr)
    }
}
if floats.isEmpty {
    // `screencapture -l` also shoots the child windows of the window (a
    // transparent helper hangs below it when inactive): crop back to the
    // window itself so the shot is its bounds x backing scale.
    let raw = out + ".l.png"
    let sc = Process()
    sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // SHADOW=1 keeps the window shadow (README shots); else window pixels only.
    sc.arguments = ["-l\(main.id)"] + (env["UI_SHOT_SHADOW"] == "1" ? [] : ["-o"]) + ["-x", raw]
    try? sc.run()
    sc.waitUntilExit()
    guard sc.terminationStatus == 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: raw) as CFURL, nil),
          let shot = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fputs("ui-shot: screencapture -l\(main.id) failed\n", stderr); exit(1) }
    let u = mine.filter { $0.layer == 0 && $0.rect.intersects(main.rect) }.reduce(main.rect) { $0.union($1.rect) }
    let k = CGFloat(shot.width) / u.width
    if u != main.rect, abs(CGFloat(shot.height) - u.height * k) < 1,
       let cut = shot.cropping(to: CGRect(x: (main.rect.minX - u.minX) * k, y: (main.rect.minY - u.minY) * k,
                                          width: main.rect.width * k, height: main.rect.height * k).integral) {
        writePNG(cut, to: out)
        try? FileManager.default.removeItem(atPath: raw)
    } else {
        try? FileManager.default.removeItem(atPath: out)
        guard (try? FileManager.default.moveItem(atPath: raw, toPath: out)) != nil else { exit(1) }
    }
    print("window \(main.id) \(Int(main.rect.width)) \(Int(main.rect.height))")
    exit(0)
}
for w in [main] + floats { fputs("ui-shot: window \(w.id) layer=\(w.layer) \(w.rect)\n", stderr) }
let union = floats.reduce(main.rect) { $0.union($1.rect) }
let ids = Set([main.id] + floats.map(\.id))
do {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let wins = content.windows.filter { ids.contains($0.windowID) }
    guard let display = content.displays.first(where: { $0.frame.intersects(main.rect) }) else { exit(1) }
    let filter = SCContentFilter(display: display, including: wins)
    let scale = CGFloat(filter.pointPixelScale)
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = union.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    cfg.width = Int((union.width * scale).rounded())
    cfg.height = Int((union.height * scale).rounded())
    cfg.showsCursor = false
    cfg.backgroundColor = .clear
    let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    writePNG(image, to: out)
    print("composite \(wins.count) \(Int(union.width)) \(Int(union.height))")
} catch {
    fputs("ui-shot: ScreenCaptureKit: \(error)\n", stderr)
    exit(1)
}
SWIFT
        ) || status=1
        set -- $MODE
        # Composite shots list the windows they combined.
        [ "${1:-}" = composite ] && grep '^ui-shot: ' "$LOG" >&2
        MODE="${1:-none} ${3:-0}x${4:-0}pt"
    fi
    if [ "${ACTIVE:-0}" != 1 ] && [ "$(front_pid)" = "$PID" ]; then
        echo "ui-shot: evidence app became frontmost ($ROUTE) — focus theft" >&2
        status=1
    fi
    if [ ! -f "$OUT" ]; then
        echo "ui-shot: capture failed for $ROUTE ($LOOK)" >&2
        status=1
    elif [ "$(stat -f%z "$OUT")" -lt 20000 ]; then
        echo "ui-shot: rejected $OUT (<20 KB: blank or single color)" >&2
        status=1
    else
        echo "shot: $OUT settled=$SETTLED mode=$MODE"
    fi
fi
kill "$PID" 2>/dev/null
QUIT=$((SECONDS + 5))
while kill -0 "$PID" 2>/dev/null && [ $SECONDS -lt $QUIT ]; do sleep 0.2; done
kill -9 "$PID" 2>/dev/null
[ $status -eq 0 ] && rm -f "$LOG"
exit $status
