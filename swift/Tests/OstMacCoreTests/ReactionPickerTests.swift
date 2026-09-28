// ReactionPickerTests.swift — om-react-polish lane: more-picker
// catalog/search/recents plus the widened Swift-side acceptance
// (any single emoji reacts; live sends attempt any emoji, fid-lists
// D20 — server verdict surfaces verbatim on failure).
import XCTest

@testable import OstMacCore

@MainActor
final class ReactionPickerTests: XCTestCase {
    // MARK: - Acceptance

    func testIsReactableSingleGraphemeOnly() {
        XCTAssertTrue(ConversationStore.isReactable("👍"))
        XCTAssertTrue(ConversationStore.isReactable("🎉"))
        // Flag, ZWJ sequence, and modifier sequence are one Character.
        XCTAssertTrue(ConversationStore.isReactable("🇫🇷"))
        XCTAssertTrue(ConversationStore.isReactable("👨‍👩‍👧"))
        XCTAssertTrue(ConversationStore.isReactable("👍🏽"))
        XCTAssertFalse(ConversationStore.isReactable(""))
        XCTAssertFalse(ConversationStore.isReactable("ab"))
        XCTAssertFalse(ConversationStore.isReactable("👍👍"))
    }

    func testExtendedEmojiTogglesInDemo() {
        let store = ConversationStore.demo()
        let id = store.messages[0].id
        store.toggleReaction(messageID: id, emoji: "🎉")
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "🎉", count: 1)])
        store.toggleReaction(messageID: id, emoji: "🎉")
        XCTAssertTrue(store.messages[0].reactions.isEmpty)
    }

    func testExtendedEmojiAttemptedLiveNoClientRefusal() {
        // CONTRACT CHANGE (fid-lists D20): no client pre-refusal —
        // extended emoji apply optimistically like canonical (see
        // testCanonicalLiveWithoutChatStaysApplied); a core/server
        // rejection reverts with verbatim detail (FidListsTests).
        let store = ConversationStore()
        store.ingest(realtime: RealtimeMessage(
            chatID: "c", msgId: "live-1", sender: "A",
            text: "hi", time: "t", isEdit: false))
        store.toggleReaction(messageID: "live-1", emoji: "🎉")
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "🎉", count: 1)])
        XCTAssertNil(store.error)
    }

    func testCanonicalLiveWithoutChatStaysApplied() {
        // No chatID yet: canonical applies and waits (pre-existing path).
        let store = ConversationStore()
        store.ingest(realtime: RealtimeMessage(
            chatID: "c", msgId: "live-1", sender: "A",
            text: "hi", time: "t", isEdit: false))
        store.toggleReaction(messageID: "live-1", emoji: "👍")
        XCTAssertEqual(
            store.messages[0].reactions, [ReactionCount(emoji: "👍", count: 1)])
        XCTAssertNil(store.error)
    }

    // MARK: - Catalog

    func testCatalogEntriesAreSingleCharacters() {
        XCTAssertFalse(ReactionCatalog.categories.isEmpty)
        for e in ReactionCatalog.all {
            XCTAssertEqual(e.emoji.count, 1, "not single: \(e.emoji)")
            XCTAssertFalse(e.keywords.isEmpty)
        }
    }

    func testCatalogCoversCanonicalSix() {
        for e in ConversationStore.reactionEmojis {
            XCTAssertTrue(ReactionCatalog.contains(e), "missing: \(e)")
        }
        // Category lookup resolves, unknown ids do not.
        XCTAssertNotNil(ReactionCatalog.entries(forCategory: "faces"))
        XCTAssertNil(ReactionCatalog.entries(forCategory: "nope"))
    }

    func testSearchMatchesKeywordsCaseInsensitively() {
        let party = ReactionCatalog.search("party").map(\.emoji)
        XCTAssertTrue(party.contains("🎉"))
        XCTAssertTrue(party.contains("🥳"))
        XCTAssertEqual(
            ReactionCatalog.search("PARTY").map(\.emoji), party)
        // Multi-term AND: hearts + eyes narrows to 😍.
        XCTAssertEqual(
            ReactionCatalog.search("hearts eyes").map(\.emoji), ["😍"])
        XCTAssertTrue(ReactionCatalog.search("zzz-no-match").isEmpty)
        XCTAssertTrue(ReactionCatalog.search("   ").isEmpty)
    }

    // MARK: - Recents

    func testRecentsMoveToFrontDedupAndCap() {
        XCTAssertEqual(
            ReactionRecents.withRecorded([], emoji: "👍"), ["👍"])
        XCTAssertEqual(
            ReactionRecents.withRecorded(["👍", "❤️"], emoji: "❤️"),
            ["❤️", "👍"])
        let full = (0 ..< ReactionRecents.maxCount).map { "\($0)" }
        let capped = ReactionRecents.withRecorded(full, emoji: "new")
        XCTAssertEqual(capped.count, ReactionRecents.maxCount)
        XCTAssertEqual(capped.first, "new")
        XCTAssertFalse(capped.contains("11"))
    }

    func testRecentsDefaultsRoundTripFiltersJunk() {
        let suite = "om.reactpolish.test"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("no suite defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["👍", "", "ab"], forKey: ReactionRecents.defaultsKey)
        XCTAssertEqual(ReactionRecents.load(defaults: defaults), ["👍"])
        ReactionRecents.record("🎉", defaults: defaults)
        XCTAssertEqual(
            ReactionRecents.load(defaults: defaults), ["🎉", "👍"])
        // Non-emoji never records.
        ReactionRecents.record("", defaults: defaults)
        XCTAssertEqual(
            ReactionRecents.load(defaults: defaults), ["🎉", "👍"])
    }

    // MARK: - w4-emoji-recent seeded recents

    func testSeedIsFullTopFrequentGrid() {
        XCTAssertEqual(ReactionRecents.seed.count, ReactionRecents.maxCount)
        XCTAssertEqual(Set(ReactionRecents.seed).count, ReactionRecents.seed.count)
        for e in ReactionRecents.seed {
            XCTAssertEqual(e.count, 1, "not single: \(e)")
            XCTAssertTrue(ReactionCatalog.contains(e), "not in catalog: \(e)")
        }
    }

    func testFreshUserSeesFullSeedGrid() {
        let suite = "om.w4recent.fresh.test"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("no suite defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        // No key at all: full grid of top-N frequent, zero empty slots.
        XCTAssertEqual(ReactionRecents.load(defaults: defaults), ReactionRecents.seed)
        XCTAssertEqual(
            ReactionRecents.load(defaults: defaults).count, ReactionRecents.maxCount)
        // Junk-only also counts as fresh.
        defaults.set(["", "ab"], forKey: ReactionRecents.defaultsKey)
        XCTAssertEqual(ReactionRecents.load(defaults: defaults), ReactionRecents.seed)
    }

    func testOwnPickPushesOutLowestSeed() {
        let suite = "om.w4recent.pushout.test"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("no suite defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        // Fresh seed, then react with X (outside the seed): X first,
        // lowest-ranked seed drops, grid stays full.
        XCTAssertFalse(ReactionRecents.seed.contains("🚀"))
        ReactionRecents.record("🚀", defaults: defaults)
        let got = ReactionRecents.load(defaults: defaults)
        XCTAssertEqual(got.count, ReactionRecents.maxCount)
        XCTAssertEqual(got.first, "🚀")
        XCTAssertEqual(got, ["🚀"] + Array(ReactionRecents.seed.prefix(11)))
        // Re-picking a seed member moves it to front, no dupes.
        ReactionRecents.record("👍", defaults: defaults)
        let got2 = ReactionRecents.load(defaults: defaults)
        XCTAssertEqual(got2.count, ReactionRecents.maxCount)
        XCTAssertEqual(got2.first, "👍")
        XCTAssertEqual(Set(got2).count, got2.count)
        // Enough distinct picks push every seed out, most-recent-first.
        for e in ["📌", "✅", "⭐", "☕", "🍕", "⚽", "🎮", "💡", "❓", "❗", "🌟", "🎊"] {
            ReactionRecents.record(e, defaults: defaults)
        }
        let got3 = ReactionRecents.load(defaults: defaults)
        XCTAssertEqual(got3.count, ReactionRecents.maxCount)
        XCTAssertEqual(got3.first, "🎊")
        XCTAssertTrue(Set(got3).isDisjoint(with: Set(ReactionRecents.seed)))
    }
}
