// ChatPolishTests.swift — hover toolbar rules, message-row timestamps,
// save-original image path, and the older-page race (CHATPOLISH).
import XCTest

import OstMacCore
import UniformTypeIdentifiers
@testable import BetterTeamsUI

@MainActor
final class ChatPolishTests: XCTestCase {
    private func row(_ m: ChatMessage, send: SendState = .none, header: Bool = true,
                     bubble: RowBubble = .other) -> MessageRowData {
        MessageRowData(message: m, showsHeader: header, send: send, quote: nil, receipt: .none, translation: nil,
                       isPinned: false, isSaved: false, ownName: nil, chatID: "c", bubble: bubble)
    }

    private func msg(_ id: String, own: Bool = false) -> ChatMessage {
        ChatMessage(id: id, sender: own ? "Me" : "Megan Harper", timestamp: "2026-09-27T16:02:00Z",
                    content: "hi", isOwn: own)
    }

    // MARK: hover toolbar

    func testToolbarItemsMirrorTeams() {
        XCTAssertEqual(HoverToolbarRules.quickReactions.map(\.emoji), ConversationStore.reactionEmojis)
        XCTAssertEqual(HoverToolbarRules.quickReactions.map(\.name),
                       ["Like", "Heart", "Laugh", "Surprised", "Sad", "Angry"])
        XCTAssertEqual(HoverToolbarRules.trailingItems, ["More reactions", "Reply", "More options"])
    }

    func testToolbarAvailableOnSentOwnAndOthersNotOnFailedSendingOrDeleted() {
        XCTAssertTrue(HoverToolbarRules.isAvailable(row(msg("a"))))
        XCTAssertTrue(HoverToolbarRules.isAvailable(row(msg("b", own: true), bubble: .own)))
        XCTAssertTrue(HoverToolbarRules.isAvailable(row(msg("p"), bubble: .none)))   // channel post
        XCTAssertFalse(HoverToolbarRules.isAvailable(row(msg("c", own: true), send: .failed)))
        XCTAssertFalse(HoverToolbarRules.isAvailable(row(msg("d", own: true), send: .sending)))
        var gone = msg("e")
        gone.deleted = true
        XCTAssertFalse(HoverToolbarRules.isAvailable(row(gone)))
    }

    func testShownOnHoverFocusOrEvidencePin() {
        XCTAssertTrue(HoverToolbarRules.isShown(id: "a", hovered: "a", focused: nil, pinned: nil))
        XCTAssertTrue(HoverToolbarRules.isShown(id: "a", hovered: "b", focused: "a", pinned: nil))
        XCTAssertTrue(HoverToolbarRules.isShown(id: "a", hovered: nil, focused: nil, pinned: "a"))
        XCTAssertFalse(HoverToolbarRules.isShown(id: "a", hovered: "b", focused: "c", pinned: nil))
    }

    func testLeavingOnlyClearsOwnHoverInEitherOrder() {
        let clock = ManualHoverScheduler()
        let h = MessageHover(scheduler: clock)
        h.pointer(true, id: "a")
        h.pointer(true, id: "b")    // enter next before leaving previous
        h.pointer(false, id: "a")
        clock.fire()
        XCTAssertEqual(h.shownID, "b")
        h.pointer(false, id: "b")
        clock.fire()
        XCTAssertNil(h.shownID)
        h.focus(true, id: "x")
        h.focus(false, id: "y")
        XCTAssertEqual(h.focusedID, "x")
    }

    // MARK: timestamps

    private static let utc = TimeZone(identifier: "UTC")!
    private static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testOlderStampsAreDateFirstAndLocaleAware() {
        let now = ISO8601DateFormatter().date(from: "2026-09-28T10:00:00Z")!
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(Self.norm(ChatMessage.shortTime("2026-09-27T16:02:00Z", now: now, timeZone: Self.utc,
                                                       locale: us)), "Sep 27, 4:02 PM")
        XCTAssertEqual(Self.norm(ChatMessage.shortTime("2026-09-28T09:15:00Z", now: now, timeZone: Self.utc,
                                                       locale: us)), "9:15 AM")
        XCTAssertEqual(Self.norm(ChatMessage.shortTime("2025-12-31T16:02:00Z", now: now, timeZone: Self.utc,
                                                       locale: us)), "Dec 31, 2025, 4:02 PM")
        let de = ChatMessage.shortTime("2026-09-27T16:02:00Z", now: now, timeZone: Self.utc,
                                       locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(de.hasPrefix("27."), de)   // day first in German
        XCTAssertTrue(de.hasSuffix("16:02"), de) // 24h clock, date first
    }

    // MARK: save original image

    func testInlineSaveUsesOriginalBytesNotTheBubbleDecode() async throws {
        let full = try DemoMedia.data(for: DemoMedia.photo1Full)
        let bubble = NSImage(size: NSSize(width: 520, height: 347))
        let original = FullResImageModel(thumbURL: "https://h/v1/objects/0/views/imgt1", messageID: "m1",
                                         cache: RichMediaCache(diskDir: nil, memory: .pinned), fetcher: { _ in full })
        let saved = await ImageSave.bytes(original: original, fallback: bubble)
        let (data, type) = try XCTUnwrap(saved)
        XCTAssertEqual(data, full)                          // byte-identical original
        XCTAssertEqual(type, original.originalType)         // its own type/extension
    }

    func testInlineSaveFallsBackToDecodeWhenOriginalFails() async throws {
        struct Down: Error {}
        let decoded = try XCTUnwrap(NSImage(data: DemoMedia.data(for: DemoMedia.photo1)))
        let original = FullResImageModel(thumbURL: "https://h/v1/objects/0/views/imgt2", messageID: "m2",
                                         cache: RichMediaCache(diskDir: nil, memory: .pinned), fetcher: { _ in throw Down() })
        let saved = await ImageSave.bytes(original: original, fallback: decoded)
        XCTAssertEqual(saved?.1, .png)
        XCTAssertNotNil(saved.flatMap { NSImage(data: $0.0) })
    }
}
