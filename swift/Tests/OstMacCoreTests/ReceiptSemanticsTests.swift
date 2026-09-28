// ReceiptSemanticsTests.swift — lanes/receipts: real-Teams receipt matrix.
import XCTest

@testable import OstMacCore

/// Pure-matrix pins: Sent-always, Seen upgrade, receipts-off, group-N,
// channel-none, reader extraction. The inline layout (trailing HStack
// mark, never a VStack row) is pinned by viewed demo shots + the
// ReceiptMark accessibility identifiers, not here — XCTest cannot
// introspect SwiftUI geometry.
@MainActor
final class ReceiptSemanticsTests: XCTestCase {
    private func pos(_ ids: String...) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }

    // MARK: - Resolve matrix

    func testSentAlwaysOnOwnUnread() {
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: true, isGroup: true, readers: []),
            .sent)
        // 1:1 too (no readers yet).
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: true, isGroup: false, readers: []),
            .sent)
    }

    func testSeenUpgradeOneToOne() {
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: true, isGroup: false, readers: ["Ava"]),
            .seen)
    }

    func testReceiptsOffSentForever() {
        // Readers exist, but the opt-out holds Sent (mutual).
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: false, isGroup: false, readers: ["Ava"]),
            .sent)
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: false, isGroup: true,
                readers: ["Ava", "Liam", "Maya"]),
            .sent)
    }

    func testGroupSeenByN() {
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: true, isGroup: true,
                readers: ["Maya", "Ava"]),
            .seenBy(readers: ["Ava", "Maya"]))
        // Boundary: exactly 20 still lists.
        let twenty = (1...20).map { "u\($0)" }
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: true, isGroup: true, readers: twenty),
            .seenBy(readers: twenty.sorted()))
    }

    func testGroupOverCapFallsBackToSeen() {
        let many = (1...21).map { "u\($0)" }
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: false,
                receiptsEnabled: true, isGroup: true, readers: many),
            .seen)
    }

    func testChannelNone() {
        // Readers or not, channels never mark.
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: true,
                receiptsEnabled: true, isGroup: true,
                readers: ["Ava", "Liam"]),
            .none)
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: false, isChannel: true,
                receiptsEnabled: true, isGroup: true, readers: []),
            .none)
    }

    func testPeerAndFailedNone() {
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: false, failed: false, isChannel: false,
                receiptsEnabled: true, isGroup: true, readers: ["Ava"]),
            .none)
        XCTAssertEqual(
            ReceiptDisplay.resolve(
                isOwn: true, failed: true, isChannel: false,
                receiptsEnabled: true, isGroup: true, readers: ["Ava"]),
            .none)
    }

    // MARK: - Labels + who-list surface

    func testLabels() {
        XCTAssertEqual(ReceiptDisplay.none.accessibilityLabel, "")
        XCTAssertEqual(ReceiptDisplay.sent.accessibilityLabel, "Sent")
        XCTAssertEqual(ReceiptDisplay.seen.accessibilityLabel, "Seen")
        XCTAssertEqual(
            ReceiptDisplay.seenBy(readers: ["A", "B", "C"]).accessibilityLabel,
            "Seen by 3")
    }

    func testVisibilityAndWhoList() {
        XCTAssertFalse(ReceiptDisplay.none.isVisible)
        XCTAssertTrue(ReceiptDisplay.sent.isVisible)
        XCTAssertTrue(ReceiptDisplay.seen.isVisible)
        XCTAssertTrue(ReceiptDisplay.seenBy(readers: ["A"]).isVisible)
        XCTAssertFalse(ReceiptDisplay.none.showsWhoList)
        XCTAssertFalse(ReceiptDisplay.sent.showsWhoList)
        XCTAssertFalse(ReceiptDisplay.seen.showsWhoList)
        XCTAssertTrue(ReceiptDisplay.seenBy(readers: ["A"]).showsWhoList)
    }

    // MARK: - Reader extraction

    func testReadersFrontierAtOrPast() {
        let p = pos("m1", "m2", "m3")
        XCTAssertEqual(
            ReceiptStore.readers(
                messageID: "m1", position: p,
                peers: ["ava": "m1", "liam": "m3", "zed": "m0"]),
            ["ava", "liam"])
        XCTAssertEqual(
            ReceiptStore.readers(
                messageID: "m3", position: p,
                peers: ["ava": "m1", "liam": "m3"]),
            ["liam"])
    }

    func testReadersUnknownReadsEmpty() {
        let p = pos("m1", "m2")
        XCTAssertEqual(
            ReceiptStore.readers(
                messageID: "nope", position: p, peers: ["ava": "m2"]),
            [])
        XCTAssertEqual(
            ReceiptStore.readers(messageID: "", position: p, peers: ["ava": "m2"]),
            [])
        XCTAssertEqual(
            ReceiptStore.readers(messageID: "m1", position: p, peers: [:]),
            [])
    }

    func testReadersKeepsBlankUser() {
        // "" = unknown peer shape: evidence, like isRead (fail-open).
        let p = pos("m1", "m2")
        XCTAssertEqual(
            ReceiptStore.readers(messageID: "m1", position: p, peers: ["": "m2"]),
            [""])
    }

    func testReadersStoreOverload() {
        let store = ReceiptStore(sender: { _, _ in }, fetcher: { _ in [] })
        store.adopt(threadID: "c1", peers: ["ava": "m2", "liam": "m1"])
        XCTAssertEqual(
            store.readers(chatID: "c1", messageID: "m1", position: pos("m1", "m2")),
            ["ava", "liam"])
        XCTAssertEqual(
            store.readers(chatID: "c1", messageID: "m2", position: pos("m1", "m2")),
            ["ava"])
        XCTAssertEqual(
            store.readers(chatID: "nope", messageID: "m1", position: pos("m1")),
            [])
    }
}
