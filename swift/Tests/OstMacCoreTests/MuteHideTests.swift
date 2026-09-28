// MuteHideTests — om-mute-hide lane: absolute per-chat mute + hide/restore.
//   - Mute wiring: a muted chat skips as "chat-muted" even when the
//     message mentions the owner or the channel (absolute: mentions do
//     NOT break through per-chat mute, unlike the global and Teams
//     mutes). Muted mentions never banner; since fid-lists D19 they
//     accrue ROW unread but stay out of the dock total.
//   - Hide/restore: the hidden filter drops hidden ids in order, the
//     show-hidden pass restores every row, hide/unhide persist.
//   - Persistence: hidden ids survive JSON + file + store round-trips;
//     pre-lane files (no hiddenChatIDs key) decode as nothing hidden.
import XCTest

@testable import OstMacCore

final class MuteHideTests: XCTestCase {
    // MARK: helpers

    func msg(
        chatID: String = "19:chat@thread.v2",
        msgId: String = "m1",
        sender: String = "Megan",
        senderID: String? = "8:orgid:megan",
        text: String = "hello",
        isEdit: Bool = false,
        editedID: String? = nil,
        raw: String? = nil,
        messageType: String? = "Text"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: senderID, text: text, time: "2026-09-23T10:00:00Z",
            isEdit: isEdit, editedID: editedID, raw: raw,
            messageType: messageType)
    }

    /// Owner mention mined from `<at>` markup (the live-path shape).
    func ownerMention(chatID: String = "19:chat@thread.v2") -> RealtimeMessage {
        msg(chatID: chatID, text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
    }

    /// Channel mention mined from `<at>` markup (display-name fallback).
    func channelMention(chatID: String = "19:chat@thread.v2") -> RealtimeMessage {
        msg(chatID: chatID, text: "hi channel", raw: #"hi <at id="0">@channel</at>"#)
    }

    func cfg(
        _ rules: [NotifyRule] = [], mutes: Set<String> = [],
        hidden: Set<String> = []
    ) -> RulesConfig {
        var c = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        c.notifyRules = rules
        c.mutedChatIDs = mutes
        c.hiddenChatIDs = hidden
        c.applyRules()
        return c
    }

    func decide(
        _ m: RealtimeMessage, chat: String = "Team Chat",
        ownerMRI: String? = "8:orgid:me", rules: RulesConfig,
        teamsMuted: Set<String> = []
    ) -> ChatFilter.Decision {
        ChatFilter.decide(
            message: m, chatDisplayName: chat, ownerMRI: ownerMRI,
            rules: rules, teamsMutedChatIDs: teamsMuted)
    }

    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-mute-hide-\(UUID().uuidString)") ?? .standard
    }

    /// Fresh rules.json path in its own temp dir (save() creates parents).
    func tempRulesPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ostmac-mute-hide-\(UUID().uuidString)/rules.json").path
    }

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    func chat(id: String, name: String) -> ChatItem {
        ChatItem(chatId: id, name: name)
    }

    // MARK: mute wiring — mentions do NOT break through per-chat mute

    func testChatMuteSuppressesOwnerMention() {
        let c = cfg(mutes: ["19:chat@thread.v2"])
        XCTAssertEqual(
            decide(ownerMention(), rules: c),
            .skip(reason: ChatFilter.chatMutedReason))
        // Unmuted control: the same mention notifies.
        XCTAssertEqual(
            decide(ownerMention(), rules: cfg()),
            .notify(reason: "chat-message"))
    }

    func testChatMuteSuppressesChannelMention() {
        let c = cfg(mutes: ["19:chat@thread.v2"])
        XCTAssertEqual(
            decide(channelMention(), rules: c),
            .skip(reason: ChatFilter.chatMutedReason))
        // Unmuted control: the same mention notifies.
        XCTAssertEqual(
            decide(channelMention(), rules: cfg()),
            .notify(reason: "chat-message"))
    }

    func testChatMuteAbsoluteAgainstOtherMutes() {
        // Same owner mention under each mute: only the per-chat mute is
        // absolute — the global and Teams mutes break through.
        var global = cfg()
        global.muted = true
        XCTAssertEqual(
            decide(ownerMention(), rules: global),
            .notify(reason: MentionAlert.breakthroughReason))
        XCTAssertEqual(
            decide(ownerMention(), rules: cfg(), teamsMuted: ["19:chat@thread.v2"]),
            .notify(reason: MentionAlert.breakthroughReason))
        XCTAssertEqual(
            decide(ownerMention(), rules: cfg(mutes: ["19:chat@thread.v2"])),
            .skip(reason: ChatFilter.chatMutedReason))
    }

    func testMutedMentionNeverBanners() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: isolatedDefaults())
        // Defensive mute-set gate.
        await notifs.handle(ownerMention(), mutedChatIDs: ["19:chat@thread.v2"])
        // Rules-verdict gate (the live path's chat-muted decision).
        await notifs.handle(
            ownerMention(chatID: "19:other@thread.v2"),
            decision: .skip(reason: ChatFilter.chatMutedReason))
        let suppressed = await fake.posted
        XCTAssertEqual(suppressed.count, 0)
        // Unmuted control: the mention banners.
        await notifs.handle(ownerMention(chatID: "19:other@thread.v2"))
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 1)
    }

    func testMutedMentionAccruesRowNotBadge() async {
        // CONTRACT CHANGE (fid-lists D19): a muted mention still
        // bolds its row (Teams parity) but stays out of the dock
        // total — see FidListsTests for the full matrix.
        let decision = decide(ownerMention(), rules: cfg(mutes: ["19:chat@thread.v2"]))
        XCTAssertEqual(decision, .skip(reason: ChatFilter.chatMutedReason))
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        await MainActor.run {
            unread.ingest(decision: decision, chatID: "19:chat@thread.v2", openChatID: nil)
        }
        let row = await MainActor.run { unread.count(for: "19:chat@thread.v2") }
        let total = await MainActor.run { unread.total }
        XCTAssertEqual(row, 1)
        XCTAssertEqual(total, 0)
        XCTAssertTrue(dock.labels.isEmpty)
    }

    // MARK: hide / restore (list visibility only)

    func testFilterHiddenDropsHiddenInOrder() {
        let chats = [
            chat(id: "a", name: "A"), chat(id: "b", name: "B"),
            chat(id: "c", name: "C"),
        ]
        let out = ChatListFormat.filterHidden(chats, hiddenIDs: ["b"])
        XCTAssertEqual(out.map(\.id), ["a", "c"])
    }

    func testFilterHiddenShowHiddenRestores() {
        let chats = [
            chat(id: "a", name: "A"), chat(id: "b", name: "B"),
        ]
        let out = ChatListFormat.filterHidden(
            chats, hiddenIDs: ["a", "b"], showHidden: true)
        XCTAssertEqual(out.map(\.id), ["a", "b"])
    }

    func testFilterHiddenEmptyAndUnknown() {
        let chats = [chat(id: "a", name: "A")]
        XCTAssertEqual(
            ChatListFormat.filterHidden(chats, hiddenIDs: []).map(\.id), ["a"])
        XCTAssertEqual(
            ChatListFormat.filterHidden(chats, hiddenIDs: ["zzz"]).map(\.id), ["a"])
    }

    func testHideIsVisibilityOnly() {
        // Hidden threads keep their rules verdict (notify): hiding never
        // silences banners or unread — mute owns that.
        let c = cfg(hidden: ["19:chat@thread.v2"])
        XCTAssertEqual(
            decide(msg(), rules: c),
            .notify(reason: "chat-message"))
        XCTAssertEqual(
            decide(ownerMention(), rules: c),
            .notify(reason: "chat-message"))
        // And the hidden set never leaks into the resolved gates.
        XCTAssertTrue(cfg(hidden: ["19:chat@thread.v2"]).effective(forChat: "Team Chat").mutedChatIDs.isEmpty)
    }

    func testRulesStoreHidePersists() async {
        let path = tempRulesPath()
        defer { cleanup(path) }
        let store = await RulesStore(path: path)
        await MainActor.run { store.setHidden(chatID: "19:a@thread.v2", hidden: true) }
        let isHidden = await MainActor.run { store.isHidden(chatID: "19:a@thread.v2") }
        XCTAssertTrue(isHidden)
        // A fresh store over the same file sees the hide, then clears it.
        let reopened = await RulesStore(path: path)
        let seen = await MainActor.run { reopened.isHidden(chatID: "19:a@thread.v2") }
        XCTAssertTrue(seen)
        await MainActor.run { reopened.setHidden(chatID: "19:a@thread.v2", hidden: false) }
        let cleared = await MainActor.run { RulesStore(path: path).isHidden(chatID: "19:a@thread.v2") }
        XCTAssertFalse(cleared)
    }

    func testRulesStoreHideIgnoresBlankID() async {
        let store = await RulesStore(path: tempRulesPath())
        await MainActor.run { store.setHidden(chatID: "", hidden: true) }
        let hidden = await MainActor.run { store.config.hiddenChatIDs }
        XCTAssertTrue(hidden.isEmpty)
    }

    // MARK: persistence

    func testHiddenChatIDsJSONRoundTrip() throws {
        var c = cfg(
            [NotifyRule(kind: NotifyRule.skipMyMessages)],
            mutes: ["19:m@thread.v2"], hidden: ["19:a@thread.v2", "19:b@thread.v2"])
        c.muted = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(RulesConfig.self, from: data)
        XCTAssertEqual(back.hiddenChatIDs, ["19:a@thread.v2", "19:b@thread.v2"])
        XCTAssertEqual(back.mutedChatIDs, ["19:m@thread.v2"])
        XCTAssertTrue(back.muted)
        XCTAssertEqual(back.notifyRules, c.notifyRules)
    }

    func testHiddenChatIDsFileRoundTrip() throws {
        let path = tempRulesPath()
        defer { cleanup(path) }
        let c = cfg(
            [NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")],
            hidden: ["19:a@thread.v2"])
        try c.save(to: path)
        let back = RulesConfig.loadBestEffort(from: path)
        XCTAssertEqual(back.hiddenChatIDs, ["19:a@thread.v2"])
        XCTAssertEqual(back.allowKeywords, ["outage"])
    }

    func testHiddenChatIDsDecodeTolerance() throws {
        // Pre-lane files have no hiddenChatIDs key: decode as all shown.
        let data = Data(#"{"muted":false,"notifyRules":[]}"#.utf8)
        let back = try JSONDecoder().decode(RulesConfig.self, from: data)
        XCTAssertEqual(back.hiddenChatIDs, [])
    }
}
