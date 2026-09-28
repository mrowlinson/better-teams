// EvidenceHarness.swift — visual-evidence harness (UI-SPEC §11.4).
//
// Demo only. After the route is applied and startup finishes, waits for
// the stores to settle and the window to display, then prints
//   EVIDENCE READY route=<r> appearance=<a> windowID=<n> settled=true|false rect=<x,y,w,h>
// (10 s hard cap). `rect` is the window plus its popovers and sheets,
// in screen-capture coordinates (points, top-left origin), so a region
// capture shows exactly the window with what floats over it. The window stays frontmost at a fixed origin until
// killed. `--evidence-out` also writes an in-process snapshot.
import AppKit
import OstMacCore
import SwiftUI

@MainActor
enum EvidenceHarness {
    /// The route's primary window when it is not the main window
    /// (Settings, the separate call window; `CallEvidence`).
    static weak var primaryWindow: NSWindow?

    /// Positive control (`evidence/control`): a fixed test card.
    static func showControl(in wc: ShellWindowController) {
        wc.window?.contentViewController = Hosting.controller(EvidenceControlView(), role: .pane, model: wc.model)
        wc.window?.title = "Evidence Control"
        wc.window?.setContentSize(wc.model.options.windowSize ?? NSSize(width: 1280, height: 820))
    }

    static func settle(_ wc: ShellWindowController, options: LaunchOptions) {
        let deadline = Date().addingTimeInterval(10)
        let earliest = Date().addingTimeInterval(0.8)
        var quiet = 0
        func tick() {
            guard let window = wc.window else { return }
            let ready = storesReady(wc.model)
            if ready {
                window.displayIfNeeded()
                quiet += 1
            } else {
                quiet = 0
            }
            if ready, quiet >= 3, Date() >= earliest {
                emit(wc, options: options, settled: true)
            } else if Date() >= deadline {
                emit(wc, options: options, settled: false)
            } else {
                DispatchQueue.main.async { tick() }
            }
        }
        DispatchQueue.main.async { tick() }
    }

    private static func storesReady(_ m: WindowModel) -> Bool {
        if m.graph.chats.state == .loading { return false }
        if m.nav.section == .chat, let id = m.nav.selection(in: .chat)?.id, m.forced(.chat) == nil {
            if m.graph.conv.chatID != id || m.graph.conv.loading { return false }
        }
        // Teams list and the open channel (P2c).
        if m.nav.section == .teams, m.forced(.teams) == nil, let app = m.app {
            if app.teams.state == .loading { return false }
            if let ch = TeamsSelection(m.nav.selection(in: .teams))?.channelID,
               m.graph.conv.chatID != ch || m.graph.conv.loading { return false }
        }
        // Calendar week and the meeting join parse (P3b).
        if let app = m.app, m.nav.section == .calendar, m.forced(.calendar) == nil,
           app.calWeek.state == .loading { return false }
        if let app = m.app, app.meetings.parsing { return false }
        // Search results and Activity/Search landings (P2b).
        if m.nav.search != nil, let app = m.app {
            if app.messageSearch.isSearching || app.localSearch.isSearching || app.filePeople.isSearching { return false }
        }
        if m.nav.search != nil || (m.nav.section == .activity && m.nav.selection(in: .activity) != nil) {
            if m.graph.conv.loading { return false }
        }
        return true
    }

    private static func emit(_ wc: ShellWindowController, options: LaunchOptions, settled: Bool) {
        // A presented sheet is its own window; capture it instead.
        let main = primaryWindow ?? wc.window
        let win = (main?.attachedSheet ?? main)?.windowNumber ?? 0
        if let path = options.snapshotPath, let w = wc.window { snapshot(w, to: path) }
        EvidenceGeometry.append(wc, route: options.route, appearance: options.appearance)
        if options.dumpMenus, let bar = NSApp.mainMenu {
            print("EVIDENCE MENUS BEGIN\n\(MainMenu.dump(bar))EVIDENCE MENUS END")
        }
        print("EVIDENCE READY route=\(options.route ?? "-") appearance=\(options.appearance ?? "system") "
            + "windowID=\(win) settled=\(settled)" + (main.map { " rect=\(captureRect($0))" } ?? ""))
        fflush(stdout)
        if options.route.flatMap(Route.init(string:))?.query["recents"] == "1" { showRecents(wc) }
    }

    /// `<route>?recents=1` (§5.5 recents, G1): focuses the empty search
    /// field and clicks its magnifier, which opens the field's native
    /// Recent Searches menu. After READY: the menu tracks modally and is
    /// its own window, so the capture script shoots the screen region.
    private static func showRecents(_ wc: ShellWindowController) {
        guard let window = wc.window, let item = wc.toolbarController.searchItem,
              let cell = item.searchField.cell as? NSSearchFieldCell else { return }
        let field = item.searchField
        field.recentSearches = wc.model.app?.searchRecents.recents ?? []
        window.makeFirstResponder(field)
        let r = cell.searchButtonRect(forBounds: field.bounds)
        let p = field.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        DispatchQueue.main.async { window.sendEvent(down) }
    }

    /// The window's frame united with its popovers, child windows and
    /// sheet, as "x,y,w,h" in top-left-origin screen points
    /// (`screencapture -R`).
    private static func captureRect(_ w: NSWindow) -> String {
        var r = w.frame
        for other in NSApp.windows where other.isVisible && other !== w {
            let floats = other.sheetParent === w || other.parent === w
                || String(describing: type(of: other)).contains("Popover")
            if floats { r = r.union(other.frame) }
        }
        let top = NSScreen.screens.first?.frame.maxY ?? r.maxY
        return "\(Int(r.minX.rounded())),\(Int((top - r.maxY).rounded())),"
            + "\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }

    /// In-process window snapshot (used when screen capture is not
    /// permitted). Renders the window's frame view, titlebar included.
    static func snapshot(_ w: NSWindow, to path: String) {
        guard let frameView = w.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
