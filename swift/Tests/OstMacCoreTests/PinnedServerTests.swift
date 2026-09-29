// PinnedServerTests.swift — OstMac §84: Teams' own pins join the strip.
// Fakes only: no core, no network.
import Combine
import Foundation
import XCTest

@testable import OstMacCore

/// Fake transport: canned fetch result, records unpin calls.
final class FakePinServer: PinnedServerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _pins: [PinnedMessage]
    private var _fail = false
    private var _unpins: [String] = []
    private var _fetches = 0

    init(_ pins: [PinnedMessage]) { _pins = pins }

    func set(_ pins: [PinnedMessage], fail: Bool = false) {
        lock.lock(); _pins = pins; _fail = fail; lock.unlock()
    }
    var unpins: [String] { lock.lock(); defer { lock.unlock() }; return _unpins }
    var fetches: Int { lock.lock(); defer { lock.unlock() }; return _fetches }

    func fetchPins(chatID: String) throws -> [PinnedMessage] {
        lock.lock(); defer { lock.unlock() }
        _fetches += 1
        if _fail { throw CoreCallError.failed("HTTP 403") }
        return _pins
    }

    func unpin(chatID: String, pinID: String) throws {
        lock.lock(); _unpins.append("\(chatID)|\(pinID)"); lock.unlock()
    }
}

@MainActor
final class PinnedServerTests: XCTestCase {
    private let chat = "19:a@thread.v2"

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test-serverpins-\(UUID().uuidString)") ?? .standard
    }

    private func serverPin(_ id: String, graph: String? = nil, preview: String = "p") -> PinnedMessage {
        PinnedMessages.fromServer([ServerPin(
            messageID: id, sender: "Ava Hart", preview: preview,
            time: "2026-09-28T10:00:00Z", graphPinID: graph)])[0]
    }

    func testCoreEnvelopeDecodesAndMapsDeterministically() throws {
        let json = #"{"ok":true,"chat_id":"c","source":"chatsvc","pins":[{"message_id":"1727000000100","sender":null,"preview":"Ship it","time":null,"pinned_by":"8:orgid:x","pinned_at":null,"graph_pin_id":null},{"message_id":" "}]}"#
        let resp = try decodeOrThrow(ServerPinsResponse.self, from: Data(json.utf8))
        let pins = PinnedMessages.fromServer(resp.pins)
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins[0].messageID, "1727000000100")
        XCTAssertTrue(pins[0].isServer)
        XCTAssertEqual(pins[0].pinnedAt, 1_727_000_000.1, accuracy: 0.001) // ms-epoch id fallback
        XCTAssertEqual(PinnedMessages.serverSeconds("2026-09-28T10:00:00.500Z").map { Int($0) },
                       Int(ISO8601DateFormatter().date(from: "2026-09-28T10:00:00Z")!.timeIntervalSince1970))
        XCTAssertThrowsError(try decodeOrThrow(
            ServerPinsResponse.self,
            from: Data(#"{"ok":false,"error":"pinned_messages","detail":"HTTP 403"}"#.utf8)))
    }

    func testRefreshMergesKeepsLocalAndOnlyPublishesOnChange() async {
        let fake = FakePinServer([serverPin("1727000000100")])
        let store = PinnedMessageStore(defaults: defaults(), key: "k", server: fake)
        store.pin(chatID: chat, messageID: "local-1", sender: "Me", preview: "mine",
                  timestamp: "", at: Date(timeIntervalSince1970: 1_800_000_000))
        var publishes = 0
        let sub = store.$map.dropFirst().sink { _ in publishes += 1 }
        await store.refreshFromServer(chatID: chat)
        XCTAssertEqual(store.pins(for: chat).map(\.messageID), ["1727000000100", "local-1"])
        XCTAssertEqual(publishes, 1)
        // Same server answer again: no republish (no strip flash).
        await store.refreshFromServer(chatID: chat)
        XCTAssertEqual(publishes, 1)
        // Fetch failure keeps what is shown.
        fake.set([], fail: true)
        await store.refreshFromServer(chatID: chat)
        XCTAssertEqual(store.pins(for: chat).count, 2)
        // Unpinned in Teams: the server pin drops, the local pin stays.
        fake.set([])
        await store.refreshFromServer(chatID: chat)
        XCTAssertEqual(store.pins(for: chat).map(\.messageID), ["local-1"])
        XCTAssertEqual(fake.fetches, 4)
        sub.cancel()
    }

    func testBlankPreviewNeverBlanksAHeldRow() {
        let held = serverPin("1727000000100", preview: "Budget due")
        let blank = serverPin("1727000000100", preview: "")
        let merged = PinnedMessages.mergeServer(current: [held], server: [blank], dismissed: [])
        XCTAssertEqual(merged.map(\.preview), ["Budget due"])
        XCTAssertEqual(merged[0].pinnedAt, held.pinnedAt)
    }

    func testUnpinGraphPinDeletesAndDismissedStaysGoneAcrossRestart() async {
        let d = defaults()
        let fake = FakePinServer([serverPin("1727000000100", graph: "pin-1"), serverPin("1727000000200")])
        let store = PinnedMessageStore(defaults: d, key: "k", server: fake)
        await store.refreshFromServer(chatID: chat)
        XCTAssertEqual(store.pins(for: chat).count, 2)
        // Graph-sourced: DELETE through the transport.
        await store.unpin(chatID: chat, messageID: "1727000000100")?.value
        XCTAssertEqual(fake.unpins, ["\(chat)|pin-1"])
        // Chat-service-sourced: local dismiss only, no DELETE.
        XCTAssertNil(store.unpin(chatID: chat, messageID: "1727000000200"))
        XCTAssertEqual(fake.unpins.count, 1)
        // Refetch (server still lists both) never re-adds; survives restart.
        await store.refreshFromServer(chatID: chat)
        XCTAssertTrue(store.pins(for: chat).isEmpty)
        let reborn = PinnedMessageStore(defaults: d, key: "k", server: fake)
        await reborn.refreshFromServer(chatID: chat)
        XCTAssertTrue(reborn.pins(for: chat).isEmpty)
        // Server drops a pin, later re-pins it in Teams: shows again.
        fake.set([serverPin("1727000000200")])
        await reborn.refreshFromServer(chatID: chat)
        XCTAssertTrue(reborn.pins(for: chat).isEmpty) // still pinned server-side → still dismissed
        fake.set([])
        await reborn.refreshFromServer(chatID: chat)
        fake.set([serverPin("1727000000100", graph: "pin-9")])
        await reborn.refreshFromServer(chatID: chat)
        XCTAssertEqual(reborn.pins(for: chat).map(\.graphPinID), ["pin-9"])
    }

    func testLocalOnlyStoreNeverFetchesAndLegacyPinsDecode() async {
        let d = defaults()
        let legacy = #"{"19:a@thread.v2":[{"messageID":"m1","sender":"S","preview":"p","timestamp":"","pinnedAt":1}]}"#
        d.set(Data(legacy.utf8), forKey: "k")
        let store = PinnedMessageStore(defaults: d, key: "k")
        await store.refreshFromServer(chatID: chat)
        XCTAssertEqual(store.pins(for: chat).map(\.messageID), ["m1"])
        XCTAssertFalse(store.pins(for: chat)[0].isServer)
        // Local unpin: no dismissal record, no transport task.
        XCTAssertNil(store.unpin(chatID: chat, messageID: "m1"))
        XCTAssertTrue(store.dismissed.isEmpty)
    }

    /// FIXPACK F2: a failed read is an error state (with the reason class),
    /// keeps shown pins, and the next good read clears it; an empty answer
    /// is not an error.
    func testFailedReadIsAnErrorStateAndEmptyIsNot() async {
        let fake = FakePinServer([])
        let store = PinnedMessageStore(defaults: defaults(), key: "k", server: fake)
        await store.refreshFromServer(chatID: chat)
        XCTAssertNil(store.loadFailure(for: chat), "an empty source is not a failure")
        fake.set([], fail: true)
        await store.refreshFromServer(chatID: chat)
        let why = store.loadFailure(for: chat)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("not permitted") == true, why ?? "")
        var publishes = 0
        let sub = store.$loadFailures.dropFirst().sink { _ in publishes += 1 }
        await store.refreshFromServer(chatID: chat)
        XCTAssertEqual(publishes, 0, "same failure again does not republish")
        sub.cancel()
        fake.set([serverPin("1727000000100")])
        await store.refreshFromServer(chatID: chat)
        XCTAssertNil(store.loadFailure(for: chat))
        XCTAssertEqual(store.pins(for: chat).count, 1)
        XCTAssertEqual(PinnedMessages.failureReason(CoreCallError.failed("HTTP 401 Unauthorized")), "sign-in expired")
        XCTAssertEqual(PinnedMessages.failureReason(CoreCallError.failed("request timed out")), "timed out")
        XCTAssertEqual(PinnedMessages.failureReason(CoreCallError.failed("boom")), "read failed")
    }
}
