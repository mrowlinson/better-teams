// ContactHoverEventTests.swift — HOVERFIX: pointing at a person's name,
// avatar or @mention in the timeline shows the contact hover card after
// the dwell, and the card stays up. Real AppKit mouse events go into the
// row's hosting view (through its own tracking area) or the mention
// tracker, so SwiftUI's onHover, the dwell, the popover and the card's
// own layout all run as in the app. Since 132dac4 the card scrolls past a
// height cap; its clip view's first layout reached the app-wide scroll
// observer, which hid every card the moment it appeared.
// Nothing reaches a display: the window only records order-in and sits
// far outside every screen; presenting the popover orders both into the
// window server there, never onto a display (asserted).
import AppKit
import XCTest
@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class ContactHoverEventTests: XCTestCase {
    private let hover = ContactHover.shared

    override func setUp() {
        super.setUp()
        AppSettings.useDemoStorage()
        CallSettings.useDemoStorage()
        hover.dismiss()
    }

    override func tearDown() {
        hover.dismiss()
        spin(0.3) // let the popover close before the next test
        super.tearDown()
    }

    // MARK: harness

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The demo showcase thread in a timeline, laid out in an off-screen
    /// window, scrolled to the newest message.
    private func timeline() -> (TimelineViewController, NSWindow, NSTableView) {
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        let conv = ConversationStore()
        conv.showDemo(chatID: DemoData.showcaseID, chatName: "Product Team",
                      messages: DemoData.messages(for: DemoData.showcaseID))
        let vc = TimelineViewController(conv: conv, model: m)
        _ = vc.view
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 700),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.isReleasedWhenClosed = false
        addTeardownBlock { _ = nav; _ = app; window.close() }
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 900, height: 700))
        window.orderFront(nil) // recorded only
        let table = views(of: NSTableView.self, in: window.contentView!).first!
        let deadline = Date().addingTimeInterval(8)
        repeat {
            table.tile()
            table.scrollRowToVisible(table.numberOfRows - 1)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            spin(0.1)
        } while vc.visibleMessageIDs.isEmpty && Date() < deadline
        XCTAssertFalse(vc.visibleMessageIDs.isEmpty, "control: timeline rows laid out")
        return (vc, window, table)
    }

    private func views<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(of: type, in: $0) }
    }

    /// Row hosting views on screen, top to bottom.
    private func rowHosts(_ window: NSWindow) -> [NSView] {
        func walk(_ v: NSView) -> [NSView] {
            String(describing: type(of: v)).contains("TimelineRowContent") ? [v] : v.subviews.flatMap(walk)
        }
        return walk(window.contentView!).sorted {
            $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
        }
    }

    /// An enter/exit event the window server would send for `area`.
    private func enterExit(_ type: NSEvent.EventType, _ view: NSView, _ area: NSTrackingArea,
                           _ p: NSPoint) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                               trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil)!
    }

    private func moved(_ view: NSView, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(p, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: 0, pressure: 0)!
    }

    private struct Target {
        let anchor: String
        let point: NSPoint
        let enter: () -> Void
        let exit: () -> Void
    }

    /// Hover targets in a row's header band: the pointer enters each
    /// point through the row host's own tracking area; a point whose
    /// entry registers a new contact anchor is a target (avatar, name).
    private func headerTargets(_ host: NSView) -> [Target] {
        guard let area = host.trackingAreas.first(where: { $0.owner === host }) else { return [] }
        var found: [Target] = []
        for y in stride(from: CGFloat(4), through: 28, by: 4) {
            for x in stride(from: CGFloat(4), through: 320, by: 6) {
                let p = NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y)
                host.mouseEntered(with: enterExit(.mouseEntered, host, area, p))
                let anchor = hover.pointerAnchor
                host.mouseExited(with: enterExit(.mouseExited, host, area, p))
                guard let anchor, !found.contains(where: { $0.anchor == anchor }) else { continue }
                found.append(Target(
                    anchor: anchor, point: p,
                    enter: { [unowned self] in host.mouseEntered(with: enterExit(.mouseEntered, host, area, p)) },
                    exit: { [unowned self] in host.mouseExited(with: enterExit(.mouseExited, host, area, p)) }))
            }
        }
        hover.dismiss()
        return found.sorted { $0.point.x < $1.point.x }
    }

    /// Windows other than `window` that hold a hover card.
    private func cardWindows(besides window: NSWindow) -> [NSWindow] {
        NSApp.windows.filter { w in
            w !== window && w.contentView.map { !views(of: CardWindowReporter.ReporterView.self, in: $0).isEmpty } == true
        }
    }

    /// Of `windows`, the window-server windows that touch any display.
    private func onDisplays(_ windows: [NSWindow]) -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let displays = NSScreen.screens.map(\.frame)
        let numbers = Set(windows.map(\.windowNumber))
        return info.filter { ($0[kCGWindowNumber as String] as? Int).map(numbers.contains) == true }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
            .filter { r in displays.contains { d in
                // CG bounds are top-left based; X is the same in both spaces.
                r.maxX > d.minX && r.minX < d.maxX
            } }
    }

    /// Points at `target`, waits out the dwell, and checks the card is up,
    /// presented in a popover, and still up well after it appeared.
    private func assertCardShowsAndStays(_ target: Target, in window: NSWindow, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        target.enter()
        XCTAssertEqual(hover.pointerAnchor, target.anchor, "\(what): pointer registered", file: file, line: line)
        XCTAssertNil(hover.shownAnchor, "\(what): no card before the dwell", file: file, line: line)
        let deadline = Date().addingTimeInterval(3)
        while hover.shownAnchor == nil, Date() < deadline { spin(0.01) }
        XCTAssertEqual(hover.shownAnchor, target.anchor, "\(what): card never came up", file: file, line: line)
        spin(0.8) // the card lays out, loads its sections and resizes meanwhile
        XCTAssertEqual(hover.shownAnchor, target.anchor, "\(what): card hid itself after appearing",
                       file: file, line: line)
        XCTAssertFalse(cardWindows(besides: window).isEmpty, "\(what): no popover holds the card",
                       file: file, line: line)
        XCTAssertEqual(onDisplays([window] + cardWindows(besides: window)), [],
                       "\(what): the test window or its card reached a display", file: file, line: line)
        target.exit()
        hover.dismiss()
        spin(0.3)
    }

    // MARK: tests

    /// Sender avatar and name of a message header: the card comes up
    /// after the dwell and stays.
    func testSenderAvatarAndNameHoverShowsCardThatStays() {
        let (_, window, _) = timeline()
        let targets = rowHosts(window).lazy.map(headerTargets).first { $0.count >= 2 }
        guard let targets else { return XCTFail("no header row with an avatar and a name anchor") }
        assertCardShowsAndStays(targets[0], in: window, "avatar")
        assertCardShowsAndStays(targets[1], in: window, "sender name")
    }

    /// An @mention in message text (its own tracker view, AppKit events).
    func testMentionHoverShowsCardThatStays() {
        let (_, window, table) = timeline()
        var target: Target?
        rows: for row in stride(from: table.numberOfRows - 1, through: 0, by: -1) {
            table.scrollRowToVisible(row)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            spin(0.05)
            for tracker in views(of: MentionTrackingView.self, in: window.contentView!) where tracker.bounds.width > 0 {
                for y in stride(from: CGFloat(3), to: tracker.bounds.height, by: 4) {
                    for x in stride(from: CGFloat(2), to: tracker.bounds.width, by: 6) {
                        let p = NSPoint(x: x, y: y)
                        tracker.mouseMoved(with: moved(tracker, p))
                        guard let anchor = hover.pointerAnchor else { continue }
                        tracker.mouseExited(with: moved(tracker, p))
                        hover.dismiss()
                        target = Target(anchor: anchor, point: p,
                                        enter: { [unowned self] in tracker.mouseMoved(with: moved(tracker, p)) },
                                        exit: { [unowned self] in tracker.mouseExited(with: moved(tracker, p)) })
                        break rows
                    }
                }
            }
        }
        guard let target else { return XCTFail("control: no @mention found in the demo thread") }
        assertCardShowsAndStays(target, in: window, "mention")
    }

    /// Chat list rows (a SwiftUI List in the real shell window): pointing
    /// at a 1:1 chat's avatar shows the card, and it stays.
    func testChatListAvatarHoverShowsCardThatStays() {
        let app = AppState(args: ["--demo"])
        let loaded = expectation(description: "chats")
        Task { await app.chats.load(); loaded.fulfill() }
        wait(for: [loaded], timeout: 10)
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo"]))
        let offDisplay = NSRect(x: -30000, y: -30000, width: 1440, height: 900)
        wc.window!.setFrame(offDisplay, display: false)
        wc.showShell()
        wc.model.navigator?.apply(Route(string: "chat/demo-showcase")!)
        // The shell's content moves into a window that only records
        // order-in (a real one would be pulled onto a display to present
        // the card's popover).
        let content = wc.window!.contentViewController!
        wc.window!.contentViewController = nil
        let window = OffscreenWindow(contentRect: offDisplay, styleMask: [.titled], backing: .buffered, defer: false)
        window.setFrameOrigin(offDisplay.origin)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setFrame(offDisplay, display: false)
        window.orderFront(nil) // recorded only
        addTeardownBlock { window.close(); wc.close() }
        for _ in 0 ..< 20 { window.layoutIfNeeded(); window.displayIfNeeded(); spin(0.05) }
        // List cells host SwiftUI in their own hosting views; 1:1 rows
        // track the pointer (their avatar has a contact card).
        let cells = views(of: NSView.self, in: window.contentView!).filter { cell in
            String(describing: type(of: cell)).hasPrefix("CellHostingView")
                && cell.trackingAreas.contains { $0.owner === cell }
        }
        XCTAssertFalse(cells.isEmpty, "control: chat list rows laid out")
        guard let target = cells.lazy.map(headerTargets).first(where: { !$0.isEmpty })?.first else {
            return XCTFail("no chat list row with a contact anchor")
        }
        assertCardShowsAndStays(target, in: window, "chat list avatar")
    }

    /// Scrolling the timeline under the card still hides it (the card's
    /// own scroll view is exempt, the anchor's is not).
    func testScrollingTimelineHidesCard() {
        let (_, window, table) = timeline()
        let targets = rowHosts(window).lazy.map(headerTargets).first { !$0.isEmpty }
        guard let target = targets?.last else { return XCTFail("no header row with a contact anchor") }
        target.enter()
        let deadline = Date().addingTimeInterval(3)
        while hover.shownAnchor == nil, Date() < deadline { spin(0.01) }
        spin(0.5)
        XCTAssertEqual(hover.shownAnchor, target.anchor, "control: card up before the scroll")
        let clip = table.enclosingScrollView!.contentView
        let before = clip.bounds.origin
        clip.scroll(to: NSPoint(x: 0, y: before.y >= 120 ? before.y - 120 : before.y + 120))
        table.enclosingScrollView!.reflectScrolledClipView(clip)
        XCTAssertNotEqual(clip.bounds.origin, before, "control: the timeline scrolled")
        XCTAssertNil(hover.shownAnchor, "a timeline scroll must hide the card")
        XCTAssertNil(hover.pointerAnchor)
    }
}
