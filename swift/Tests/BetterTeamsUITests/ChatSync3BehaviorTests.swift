// ChatSync3BehaviorTests.swift — CHATSYNC3 R2 + R4, driven through the
// real objects instead of reading source text:
//   R4a a pushed ConversationUpdate (core poll envelope `read_states`)
//       reaches the chat row through the app's feed subscription;
//   R4b a pop-out's timeline reports "viewing the newest message" as
//       active only while its window is key, and only an active report
//       moves the Teams read position;
//   R4c a closed pop-out no longer counts as an open chat;
//   R2  the pop-out's toolbar is native (segmented Chat | Shared, call
//       buttons as toolbar items, identity item centered).
// Demo app state, fake read writer, off-screen windows: zero network,
// nothing ordered in, no user defaults written.
import AppKit
import XCTest
@testable import BetterTeamsUI
@testable import OstMacCore

/// Records read-position writes (`ReadSync.Writer`).
private final class RecordingReadWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    var names: [String] { lock.withLock { _names } }
    var writer: ReadSync.Writer {
        { [self] _, name, _ in lock.withLock { _names.append(name) } }
    }
}

/// Core poll envelopes handed out one per poll (then empty polls).
private final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String]
    init(_ frames: [String]) { self.frames = frames }
    func push(_ f: String) { lock.withLock { frames.append(f) } }
    func next() -> String {
        lock.withLock { frames.isEmpty ? #"{"ok":true,"messages":[],"resync":false,"skipped":0}"# : frames.removeFirst() }
    }
}

/// Order-in marks it visible and key is set by the test; it never
/// reaches the window server.
private final class KeyControlledWindow: NSWindow {
    var key = false
    private var shown = false
    override var isKeyWindow: Bool { key }
    override var isVisible: Bool { shown }
    override func makeKeyAndOrderFront(_ sender: Any?) { shown = true }
    override func orderFront(_ sender: Any?) { shown = true }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
}

@MainActor
final class ChatSync3BehaviorTests: XCTestCase {
    private func demoApp() async -> AppState {
        let app = AppState(args: ["--demo"])
        await app.chats.load()
        return app
    }

    /// Waits up to `ticks` x 10 ms for `done` (a negative check waits the
    /// short default: pushes land within one main-actor hop).
    private func settle(ticks: Int = 300, _ done: () -> Bool) async {
        for _ in 0 ..< ticks where !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01)) // main-queue sinks
            await Task.yield() // main-actor tasks
        }
    }

    private func message(_ id: String) -> ChatMessage {
        ChatMessage(id: id, sender: "Emma Clark", timestamp: "", content: "hi")
    }

    // MARK: R4a ConversationUpdate -> row

    func testConversationUpdatePushUpdatesTheChatRow() async throws {
        defer { RichMediaCache.memoryOnly = false }
        let app = await demoApp()
        let rows = app.chats.chats.map(\.id)
        let chat = try XCTUnwrap(rows.first { !app.unread.isUnread(chatID: $0) }, "control: a read demo row")
        let other = try XCTUnwrap(rows.first { $0 != chat && !app.unread.isUnread(chatID: $0) })

        // What the core emits for a ConversationUpdate frame: the owner
        // marked the chat unread on another client (bookmark behind the
        // newest message).
        func envelope(_ id: String, bookmark: String?, time: String) -> String {
            let mark = bookmark.map { #","bookmark":"\#($0)""# } ?? ""
            return #"{"ok":true,"messages":[],"resync":false,"skipped":0,"read_states":[{"chat_id":"\#(id)","horizon":"1760000000100;1760000000999;0"\#(mark),"last_message_id":"1760000000100","last_message_time":"2025-10-09T08:53:20.100Z","last_message_type":"RichText/Html","time":"\#(time)"}]}"#
        }
        let frames = FrameQueue([
            envelope(chat, bookmark: "1760000000099;1760000000999;0", time: "2025-10-09T08:53:30.000Z"),
            envelope("19:not-listed@thread.v2", bookmark: "1760000000099;1760000000999;0", time: "2025-10-09T08:53:30.000Z"),
        ])
        let idle = RealtimePoll(ok: true, messages: [], resync: false, skipped: 0)
        let feed = RealtimeFeed(poll: { try JSONDecoder().decode(RealtimePoll.self, from: Data(frames.next().utf8)) },
                                pollWait: { _ in idle }, start: { 0 }, stop: { 0 })
        app.subscribeReadState(feed)

        _ = try feed.pollOnce()
        await settle { app.unread.isUnread(chatID: chat) }
        XCTAssertTrue(app.unread.isUnread(chatID: chat), "marked unread elsewhere -> row unread at once")
        XCTAssertFalse(app.unread.isUnread(chatID: other), "only the pushed row changes")

        // A chat the list does not show is ignored.
        _ = try feed.pollOnce()
        await settle(ticks: 30) { false }
        XCTAssertNil(app.chats.chat(id: "19:not-listed@thread.v2"))
        XCTAssertFalse(app.unread.isUnread(chatID: "19:not-listed@thread.v2"))

        // A frame without the bookmark never drops a local Mark as Unread.
        app.unread.markUnread(chatID: other)
        frames.push(envelope(other, bookmark: nil, time: "2030-01-01T00:00:00.000Z"))
        _ = try feed.pollOnce()
        await settle(ticks: 30) { false }
        XCTAssertTrue(app.unread.isUnread(chatID: other), "bookmark-less push keeps the local mark")
    }

    // MARK: R4b key-window reporting

    func testPopOutReportsViewingOnlyFromTheKeyWindow() async throws {
        defer { RichMediaCache.memoryOnly = false }
        let app = await demoApp()
        let chat = try XCTUnwrap(app.chats.chats.first?.id)
        XCTAssertTrue(app.popouts.pop(chatID: chat))

        let conv = ConversationStore()
        conv.showDemo(chatID: chat, chatName: "Emma Clark",
                      messages: [message("1760000000200"), message("1760000000300")])
        let vc = TimelineViewController(conv: conv, model: nil)
        var reports: [(chatID: String?, windowActive: Bool, atLatest: Bool, loaded: Bool, count: Int)] = []
        vc.viewingLatestSink = { reports.append(($0.chatID, $0.windowActive, $0.atLatest, $0.loaded, $0.messages.count)) }
        _ = vc.view
        let window = KeyControlledWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                                         styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 520, height: 400))
        window.orderFront(nil) // recorded only
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        // Background pop-out: reported, but never as active. (The first
        // report waits for the cold first layout, a few seconds.)
        reports.removeAll()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await settle { !reports.isEmpty }
        let background = try XCTUnwrap(reports.last, "control: the timeline reports")
        XCTAssertEqual(background.chatID, chat)
        XCTAssertFalse(background.windowActive, "not the key window")
        XCTAssertTrue(background.atLatest && background.loaded)

        // Key pop-out: active.
        window.key = true
        reports.removeAll()
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await settle { !reports.isEmpty }
        let key = try XCTUnwrap(reports.last)
        XCTAssertTrue(key.windowActive, "key window")

        // Through the app's gate: only the key report writes the read position.
        let msgs = [message("1760000000200"), message("1760000000300")]
        let w = RecordingReadWriter()
        let sync = ReadSync(writer: w.writer, now: { 1_760_000_000_999 })
        let bgGate = app.readViewGate(chatID: chat, windowActive: background.windowActive,
                                      atLatest: background.atLatest, loaded: background.loaded)
        XCTAssertTrue(bgGate.isOpen, "a popped chat counts as open")
        XCTAssertNil(sync.viewed(chatID: chat, messages: msgs, gate: bgGate))
        XCTAssertEqual(w.names, [], "background pop-out never marks read")
        let keyGate = app.readViewGate(chatID: chat, windowActive: key.windowActive,
                                       atLatest: key.atLatest, loaded: key.loaded)
        await sync.viewed(chatID: chat, messages: msgs, gate: keyGate)?.value
        XCTAssertEqual(w.names, ["consumptionhorizon"], "key pop-out marks read")
    }

    // MARK: R4c closed pop-out

    func testClosedPopOutIsNotOpen() async throws {
        defer { RichMediaCache.memoryOnly = false }
        let app = await demoApp()
        let chat = try XCTUnwrap(app.chats.chats.first { $0.id != app.openChatID }?.id)
        let msgs = [message("1760000000300")]
        func gate() -> ReadViewGate {
            app.readViewGate(chatID: chat, windowActive: true, atLatest: true, loaded: true)
        }
        XCTAssertFalse(gate().isOpen, "control: neither open nor popped")

        XCTAssertTrue(app.popouts.pop(chatID: chat))
        XCTAssertTrue(gate().isOpen, "popped = open")
        XCTAssertTrue(app.popouts.visibleChatIDs(open: app.openChatID).contains(chat))

        app.popouts.close(chatID: chat)
        XCTAssertFalse(app.popouts.isPopped(chatID: chat))
        XCTAssertFalse(gate().isOpen, "closed pop-out is not open")
        XCTAssertFalse(app.popouts.visibleChatIDs(open: app.openChatID).contains(chat))
        let w = RecordingReadWriter()
        let sync = ReadSync(writer: w.writer, now: { 1_760_000_000_999 })
        XCTAssertNil(sync.viewed(chatID: chat, messages: msgs, gate: gate()))
        XCTAssertEqual(w.names, [], "a closed pop-out never marks read")
    }

    // MARK: timeline column spans the table (pop-out cold-open glitch)

    /// A timeline laid out narrow, then widened (a window built around its
    /// content, then sized): the column and every materialized cell span
    /// the table, so bubbles are laid out at the width rows were measured at.
    func testTimelineCellsSpanTheTableAfterTheWindowWidens() async throws {
        let conv = ConversationStore()
        conv.showDemo(chatID: "19:run@thread.v2", chatName: "Platform Standup", messages: [
            ChatMessage(id: "1760000000100", sender: "Ava Lindqvist", timestamp: "2026-09-21T16:11:25Z",
                        content: "Can you take the release notes this week?"),
            ChatMessage(id: "1760000000200", sender: "Tom Becker", timestamp: "2026-09-21T16:18:02Z",
                        content: "Update: sidebar done, conversation view in review."),
            ChatMessage(id: "1760000000300", sender: "Tom Becker", timestamp: "2026-09-21T16:20:11Z",
                        content: "Build is green, packaging is next."),
        ])
        let vc = TimelineViewController(conv: conv, model: nil)
        _ = vc.view
        let window = KeyControlledWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 500),
                                         styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 180, height: 500))
        window.orderFront(nil) // recorded only
        window.layoutIfNeeded()
        await settle(ticks: 30) { false }
        let narrow = vc.geometryAudit()
        let narrowW = narrow.range(of: #"(?<= w=)\d+"#, options: .regularExpression).map { Int(narrow[$0]) ?? 0 } ?? 0
        XCTAssertLessThan(narrowW, 200, "control: laid out narrow first: \(narrow)")

        window.setContentSize(NSSize(width: 640, height: 500))
        window.layoutIfNeeded()
        await settle(ticks: 30) { false }
        let audit = vc.geometryAudit()
        let w = try XCTUnwrap(audit.range(of: #"(?<= w=)\d+"#, options: .regularExpression).map { String(audit[$0]) })
        XCTAssertGreaterThan(Int(w) ?? 0, 600, audit)
        XCTAssertTrue(audit.contains("colW=\(w) "), "column spans the table: \(audit)")
        XCTAssertTrue(audit.contains("cellsOff=0"), "every materialized cell spans the table: \(audit)")
        XCTAssertTrue(audit.contains("stale=0"), audit)
    }

    // MARK: menus (were source-text checks)

    func testRowAndMessageMenusOfferPopOutDeleteAndMarkUnread() async throws {
        defer { RichMediaCache.memoryOnly = false }
        let app = await demoApp()
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo", "--evidence"]))
        let id = try XCTUnwrap(app.chats.chats.first { !$0.id.contains("meeting") }?.id)
        func rowMenu() -> [String] {
            ChatSyncEvidence.menuText(ChatRowMenu(id: id, chats: app.chats, unread: app.unread, rules: app.rules,
                                                  snooze: app.snooze, folders: app.chats.folders, model: wc.model))
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        app.chats.deletePolicy = .allowed
        let allowed = rowMenu()
        XCTAssertTrue(allowed.contains("Pop Out Chat"), "\(allowed)")
        XCTAssertFalse(allowed.contains { $0.hasPrefix("Pop Out Chat") && $0 != "Pop Out Chat" }, "enabled, not a placeholder")
        XCTAssertTrue(allowed.contains { $0.hasPrefix("Delete") }, "Teams policy allows Delete")
        app.chats.deletePolicy = .denied
        XCTAssertFalse(rowMenu().contains { $0.hasPrefix("Delete") }, "Teams policy denies Delete")

        let newest = message("1760000000300")
        let row = MessageRowData(message: newest, showsHeader: true, send: .none, quote: nil, receipt: .none,
                                 translation: nil, isPinned: false, isSaved: false, ownName: nil, chatID: id)
        let actions = TimelineActions(conv: wc.model.graph.conv, model: wc.model, services: ConversationServices.of(wc.model))
        let msgMenu = ChatSyncEvidence.menuText(MessageContextMenu(row: row, actions: actions))
        XCTAssertTrue(msgMenu.contains("Mark as Unread"), msgMenu)
    }

    // MARK: R2 native pop-out toolbar

    func testPopOutToolbarIsNative() async throws {
        defer { RichMediaCache.memoryOnly = false }
        let app = await demoApp()
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo", "--evidence"]))
        let one = try XCTUnwrap(app.chats.chats.first { !$0.is_group && !$0.id.contains("meeting") }?.id)
        let chrome = PopoutChrome()
        let bar = PopoutToolbar(model: wc.model, chatID: one, chrome: chrome)
        let toolbar = bar.makeToolbar()
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertFalse(toolbar.allowsUserCustomization)
        XCTAssertEqual(toolbar.centeredItemIdentifiers, [PopoutToolbar.tabsItem])
        XCTAssertEqual(bar.toolbarDefaultItemIdentifiers(toolbar),
                       [.flexibleSpace, PopoutToolbar.tabsItem, .flexibleSpace,
                        PopoutToolbar.videoItem, PopoutToolbar.audioItem])

        // Chat | Shared: one native segmented group, single selection.
        let group = try XCTUnwrap(bar.toolbar(toolbar, itemForItemIdentifier: PopoutToolbar.tabsItem,
                                              willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
        XCTAssertEqual(group.subitems.map(\.label), ["Chat", "Shared", "Notes"], "same tabs as the main window")
        XCTAssertEqual(group.selectionMode, .selectOne)
        XCTAssertEqual(group.controlRepresentation, .automatic, "segmented; AppKit's pop-up only when too narrow")
        XCTAssertEqual(group.selectedIndex, 0)
        group.selectedIndex = 1
        bar.pickTab(group)
        XCTAssertEqual(chrome.tab, .files, "Shared segment shows the Shared tab")
        group.selectedIndex = 0
        bar.pickTab(group)
        XCTAssertEqual(chrome.tab, .chat)

        // Identity: plain title content at the leading edge (titlebar
        // accessory), not a glass toolbar control (it has no action).
        let identity = bar.makeIdentityAccessory()
        XCTAssertEqual(identity.layoutAttribute, .leading)
        XCTAssertEqual(identity.view.frame.height, PopoutContactView.size.height)
        XCTAssertLessThanOrEqual(identity.view.frame.width, PopoutContactView.size.width)
        XCTAssertGreaterThanOrEqual(identity.view.frame.width, 60, "fitted to its content, not collapsed")

        // Calls: standard bordered toolbar buttons with SF Symbols,
        // enabled by the same rule as the main window's header.
        for (ident, symbol) in [(PopoutToolbar.videoItem, "video"), (PopoutToolbar.audioItem, "phone")] {
            let item = try XCTUnwrap(bar.toolbar(toolbar, itemForItemIdentifier: ident, willBeInsertedIntoToolbar: true))
            XCTAssertTrue(item.isBordered)
            XCTAssertEqual(item.visibilityPriority, .high, "calls overflow last")
            XCTAssertNotNil(item.image, symbol)
            XCTAssertNotNil(item.action)
            XCTAssertTrue(item.target === bar)
            XCTAssertFalse(item.label.isEmpty)
            XCTAssertEqual(bar.validateToolbarItem(item), ConversationToolbar.canStartCall(wc.model, for: one))
        }
        XCTAssertTrue(ConversationToolbar.canStartCall(wc.model, for: one), "control: demo can call")
    }
}
