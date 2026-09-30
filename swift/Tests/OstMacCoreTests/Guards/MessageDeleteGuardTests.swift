// Guard (MSGDELETE): deleting an own message tombstones it ("This message
// has been deleted."); a delete the server does not confirm keeps the
// message with its text and offers Retry (a failure is never read as
// "gone"); Retry reuses the same bubble. Fake transport only.
import XCTest

@testable import OstMacCore

private final class FakeDeleteWire: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(chat: String, id: String)] = []
    private var failuresLeft: Int
    init(failures: Int) { failuresLeft = failures }
    var recorded: [(chat: String, id: String)] { lock.lock(); defer { lock.unlock() }; return calls }
    func send(_ chat: String, _ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append((chat, id))
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw URLError(.timedOut)
        }
    }
}

@MainActor
final class MessageDeleteGuardTests: XCTestCase {
    private func store(_ wire: FakeDeleteWire) -> ConversationStore {
        let s = ConversationStore()
        let own = ChatMessage(id: "m1", sender: "Owner", timestamp: "2026-09-29T10:00:00Z", content: "keep me")
        s.attachLiveForTesting(chatID: "19:chat@thread.v2", messages: [own], ownName: "Owner")
        s.deleteTransport = { chat, id in try wire.send(chat, id) }
        return s
    }

    private func settle(_ done: @escaping () -> Bool) async {
        for _ in 0 ..< 300 where !done() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testConfirmedDeleteShowsDeletedTombstone() async {
        let wire = FakeDeleteWire(failures: 0)
        let s = store(wire)
        s.deleteMessage(id: "m1")
        XCTAssertTrue(s.messages[0].deleted, "optimistic tombstone")
        await settle { !wire.recorded.isEmpty }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(wire.recorded.map(\.id), ["m1"])
        XCTAssertEqual(wire.recorded.first?.chat, "19:chat@thread.v2")
        XCTAssertTrue(s.messages[0].deleted)
        XCTAssertEqual(s.messages[0].content, "")
        XCTAssertTrue(s.deleteFailedIDs.isEmpty)
    }

    func testFailedDeleteKeepsMessageMarksFailureAndRetrySucceeds() async {
        let wire = FakeDeleteWire(failures: 1)
        let s = store(wire)
        s.deleteMessage(id: "m1")
        await settle { s.deleteFailedIDs.contains("m1") }
        XCTAssertTrue(s.deleteFailedIDs.contains("m1"), "failure is flagged for the Retry row")
        XCTAssertFalse(s.messages[0].deleted, "not confirmed: never shown as deleted")
        XCTAssertEqual(s.messages[0].content, "keep me", "text stays")
        XCTAssertEqual(s.messages.count, 1)
        XCTAssertNotNil(s.error)

        s.retryDelete(id: "m1")
        XCTAssertTrue(s.messages[0].deleted, "retry re-marks the same bubble")
        XCTAssertFalse(s.deleteFailedIDs.contains("m1"), "failure cleared while retrying")
        await settle { wire.recorded.count == 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(wire.recorded.count, 2)
        XCTAssertTrue(s.messages[0].deleted)
        XCTAssertTrue(s.deleteFailedIDs.isEmpty)
        XCTAssertEqual(s.messages.count, 1, "never a duplicate row")
    }

    func testRetryDeleteWithoutFailureIsNoOp() {
        let wire = FakeDeleteWire(failures: 0)
        let s = store(wire)
        s.retryDelete(id: "m1")
        XCTAssertFalse(s.messages[0].deleted)
        XCTAssertTrue(wire.recorded.isEmpty)
    }

    /// The wire request must be the web client's softDelete (Rust unit
    /// tests pin the exact URL; this keeps the source from regressing).
    func testRustDeleteUrlKeepsSoftDeleteBehavior() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { url.deleteLastPathComponent() } // Guards/OstMacCoreTests/Tests/swift/<repo>
        let src = try String(contentsOf: url.appendingPathComponent("rust/ost/src/api/chat.rs"), encoding: .utf8)
        XCTAssertTrue(src.contains("?behavior=softDelete"))
        XCTAssertTrue(src.contains("message_delete_url(&base, chat_id, message_id)"))
    }
}
