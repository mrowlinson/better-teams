// RegfixCGuardTests — R1-R3, R6 (REGFIX-C): behavior rebuilt after the 09-27
// rebuild lost it, pinned so it cannot go silently again. One window per
// account; Manage Folders Folders|Rules; Clear Call History; the speaker
// and microphone test; the meeting-call chat opening at the newest message;
// the image viewer hiding its arrows for a single image. Nothing is shown
// on screen (presenter replaced, windows built off-display).
import AppKit
import SwiftUI
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class RegfixCGuardTests: XCTestCase {
    private var savedPresenter: ((NSWindowController) -> Void)!
    private var presented: [NSWindowController] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        savedPresenter = PopOutPresenter.present
        PopOutPresenter.present = { [unowned self] c in presented.append(c) }
    }

    override func tearDown() {
        PopOutPresenter.present = savedPresenter
        super.tearDown()
    }

    // MARK: R1 one native window per account

    func testAccountWindowOpensOncePerAccountAndCarriesTheAccountName() throws {
        let (app, _, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        // A live-mode model over the same graph (account windows never open
        // in demo). One signed-in account is enough to pin "one window per
        // account": the store cannot be given a second without touching the
        // core's real profile.
        let model = WindowModel(graph: app, accountKey: "regfixc-guard", options: LaunchOptions(args: []))
        let navigator = Navigator(model: model)
        model.navigator = navigator
        defer { withExtendedLifetime(navigator) {} }
        app.accounts.adoptLegacy(displayName: "Claire Dawson", upn: "claire@example.test")
        let id = try XCTUnwrap(app.accounts.accounts.first?.id, "control: the account exists")
        XCTAssertNil(AccountWindowController.window(for: id))

        AccountWindowController.show(model, accountID: id)
        let w1 = try XCTUnwrap(AccountWindowController.window(for: id), "no window for the account")
        addTeardownBlock { w1.close() }
        XCTAssertEqual(w1.title, "Claire Dawson")
        XCTAssertEqual(w1.subtitle, "claire@example.test")
        XCTAssertFalse(w1.isVisible, "the test never orders a window in")
        XCTAssertEqual(presented.count, 1)

        // Opening the account again brings its window forward, never a second one.
        AccountWindowController.show(model, accountID: id)
        XCTAssertTrue(AccountWindowController.window(for: id) === w1)
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0] === presented[1], "the same controller both times")
        // Unknown accounts open nothing.
        AccountWindowController.show(model, accountID: "nobody")
        XCTAssertNil(AccountWindowController.window(for: "nobody"))
        XCTAssertEqual(presented.count, 2)
        // Closed: the next open builds a fresh window.
        w1.close()
        XCTAssertNil(AccountWindowController.window(for: id))
    }

    // MARK: R2 Manage Folders: Folders | Rules

    func testManageFoldersHasFoldersAndRulesTabs() {
        XCTAssertEqual(ManageFoldersSheet.Tab.allCases.map(\.rawValue), ["Folders", "Rules"])
    }

    func testFolderRulesRoundTripAndFileChatsFirstMatchWins() throws {
        let suite = "regfixc.folders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = FolderStore(defaults: defaults)
        let work = try XCTUnwrap(store.createFolder(name: "Work"))
        let people = try XCTUnwrap(store.createFolder(name: "People"))
        let byName = try XCTUnwrap(store.addRule(FolderRule(folderID: work.id, namePattern: "  budget ")))
        _ = store.addRule(FolderRule(folderID: people.id, kind: .direct))
        let chat = ChatItem(chatId: "c1", name: "Budget review", is_group: false, last_message_sender: nil)
        XCTAssertEqual(store.folderID(for: chat), work.id, "the first matching rule files the chat")
        let other = ChatItem(chatId: "c2", name: "Lunch", is_group: false, last_message_sender: nil)
        XCTAssertEqual(store.folderID(for: other), people.id, "a 1:1 rule files a 1:1 chat")
        // Persisted, whitespace trimmed, and reloaded in order.
        let again = FolderStore(defaults: defaults)
        XCTAssertEqual(again.rules.count, 2)
        XCTAssertEqual(again.rules.first?.namePattern, "budget")
        // Removing a rule un-files its chats.
        store.removeRule(id: byName.id)
        XCTAssertEqual(store.folderID(for: chat), people.id)
        // The sheet's one-line summaries.
        XCTAssertEqual(ManageFoldersSheet.summary(FolderRule(folderID: work.id)), "New Rule")
        XCTAssertEqual(ManageFoldersSheet.summary(FolderRule(folderID: work.id, namePattern: "x", kind: .group)),
                       "name contains \u{201C}x\u{201D} or group chats")
        // A rule for an unknown folder is refused.
        XCTAssertNil(store.addRule(FolderRule(folderID: "ghost", namePattern: "x")))
    }

    // MARK: R3 Clear Call History

    func testClearCallHistoryEmptiesRecentsAndIsInTheCallMenu() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        if app.history.records.isEmpty { app.history.seedDemo() }
        XCTAssertFalse(app.history.records.isEmpty, "control: there is history to clear")
        CallsSection.performClearHistory(model)
        XCTAssertTrue(app.history.records.isEmpty, "Clear Call History must drop every recent call")
        let cmd = try XCTUnwrap(CommandCatalog.command(CallsCommands.clearHistory), "command missing from the catalog")
        XCTAssertEqual(cmd.title, "Clear Call History\u{2026}")
        XCTAssertEqual(cmd.menu?.menu, .call)
        XCTAssertTrue(MenuShortcutCatalogGuardTests.lines().contains("Call > Clear Call History\u{2026}"))
    }

    // MARK: R3 speaker and microphone test

    func testSpeakerAndMicrophoneTestsCompleteWithAResult() {
        let d = CallDevices(live: false, store: nil, camera: nil)
        XCTAssertEqual(d.speakerPhase, .idle)
        XCTAssertEqual(d.micPhase, .idle)
        d.testSpeaker()
        d.testMicrophone()
        XCTAssertEqual(d.speakerPhase, .done)
        XCTAssertEqual(d.micPhase, .done)
        XCTAssertNotEqual(d.speakerResult, "Not tested")
        XCTAssertNotEqual(d.micResult, "Not tested")
        // The sheet builds (Settings > Calls presents it).
        let host = NSHostingController(rootView: CallDeviceTestSheet(devices: d, callActive: false) {})
        XCTAssertGreaterThan(host.view.fittingSize.height, 0)
    }

    // MARK: R3 meeting-call chat opens at the newest message

    func testCallChatNewestMessageRules() {
        // At the end (within the slack) counts as newest; scrolled up does not.
        XCTAssertTrue(CallChatList.isAtNewest(offsetY: 600, containerHeight: 400, contentHeight: 1000))
        XCTAssertTrue(CallChatList.isAtNewest(offsetY: 590, containerHeight: 400, contentHeight: 1000), "inside the slack")
        XCTAssertFalse(CallChatList.isAtNewest(offsetY: 0, containerHeight: 400, contentHeight: 1000))
        // A new message follows only at the end, or when it is yours.
        XCTAssertTrue(CallChatList.followsNewMessage(atNewest: true, lastIsOwn: false))
        XCTAssertTrue(CallChatList.followsNewMessage(atNewest: false, lastIsOwn: true))
        XCTAssertFalse(CallChatList.followsNewMessage(atNewest: false, lastIsOwn: false))
    }

    func testCallChatOpensScrolledToTheNewestMessage() throws {
        let chat = MeetingChatStore.memoryOnly()
        let msgs = (0 ..< 80).map {
            ChatMessage(id: "m\($0)", sender: "Erin Walsh", timestamp: "2026-09-29T10:\(String(format: "%02d", $0 % 60)):00Z",
                        content: "message number \($0)", isOwn: false)
        }
        chat.showDemo(threadID: "19:meeting_regfixc@thread.v2", chatName: "Standup", messages: msgs)
        let size = NSRect(x: -30000, y: -30000, width: 360, height: 420)
        let window = OffscreenWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: CallChatList(chat: chat, isMeeting: true))
        host.frame = NSRect(origin: .zero, size: size.size)
        window.contentView = host
        window.orderFront(nil) // recorded only
        addTeardownBlock { window.close() }
        var scroll: NSScrollView?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            window.layoutIfNeeded(); window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            scroll = GuardSupport.subviews(of: host).compactMap { $0 as? NSScrollView }.first
            if let s = scroll, let doc = s.documentView, doc.frame.height > s.contentView.bounds.height,
               s.contentView.bounds.origin.y > 0 { break }
        }
        let s = try XCTUnwrap(scroll, "no scroll view under the call chat")
        let doc = try XCTUnwrap(s.documentView)
        XCTAssertGreaterThan(doc.frame.height, s.contentView.bounds.height, "control: 80 messages overflow the pane")
        let bottom = doc.frame.height - s.contentView.bounds.height
        XCTAssertEqual(s.contentView.bounds.origin.y, bottom, accuracy: CallChatList.bottomSlack + 2,
                       "the chat must open at the newest message, not the oldest")
    }

    // MARK: R6 image viewer: no arrows for one image

    func testViewerHidesStepArrowsForASingleImage() throws {
        let one = ImageViewerItem(url: "https://example.test/a.png", messageID: "m1")
        let two = ImageViewerItem(url: "https://example.test/b.png", messageID: "m2")
        func viewerButtons(_ nav: ImageViewerNav) throws -> (prev: NSButton, next: NSButton) {
            let viewer = ImageViewerController(viewerWindow: ImageViewerChrome.makeWindow {
                OffscreenWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: true)
            })
            viewer.show(nav: nav, thumbs: { _ in nil }, demo: true, saver: { _, _, _, _, _ in })
            addTeardownBlock { @MainActor in viewer.window?.close() }
            // The viewer orders in once the size is known (a task): wait for it.
            let deadline = Date().addingTimeInterval(5)
            while viewer.window?.isVisible != true, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(viewer.window?.isVisible, true, "control: the viewer opened")
            let root = try XCTUnwrap(viewer.window?.contentView)
            let all = GuardSupport.subviews(of: root).compactMap { $0 as? NSButton }
            let prev = try XCTUnwrap(all.first { $0.accessibilityLabel() == "Previous Image" })
            let next = try XCTUnwrap(all.first { $0.accessibilityLabel() == "Next Image" })
            return (prev, next)
        }
        let single = try viewerButtons(ImageViewerNav(items: [one], current: one))
        XCTAssertTrue(single.prev.isHidden && single.next.isHidden, "a single image has no previous/next arrows")
        let several = try viewerButtons(ImageViewerNav(items: [one, two], current: one))
        XCTAssertFalse(several.prev.isHidden || several.next.isHidden, "control: arrows show with 2+ images")
    }
}
