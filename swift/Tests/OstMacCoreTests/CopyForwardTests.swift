// CopyForwardTests.swift — om-copyforward lane: copy payload (text +
// rich) via an injected writer, forwarded-attribution post shape, and
// the forward picker model.
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class CopyForwardTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "Tom Becker",
        timestamp: String = "2026-09-22T09:04:47Z",
        content: String = "Pushed new mocks last night."
    ) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: timestamp, content: content)
    }

    // MARK: - Copy payload (text + rich)

    func testCopyPayloadTextIsBubbleDisplay() {
        let p = MessageActions.copyPayload(for: msg(content: "(thumbsup) ok"))
        XCTAssertEqual(p.text, "👍 ok")
        XCTAssertEqual(p.text, MessageActions.copyText(for: msg(content: "(thumbsup) ok")))
    }

    func testCopyPayloadRTFPresentForText() {
        let p = MessageActions.copyPayload(for: msg())
        XCTAssertNotNil(p.rtf)
        let head = String(data: p.rtf!.prefix(5), encoding: .utf8)
        XCTAssertEqual(head, "{\\rtf")
    }

    func testCopyPayloadRTFNilForEmptyText() {
        let p = MessageActions.copyPayload(for: msg(content: ""))
        XCTAssertEqual(p.text, "")
        XCTAssertNil(p.rtf)
    }

    // MARK: - Injected writer (no live pasteboard)

    func testCopyInjectedWriterReceivesPayload() {
        var seen: MessageActions.CopyPayload?
        MessageActions.copy(msg()) { seen = $0 }
        XCTAssertEqual(seen?.text, "Pushed new mocks last night.")
        XCTAssertNotNil(seen?.rtf)
    }

    func testCopyInjectedWriterLeavesLivePasteboardAlone() {
        let before = NSPasteboard.general.changeCount
        MessageActions.copy(msg()) { _ in }
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }

    // MARK: - Forward post shape

    func testForwardPostIsAttributionPlusCopyText() {
        let m = msg(content: "(party) Shipped")
        XCTAssertEqual(
            MessageActions.forwardBody(for: m),
            "Forwarded from Tom Becker:\n🥳 Shipped")
    }

    func testForwardPostBlankSenderFallsBack() {
        XCTAssertEqual(
            MessageActions.forwardBody(for: msg(sender: "  ")),
            "Forwarded from Unknown:\nPushed new mocks last night.")
    }

    func testForwardStorePostsAttributedBody() {
        let store = ConversationStore.demo()
        let m = store.messages[0]
        store.forward(m, toChatID: "demo-2")
        XCTAssertEqual(
            store.lastForward?.body,
            "Forwarded from \(m.sender):\n\(m.content)")
    }

    func testForwardStoreEmptyTextStillNoop() {
        // The header alone must never send: image-only bubbles stay a no-op.
        let store = ConversationStore.demo()
        store.forward(msg(id: "img", content: "   "), toChatID: "demo-2")
        XCTAssertNil(store.lastForward)
    }

    // MARK: - Picker model

    func testPickerKeepsChatsAndChannels() {
        let targets = ForwardPicker.targets(
            chats: DemoData.chats, teams: DemoData.teams)
        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue(targets.allSatisfy { $0.openID != nil })
        XCTAssertTrue(targets.contains { $0.kind == .chat })
        XCTAssertTrue(targets.contains { $0.kind == .channel })
    }

    func testPickerDropsChannelLessTeams() {
        let lonely = TeamItem(teamId: "t0", name: "Lonely", channels: [])
        let targets = ForwardPicker.targets(chats: [], teams: [lonely])
        XCTAssertTrue(targets.isEmpty)
    }

    func testPickerEmptyInputsEmptyOutputs() {
        XCTAssertTrue(ForwardPicker.targets(chats: [], teams: []).isEmpty)
    }
}
