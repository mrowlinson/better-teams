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
import WebKit
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
        // `hover=<messageID>`: pin that message's hover toolbar for the capture.
        MessageHover.evidence.shownID = options.route.flatMap(Route.init(string:))?.query["hover"]
        // `contact=<name>`: pin that person's hover card (also inside the
        // New Chat sheet); with `sheet=contactCard` it names the full card.
        let query = options.route.flatMap(Route.init(string:))?.query
        if query?["sheet"] != ContactActions.sheetName { ContactHover.shared.pinnedName = query?["contact"] }
        let deadline = Date().addingTimeInterval(10)
        let earliest = Date().addingTimeInterval(0.8)
        var quiet = 0
        func tick() {
            guard let window = wc.window else { return }
            let ready = storesReady(wc.model) && ImageViewerEvidence.ready(wc, route: options.route)
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
        if let root = wc.window?.contentView { revealTimelineHeaders(root) }
        if let path = options.snapshotPath, let w = wc.window {
            // Web views snapshot asynchronously: READY only once written.
            Task { @MainActor in
                await snapshot(w, to: path)
                ready(wc, options: options, settled: settled, main: main, win: win)
            }
            return
        }
        ready(wc, options: options, settled: settled, main: main, win: win)
    }

    private static func ready(_ wc: ShellWindowController, options: LaunchOptions, settled: Bool,
                              main: NSWindow?, win: Int) {
        // A text field in a sheet/popover that takes first responder makes
        // the system draw its input-source badge (a bright white rounded
        // square, undimmed by the sheet scrim) over the composer: capture
        // with no field editing anywhere in the app.
        for w in NSApp.windows { w.makeFirstResponder(nil) }
        // The text-input UI hosts (TUINSWindow, NSCampoLightweightUIHostWindow)
        // draw the input-source badge at the composer caret once a
        // popover/sheet is up, above the scrim: keep them ordered out
        // while the capture settles.
        let hideBadge = {
            for w in NSApp.windows {
                let name = String(describing: type(of: w))
                if name.hasPrefix("TUI") || name.contains("Campo") { w.orderOut(nil) }
            }
        }
        hideBadge()
        let until = Date().addingTimeInterval(8)
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            MainActor.assumeIsolated {
                hideBadge()
                if Date() > until { t.invalidate() }
            }
        }
        EvidenceGeometry.append(wc, route: options.route, appearance: options.appearance)
        if options.dumpMenus, let bar = NSApp.mainMenu {
            print("EVIDENCE MENUS BEGIN\n\(MainMenu.dump(bar))EVIDENCE MENUS END")
        }
        print("EVIDENCE READY route=\(options.route ?? "-") appearance=\(options.appearance ?? "system") "
            + "windowID=\(win) settled=\(settled)" + (main.map { " rect=\(captureRect($0))" } ?? ""))
        fflush(stdout)
        if options.route.flatMap(Route.init(string:))?.query["recents"] == "1" { showRecents(wc) }
    }

    /// Whole sender header at the top of every visible timeline.
    private static func revealTimelineHeaders(_ v: NSView) {
        if let vc = (v as? NSTableView)?.delegate as? TimelineViewController {
            vc.evidenceRevealTopHeader()
            v.window?.displayIfNeeded()
        }
        for s in v.subviews { revealTimelineHeaders(s) }
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
    /// `cacheDisplay` leaves a WKWebView blank (it paints out of
    /// process), so each visible web view's own `takeSnapshot` is drawn
    /// over its visible rect.
    static func snapshot(_ w: NSWindow, to path: String) async {
        guard let frameView = w.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        var shots: [(NSImage, NSRect)] = []
        for web in webViews(in: frameView) where !web.isHiddenOrHasHiddenAncestor {
            let visible = web.visibleRect
            guard !visible.isEmpty else { continue }
            let config = WKSnapshotConfiguration()
            config.rect = visible
            guard let image = try? await web.takeSnapshot(configuration: config) else { continue }
            var r = web.convert(visible, to: frameView)
            if frameView.isFlipped { r.origin.y = bounds.height - r.maxY }
            shots.append((image, r))
        }
        if !shots.isEmpty, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for (image, r) in shots { image.draw(in: r) }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    private static func webViews(in v: NSView) -> [WKWebView] {
        if let w = v as? WKWebView { return [w] }
        return v.subviews.flatMap(webViews)
    }
}
