// SavedMessagesTests.swift — e2-saved lane: store save/unsave, flat
// cross-chat persistence + restart, rows model, offline search, jump
// targets, cap + eviction, preview-off redaction.
// PinnedMessagesTests/LocalSearchTests precedent (memory defaults, no
// live pasteboard/network).
import XCTest

@testable import OstMacCore

@MainActor
final class SavedMessagesTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "Ava Lindqvist",
        timestamp: String = "2026-09-22T08:41:02Z",
        content: String = "Morning! Can you review the empty-states mock?"
    ) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: timestamp, content: content)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-saved-\(UUID().uuidString)") ?? .standard
    }

    private func store(_ defaults: UserDefaults? = nil, key: String = SavedMessages.defaultsKey) -> SavedMessageStore {
        SavedMessageStore(defaults: defaults ?? isolatedDefaults(), key: key)
    }

    // MARK: - Save / unsave

    func testSaveAddsAndIsSaved() {
        let s = store()
        XCTAssertFalse(s.isSaved(chatID: "chat-a", messageID: "m1"))
        s.save(chatID: "chat-a", message: msg())
        XCTAssertTrue(s.isSaved(chatID: "chat-a", messageID: "m1"))
        XCTAssertEqual(s.saves.map(\.messageID), ["m1"])
    }

    func testSaveIsIdempotent() {
        let s = store()
        s.save(chatID: "chat-a", message: msg())
        s.save(chatID: "chat-a", message: msg())
        XCTAssertEqual(s.saves.count, 1)
    }

    func testSameMessageIDDifferentChatsBothKept() {
        let s = store()
        s.save(chatID: "chat-a", message: msg(id: "m1"))
        s.save(chatID: "chat-b", message: msg(id: "m1"))
        XCTAssertEqual(s.saves.count, 2)
        XCTAssertTrue(s.isSaved(chatID: "chat-a", messageID: "m1"))
        XCTAssertTrue(s.isSaved(chatID: "chat-b", messageID: "m1"))
    }

    func testUnsaveRemoves() {
        let s = store()
        s.save(chatID: "chat-a", message: msg(id: "m1"))
        s.save(chatID: "chat-b", message: msg(id: "m2"))
        s.unsave(chatID: "chat-a", messageID: "m1")
        XCTAssertFalse(s.isSaved(chatID: "chat-a", messageID: "m1"))
        XCTAssertTrue(s.isSaved(chatID: "chat-b", messageID: "m2"))
    }

    func testUnsaveUnknownNoop() {
        let s = store()
        s.save(chatID: "chat-a", message: msg(id: "m1"))
        s.unsave(chatID: "chat-a", messageID: "nope")
        s.unsave(chatID: "other", messageID: "m1")
        XCTAssertEqual(s.saves.map(\.messageID), ["m1"])
    }

    func testBlankIDsNoop() {
        let s = store()
        s.save(chatID: "   ", message: msg())
        s.save(chatID: "chat-a", message: msg(id: "  "))
        s.save(chatID: nil, message: msg())
        XCTAssertTrue(s.saves.isEmpty)
        XCTAssertFalse(s.isSaved(chatID: "chat-a", messageID: "  "))
        XCTAssertFalse(s.isSaved(chatID: nil, messageID: "m1"))
        s.unsave(chatID: "  ", messageID: "m1")
        s.unsave(chatID: "chat-a", messageID: " ")
    }

    func testToggleSavesAndUnsaves() {
        let s = store()
        let m = msg()
        s.toggle(chatID: "chat-a", message: m)
        XCTAssertTrue(s.isSaved(chatID: "chat-a", messageID: "m1"))
        s.toggle(chatID: "chat-a", message: m)
        XCTAssertFalse(s.isSaved(chatID: "chat-a", messageID: "m1"))
        XCTAssertTrue(s.saves.isEmpty)
    }

    // MARK: - Menu label distinctness (accept 1, R1)

    func testMenuTitleDistinctFromFileExport() {
        // `Save…` is the file-export item (MessageActions.saveBody) in
        // BOTH bubble menus; the toggle must never collide with it.
        XCTAssertNotEqual(SavedMessages.menuTitle(isSaved: false), "Save…")
        XCTAssertNotEqual(SavedMessages.menuTitle(isSaved: true), "Save…")
        XCTAssertEqual(SavedMessages.menuTitle(isSaved: false), "Save this message")
        XCTAssertEqual(SavedMessages.menuTitle(isSaved: true), "Unsave")
    }

    // MARK: - Cross-chat list (accept 2)

    func testSavesListNewestFirstAcrossChatsAndChannels() {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.save(chatID: "chat-a", message: msg(id: "m1"), at: t0)
        s.save(
            chatID: "chan-9", teamID: "team-3", channelID: "chan-9",
            message: msg(id: "m2", sender: "Liam Hartley"), at: t0.addingTimeInterval(60))
        s.save(chatID: "chat-b", message: msg(id: "m3", sender: "Sofia Marchetti"), at: t0.addingTimeInterval(120))
        let rows = SavedMessages.rows(saves: s.saves, live: [])
        XCTAssertEqual(rows.map(\.messageID), ["m3", "m2", "m1"])
        XCTAssertEqual(rows.map(\.chatID), ["chat-b", "chan-9", "chat-a"])
        XCTAssertEqual(rows[1].teamID, "team-3")
        XCTAssertEqual(rows[1].channelID, "chan-9")
        XCTAssertFalse(rows[0].isLive)
    }

    // MARK: - Search (accept 3)

    private func searchStore() -> SavedMessageStore {
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        s.save(
            chatID: "chat-a",
            message: msg(
                id: "m1", sender: "Ava Lindqvist",
                content: "Morning! Can you review the empty-states mock?"),
            at: t0)
        s.save(
            chatID: "chat-b",
            message: msg(
                id: "m2", sender: "Liam Hartley",
                content: "Standup moved to ten, heads-up for the team."),
            at: t0.addingTimeInterval(60))
        s.save(
            chatID: "chan-9", teamID: "team-3", channelID: "chan-9",
            message: msg(
                id: "m3", sender: "Sofia Marchetti",
                content: "Release notes draft is ready for review."),
            at: t0.addingTimeInterval(120))
        return s
    }

    func testSearchSingleTerm() {
        let s = searchStore()
        s.query = "standup"
        XCTAssertEqual(s.filtered().map(\.messageID), ["m2"])
    }

    func testSearchMultiTermAND() {
        let s = searchStore()
        s.query = "review mock"
        XCTAssertEqual(s.filtered().map(\.messageID), ["m1"])
        s.query = "review release"
        XCTAssertEqual(s.filtered().map(\.messageID), ["m3"])
        s.query = "review standup"
        XCTAssertTrue(s.filtered().isEmpty)
    }

    func testSearchPrefixMatch() {
        let s = searchStore()
        s.query = "stan"
        XCTAssertEqual(s.filtered().map(\.messageID), ["m2"])
        s.query = "rev"
        XCTAssertEqual(Set(s.filtered().map(\.messageID)), ["m1", "m3"])
    }

    func testSearchMatchesSender() {
        let s = searchStore()
        s.query = "sofia"
        XCTAssertEqual(s.filtered().map(\.messageID), ["m3"])
    }

    func testSearchNoMatchEmpty() {
        let s = searchStore()
        s.query = "quetzal"
        XCTAssertTrue(s.filtered().isEmpty)
    }

    func testBlankQueryRestoresAll() {
        let s = searchStore()
        s.query = "standup"
        XCTAssertEqual(s.filtered().count, 1)
        s.query = "   "
        XCTAssertEqual(s.filtered().count, 3)
        s.query = ""
        XCTAssertEqual(s.filtered().count, 3)
    }

    func testSearchUsesLocalTokenizer() {
        // No second tokenizer: the store splits exactly like LocalSearchStore.
        XCTAssertEqual(
            LocalSearchStore.tokenize("Standup moved to 10!"),
            ["standup", "moved", "to", "10"])
        let s = searchStore()
        s.query = "STANDUP moved"
        XCTAssertEqual(s.filtered().map(\.messageID), ["m2"])
    }

    // MARK: - Jump targets (accept 4)

    func testHitConversionCarriesCoordinates() {
        let s = searchStore()
        let save = s.saves.first(where: { $0.messageID == "m3" })!
        let hit = SavedMessages.hit(for: save)
        XCTAssertEqual(hit.messageID, "m3")
        XCTAssertEqual(hit.chatID, "chan-9")
        XCTAssertEqual(hit.teamID, "team-3")
        XCTAssertEqual(hit.channelID, "chan-9")
        XCTAssertEqual(hit.sender, "Sofia Marchetti")
    }

    func testJumpTargetLoadedIDTargets() {
        let loaded = [msg(id: "m1"), msg(id: "m2")]
        XCTAssertEqual(SavedMessages.jumpTarget(messageID: "m1", loaded: loaded), "m1")
    }

    func testJumpTargetEvictedIsNil() {
        let loaded = [msg(id: "m1")]
        XCTAssertNil(SavedMessages.jumpTarget(messageID: "m9", loaded: loaded))
        XCTAssertNil(SavedMessages.jumpTarget(messageID: "  ", loaded: loaded))
    }

    // MARK: - Live wins (accept 5)

    func testLiveEditWinsOverSnapshot() {
        let s = store()
        s.save(chatID: "chat-a", message: msg(id: "m1", content: "first draft"))
        var edited = msg(id: "m1", content: "final wording here")
        edited.edited = true
        let rows = SavedMessages.rows(saves: s.saves, live: [edited])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isLive)
        XCTAssertEqual(rows[0].preview, "final wording here")
    }

    func testSnapshotFallsBackOffWindow() {
        let s = store()
        s.save(chatID: "chat-a", message: msg(id: "m1", content: "first draft"))
        let rows = SavedMessages.rows(saves: s.saves, live: [msg(id: "other")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isLive)
        XCTAssertEqual(rows[0].preview, "first draft")
    }

    // MARK: - Per-account + cap (accept 6)

    func testPerAccountKeySeparation() {
        let ka = SavedMessages.key(for: "profile-a")
        let kb = SavedMessages.key(for: "profile-b")
        XCTAssertNotEqual(ka, kb)
        let defaults = isolatedDefaults()
        let a = store(defaults, key: ka)
        let b = store(defaults, key: kb)
        a.save(chatID: "chat-a", message: msg(id: "m1"))
        XCTAssertEqual(a.saves.count, 1)
        XCTAssertTrue(b.saves.isEmpty)
        // Rebind (resetStoresForAccount precedent): the other account's
        // store sees only its own saves.
        let a2 = store(defaults, key: ka)
        XCTAssertEqual(a2.saves.map(\.messageID), ["m1"])
    }

    func testCapBoundOldestFirstEviction() {
        XCTAssertEqual(SavedMessages.cap, 500)
        let s = store()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0 ..< (SavedMessages.cap + 5) {
            s.save(
                chatID: "chat-a",
                message: msg(id: "m\(i)", content: "note number \(i)"),
                at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(s.saves.count, SavedMessages.cap)
        let ids = Set(s.saves.map(\.messageID))
        XCTAssertFalse(ids.contains("m0"))
        XCTAssertFalse(ids.contains("m4"))
        XCTAssertTrue(ids.contains("m5"))
        XCTAssertTrue(ids.contains("m\(SavedMessages.cap + 4)"))
        // Newest-first order holds after eviction.
        XCTAssertEqual(s.saves.first?.messageID, "m\(SavedMessages.cap + 4)")
    }

    // MARK: - Preview-off (accept 7)

    func testPreviewOffRedactsSnippet() {
        XCTAssertEqual(
            SavedMessages.displayPreview(snippet: "secret launch plan", showPreview: true),
            "secret launch plan")
        XCTAssertEqual(
            SavedMessages.displayPreview(snippet: "secret launch plan", showPreview: false),
            MessageNotifications.hiddenPreviewBody)
        XCTAssertNotEqual(
            SavedMessages.displayPreview(snippet: "secret launch plan", showPreview: false),
            "secret launch plan")
    }

    // MARK: - Persistence round-trip (accept 1)

    func testRelaunchRoundTrip() {
        let defaults = isolatedDefaults()
        let s = store(defaults)
        s.save(chatID: "chat-a", message: msg(id: "m1"))
        s.save(
            chatID: "chan-9", teamID: "team-3", channelID: "chan-9",
            message: msg(id: "m2", sender: "Liam Hartley"))
        let reopened = store(defaults)
        XCTAssertEqual(reopened.saves.map(\.id), s.saves.map(\.id))
        XCTAssertTrue(reopened.isSaved(chatID: "chan-9", messageID: "m2"))
    }

    func testCorruptPayloadDecodesEmpty() {
        XCTAssertTrue(SavedMessages.decode(Data("not-json".utf8)).isEmpty)
        XCTAssertTrue(SavedMessages.decode(nil).isEmpty)
    }

    func testSanitizeDedupesEarliestWins() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = SavedMessage(
            chatID: "chat-a", messageID: "m1", sender: "Ava Lindqvist",
            preview: "one", content: "one", timestamp: "t", savedAt: t0.timeIntervalSince1970)
        let dup = SavedMessage(
            chatID: "chat-a", messageID: "m1", sender: "Ava Lindqvist",
            preview: "two", content: "two", timestamp: "t",
            savedAt: t0.timeIntervalSince1970 + 10)
        let blank = SavedMessage(
            chatID: " ", messageID: "m2", sender: "Liam Hartley",
            preview: "x", content: "x", timestamp: "t", savedAt: 1)
        let clean = SavedMessages.sanitize([dup, blank, first])
        XCTAssertEqual(clean.map(\.preview), ["one"])
    }
}
