// ReceiptsTests.swift — om-receipts: send path, render state, store.
import XCTest

@testable import OstMacCore

/// Sendable boxes for mock transports (detached-task boundary).
private final class SendBox: @unchecked Sendable {
    var calls: [(String, String)] = []
    var fail = false
}

private final class FetchBox: @unchecked Sendable {
    var calls: [String] = []
    var list: [ReadReceipt] = []
    var fail = false
}

@MainActor
final class ReceiptsTests: XCTestCase {
    // MARK: - Send path

    func testShouldSendGate() {
        XCTAssertFalse(ReceiptStore.shouldSend(chatID: nil, latestID: "m1", sent: [:]))
        XCTAssertFalse(ReceiptStore.shouldSend(chatID: "  ", latestID: "m1", sent: [:]))
        XCTAssertFalse(ReceiptStore.shouldSend(chatID: "c1", latestID: nil, sent: [:]))
        XCTAssertFalse(ReceiptStore.shouldSend(chatID: "c1", latestID: "  ", sent: [:]))
        XCTAssertTrue(ReceiptStore.shouldSend(chatID: "c1", latestID: "m1", sent: [:]))
        XCTAssertFalse(ReceiptStore.shouldSend(chatID: "c1", latestID: "m1", sent: ["c1": "m1"]))
        XCTAssertTrue(ReceiptStore.shouldSend(chatID: "c1", latestID: "m2", sent: ["c1": "m1"]))
    }

    func testSendRecordsOnSuccess() async {
        let box = SendBox()
        let store = ReceiptStore(sender: { chat, mid in
            box.calls.append((chat, mid))
        }, fetcher: { _ in [] })
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        await waitFor { store.sent["c1"] == "m1" }
        XCTAssertEqual(box.calls.count, 1)
        // Repeat tail is a no-op (no second call).
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.calls.count, 1)
    }

    func testSendBlankIsNoop() async {
        let box = SendBox()
        let store = ReceiptStore(sender: { chat, mid in
            box.calls.append((chat, mid))
        }, fetcher: { _ in [] })
        store.sendReadPosition(chatID: "  ", latestID: "m1")
        store.sendReadPosition(chatID: "c1", latestID: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(box.calls.isEmpty)
        XCTAssertTrue(store.sent.isEmpty)
    }

    func testSendFailureSurfacesInDiagnostics() async {
        let box = SendBox()
        box.fail = true
        struct Boom: Error {}
        let store = ReceiptStore(sender: { _, _ in
            box.calls.append(("c", "m"))
            if box.fail { throw Boom() }
        }, fetcher: { _ in [] })
        store.sendReadPosition(chatID: "c1", latestID: "m9")
        await waitFor { store.lastError != nil }
        XCTAssertNil(store.sent["c1"])
        XCTAssertTrue(store.lastError?.contains("read position failed") ?? false)
    }

    func testLocalOnlyRecordsWithoutCore() {
        let box = SendBox()
        let store = ReceiptStore(sender: { chat, mid in
            box.calls.append((chat, mid))
        }, fetcher: { _ in [] })
        store.sendReadPosition(chatID: "demo", latestID: "m3", localOnly: true)
        XCTAssertEqual(store.sent["demo"], "m3")
        XCTAssertTrue(box.calls.isEmpty)
    }

    /// Live FFI round-trip: empty ids rejected by core before any network.
    func testLiveFFIEmptyIDsThrow() {
        XCTAssertThrowsError(try RustCore.markRead(chatID: "", messageID: "m1"))
        XCTAssertThrowsError(try RustCore.markRead(chatID: "19:x", messageID: "  "))
        XCTAssertThrowsError(try RustCore.receipts(threadID: ""))
    }

    // MARK: - Render state

    private static let thread: [ChatMessage] = [
        ChatMessage(id: "m1", sender: "Me", timestamp: "t", content: "a", isOwn: true),
        ChatMessage(id: "m2", sender: "Bo", timestamp: "t", content: "b"),
        ChatMessage(id: "m3", sender: "Me", timestamp: "t", content: "c", isOwn: true),
    ]

    func testIsReadPure() {
        let msgs = Self.thread
        XCTAssertTrue(ReceiptStore.isRead(messageID: "m1", messages: msgs, peerIDs: ["m1"]))
        XCTAssertTrue(ReceiptStore.isRead(messageID: "m1", messages: msgs, peerIDs: ["m3"]))
        XCTAssertFalse(ReceiptStore.isRead(messageID: "m3", messages: msgs, peerIDs: ["m1"]))
        XCTAssertFalse(ReceiptStore.isRead(messageID: "m3", messages: msgs, peerIDs: []))
        XCTAssertFalse(ReceiptStore.isRead(messageID: "nope", messages: msgs, peerIDs: ["m3"]))
        XCTAssertFalse(ReceiptStore.isRead(messageID: "m1", messages: msgs, peerIDs: ["nope"]))
        XCTAssertFalse(ReceiptStore.isRead(messageID: "", messages: msgs, peerIDs: ["m3"]))
    }

    func testIsOwnReadViaStore() {
        let store = ReceiptStore(sender: { _, _ in }, fetcher: { _ in [] })
        store.adopt(threadID: "c1", peers: ["peer": "m2"])
        XCTAssertTrue(store.isOwnRead(chatID: "c1", messageID: "m1", messages: Self.thread))
        XCTAssertFalse(store.isOwnRead(chatID: "c1", messageID: "m3", messages: Self.thread))
        XCTAssertFalse(store.isOwnRead(chatID: "c2", messageID: "m1", messages: Self.thread))
    }

    // MARK: - Store

    func testApplyMergesPerThread() {
        let store = ReceiptStore(sender: { _, _ in }, fetcher: { _ in [] })
        store.apply(threadID: "c1", receipts: [
            ReadReceipt(user: "a", message_id: "m1"),
            ReadReceipt(user: "b", message_id: "m2"),
        ])
        XCTAssertEqual(store.peerReadIDs(for: "c1"), ["m1", "m2"])
        XCTAssertEqual(store.threadCount, 1)
        XCTAssertEqual(store.receiptCount, 2)
        // Merge: same user moves, blank ids drop, other threads untouched.
        store.apply(threadID: "c1", receipts: [
            ReadReceipt(user: "a", message_id: "m3"),
            ReadReceipt(user: "c", message_id: "  "),
        ])
        XCTAssertEqual(store.peerReadIDs(for: "c1"), ["m3", "m2"])
        store.apply(threadID: "  ", receipts: [ReadReceipt(user: "x", message_id: "m1")])
        XCTAssertEqual(store.threadCount, 1)
    }

    func testRefreshMergesAndCounts() async {
        struct Boom: Error {}
        let box = FetchBox()
        box.list = [ReadReceipt(user: "peer", message_id: "m2")]
        let store = ReceiptStore(sender: { _, _ in }, fetcher: { thread in
            box.calls.append(thread)
            if box.fail { throw Boom() }
            return box.list
        })
        store.refresh(threadID: "c1")
        await waitFor { store.peerReadIDs(for: "c1") == ["m2"] }
        XCTAssertEqual(box.calls, ["c1"])
        XCTAssertEqual(
            DiagnosticsFormat.receiptsLine(
                sent: store.sentCount, threads: store.threadCount,
                peers: store.receiptCount),
            "0 sent · 1 threads · 1 peers")
        // Blank thread is a no-op (no fetch).
        store.refresh(threadID: "  ")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.calls.count, 1)
    }

    func testNoteSentAndClear() {
        let store = ReceiptStore(sender: { _, _ in }, fetcher: { _ in [] })
        store.noteSent(chatID: "c1", messageID: "m1")
        store.adopt(threadID: "c1", peers: ["p": "m1"])
        XCTAssertEqual(store.sentCount, 1)
        XCTAssertEqual(store.threadCount, 1)
        store.noteSent(chatID: "  ", messageID: "m2")
        XCTAssertEqual(store.sentCount, 1)
        store.clear()
        XCTAssertTrue(store.sent.isEmpty)
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertNil(store.lastError)
    }

    func testReceiptsLine() {
        XCTAssertEqual(
            DiagnosticsFormat.receiptsLine(sent: 2, threads: 1, peers: 3),
            "2 sent · 1 threads · 3 peers")
    }

    // MARK: - Helpers

    /// Spin until `cond` holds (mock transports resolve in ms; 2s cap).
    private func waitFor(
        _ cond: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met in 2s", file: file, line: line)
    }
}
