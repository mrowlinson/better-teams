// NotifSettingsTests — om-notif-settings lane: notification settings.
//   - Persistence round-trip: banner/preview/sound prefs (UserDefaults)
//     and per-chat mutes (rules.json + RulesStore) survive reload.
//   - Mute wiring: muted chats skip as "chat-muted" through the rules
//     engine (beating keywords/meeting signals, yielding reason to the
//     global and Teams mutes), never banner; since fid-lists D19 they
//     accrue ROW unread but stay out of the dock total.
//   - Preview/sound rows reach the posted banner.
import XCTest

@testable import OstMacCore

final class NotifSettingsTests: XCTestCase {
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

    func cfg(_ rules: [NotifyRule] = [], mutes: Set<String> = []) -> RulesConfig {
        var c = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        c.notifyRules = rules
        c.mutedChatIDs = mutes
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
        UserDefaults(suiteName: "test-notif-settings-\(UUID().uuidString)") ?? .standard
    }

    /// Fresh rules.json path in its own temp dir (save() creates parents).
    func tempRulesPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ostmac-notif-settings-\(UUID().uuidString)/rules.json").path
    }

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    // MARK: prefs persistence (banner / preview / sound)

    func testPrefsDefaultOn() async {
        let notifs = await MessageNotifications(
            backend: FakeNotificationCenter(), defaults: isolatedDefaults())
        let (enabled, preview, sound) = await MainActor.run {
            (notifs.enabled, notifs.showPreview, notifs.sound)
        }
        XCTAssertTrue(enabled)
        XCTAssertTrue(preview)
        XCTAssertTrue(sound)
    }

    func testPrefsPersistAcrossInstances() async {
        let defaults = isolatedDefaults()
        let first = await MessageNotifications(
            backend: FakeNotificationCenter(), defaults: defaults)
        await MainActor.run {
            first.enabled = false
            first.showPreview = false
            first.sound = false
        }
        XCTAssertFalse(defaults.bool(forKey: MessageNotifications.enabledKey))
        XCTAssertFalse(defaults.bool(forKey: MessageNotifications.previewKey))
        XCTAssertFalse(defaults.bool(forKey: MessageNotifications.soundKey))
        let second = await MessageNotifications(
            backend: FakeNotificationCenter(), defaults: defaults)
        let (enabled, preview, sound) = await MainActor.run {
            (second.enabled, second.showPreview, second.sound)
        }
        XCTAssertFalse(enabled)
        XCTAssertFalse(preview)
        XCTAssertFalse(sound)
    }

    // MARK: per-chat mute persistence (rules.json)

    func testMutedChatIDsJSONRoundTrip() throws {
        var c = cfg([NotifyRule(kind: NotifyRule.skipMyMessages)], mutes: ["19:a@thread.v2", "19:b@thread.v2"])
        c.muted = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(RulesConfig.self, from: data)
        XCTAssertEqual(back.mutedChatIDs, ["19:a@thread.v2", "19:b@thread.v2"])
        XCTAssertTrue(back.muted)
        XCTAssertEqual(back.notifyRules, c.notifyRules)
    }

    func testMutedChatIDsFileRoundTrip() throws {
        let path = tempRulesPath()
        defer { cleanup(path) }
        let c = cfg([NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")], mutes: ["19:a@thread.v2"])
        try c.save(to: path)
        let back = RulesConfig.loadBestEffort(from: path)
        XCTAssertEqual(back.mutedChatIDs, ["19:a@thread.v2"])
        XCTAssertEqual(back.allowKeywords, ["outage"])
    }

    func testMutedChatIDsDecodeTolerance() throws {
        // Pre-lane files have no mutedChatIDs key: decode as unmuted.
        let data = Data(#"{"muted":false,"notifyRules":[]}"#.utf8)
        let back = try JSONDecoder().decode(RulesConfig.self, from: data)
        XCTAssertEqual(back.mutedChatIDs, [])
    }

    func testRulesStoreMutePersists() async {
        let path = tempRulesPath()
        defer { cleanup(path) }
        let store = await RulesStore(path: path)
        await MainActor.run { store.setMuted(chatID: "19:a@thread.v2", muted: true) }
        let isMuted = await MainActor.run { store.isMuted(chatID: "19:a@thread.v2") }
        XCTAssertTrue(isMuted)
        // A fresh store over the same file sees the mute, then clears it.
        let reopened = await RulesStore(path: path)
        let seen = await MainActor.run { reopened.isMuted(chatID: "19:a@thread.v2") }
        XCTAssertTrue(seen)
        await MainActor.run { reopened.setMuted(chatID: "19:a@thread.v2", muted: false) }
        let cleared = await MainActor.run { RulesStore(path: path).isMuted(chatID: "19:a@thread.v2") }
        XCTAssertFalse(cleared)
    }

    // MARK: mute wiring (rules engine)

    func testMutedChatSkips() {
        let c = cfg(mutes: ["19:chat@thread.v2"])
        XCTAssertEqual(
            decide(msg(), rules: c),
            .skip(reason: ChatFilter.chatMutedReason))
        // A sibling chat still notifies.
        XCTAssertEqual(
            decide(msg(chatID: "19:other@thread.v2"), rules: c),
            .notify(reason: "chat-message"))
    }

    func testChatMuteBeatsKeywordAllow() {
        let c = cfg(
            [NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")],
            mutes: ["19:chat@thread.v2"])
        XCTAssertEqual(
            decide(msg(text: "outage in prod"), rules: c),
            .skip(reason: ChatFilter.chatMutedReason))
    }

    func testChatMuteBeatsMeetingStartWithoutClaimingWindow() {
        let chatID = "19:meeting_abc@thread.v2"
        let beacon = msg(chatID: chatID, sender: "?", senderID: nil, text: "StandupPlay")
        var dedup = MeetingStartDedup()
        let now = Date()
        // Muted: skips, claims no window.
        let muted = cfg(mutes: [chatID])
        XCTAssertEqual(
            ChatFilter.decide(
                message: beacon, chatDisplayName: "Standup", ownerMRI: "8:orgid:me",
                rules: muted, meetingDedup: &dedup, now: now),
            .skip(reason: ChatFilter.chatMutedReason))
        // Unmuted later: the same meeting still fires meeting-starting.
        let unmuted = cfg()
        XCTAssertEqual(
            ChatFilter.decide(
                message: beacon, chatDisplayName: "Standup", ownerMRI: "8:orgid:me",
                rules: unmuted, meetingDedup: &dedup, now: now),
            .notify(reason: ChatFilter.meetingStartingReason))
    }

    func testGlobalMuteKeepsReasonOverChatMute() {
        var c = cfg(mutes: ["19:chat@thread.v2"])
        c.muted = true
        XCTAssertEqual(decide(msg(), rules: c), .skip(reason: "muted"))
    }

    func testTeamsMuteKeepsReasonOverChatMute() {
        let c = cfg(mutes: ["19:chat@thread.v2"])
        XCTAssertEqual(
            decide(msg(), rules: c, teamsMuted: ["19:chat@thread.v2"]),
            .skip(reason: ChatFilter.teamsMutedReason))
    }

    func testUnmuteRestoresNotify() {
        var c = cfg(mutes: ["19:chat@thread.v2"])
        XCTAssertEqual(decide(msg(), rules: c), .skip(reason: ChatFilter.chatMutedReason))
        c.mutedChatIDs.remove("19:chat@thread.v2")
        XCTAssertEqual(decide(msg(), rules: c), .notify(reason: "chat-message"))
    }

    func testEffectiveCarriesMutedIDs() {
        let eff = cfg(mutes: ["19:a@thread.v2"]).effective(forChat: "Anything")
        XCTAssertEqual(eff.mutedChatIDs, ["19:a@thread.v2"])
    }

    func testMutedChatAccruesRowNotBadge() async {
        // CONTRACT CHANGE (fid-lists D19): muted accrues ROW unread
        // (row bolds, Teams parity) but stays out of the dock total.
        let decision = decide(msg(), rules: cfg(mutes: ["19:chat@thread.v2"]))
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

    func testHandleSkipsMutedChat() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: isolatedDefaults())
        await notifs.handle(msg(), mutedChatIDs: ["19:chat@thread.v2"])
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 0)
    }

    // MARK: preview + sound reach the banner

    func testPreviewOffHidesBody() {
        let note = MessageNotifications.makeNotification(
            for: msg(text: "secret plans"), showPreview: false)
        XCTAssertEqual(note?.body, MessageNotifications.hiddenPreviewBody)
        XCTAssertFalse(note?.body.contains("secret plans") ?? true)
        XCTAssertEqual(note?.title, "Megan")
    }

    func testPreviewOnShowsText() {
        let note = MessageNotifications.makeNotification(
            for: msg(text: "secret plans"), showPreview: true)
        XCTAssertEqual(note?.body, "secret plans")
    }

    func testPreviewOffViaHandle() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: isolatedDefaults())
        await MainActor.run { notifs.showPreview = false }
        await notifs.handle(msg(text: "secret plans"))
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0].body, MessageNotifications.hiddenPreviewBody)
    }

    func testSoundReachesPostedBanner() async {
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: isolatedDefaults())
        await notifs.handle(msg(msgId: "loud"))
        await MainActor.run { notifs.sound = false }
        await notifs.handle(msg(msgId: "quiet"))
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 2)
        XCTAssertTrue(posted[0].sound)
        XCTAssertFalse(posted[1].sound)
    }
}
