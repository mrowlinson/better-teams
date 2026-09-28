// KeywordAlertsTests — d2-alerts: keyword alerts + per-chat 3-state levels.
//
// Pins scope accept 1-5: keyword add/remove + rules.json round-trip,
// allow-through-noisy, block-beats-allow, elevated keyword banner style,
// 3-state level matrix, and no-breakthrough through chat-muted/DND/quiet.
import XCTest

@testable import OstMacCore

@MainActor
final class KeywordAlertsTests: XCTestCase {
    // MARK: helpers

    func msg(
        chatID: String = "19:chat@thread.v2",
        msgId: String = "m1",
        sender: String = "Megan",
        senderID: String? = "8:orgid:megan",
        text: String = "hello",
        isEdit: Bool = false,
        raw: String? = nil,
        messageType: String? = "Text"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: senderID, text: text,
            time: "2026-09-23T10:00:00Z",
            isEdit: isEdit, editedID: nil, raw: raw,
            messageType: messageType)
    }

    func cfg(_ rules: [NotifyRule] = [], owner: String = "Me", mri: String = "8:orgid:me") -> RulesConfig {
        var c = RulesConfig(owner: RulesOwner(displayName: owner, mri: mri))
        c.notifyRules = rules
        c.applyRules()
        return c
    }

    func decide(
        _ m: RealtimeMessage, chat: String = "Team Chat",
        ownerMRI: String? = "8:orgid:me", rules: RulesConfig,
        dnd: Bool = false, quiet: Bool = false
    ) -> ChatFilter.Decision {
        ChatFilter.decide(
            message: m, chatDisplayName: chat, ownerMRI: ownerMRI,
            rules: rules, dndActive: dnd, quietActive: quiet)
    }

    /// Unique temp rules.json path (no file created — missing-file default).
    func tempPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kw-\(UUID().uuidString).json").path
    }

    // MARK: - KeywordAlert policy (accept 3)

    func testKeywordReasons() {
        XCTAssertEqual(KeywordAlert.allowReason, "keyword-allow")
        XCTAssertEqual(KeywordAlert.blockReason, "keyword-block")
    }

    func testKeywordSubtitle() {
        XCTAssertEqual(KeywordAlert.subtitle, "Keyword alert")
    }

    func testKeywordElevationMapsAllowOnly() {
        let hit = KeywordAlert.elevation(forReason: KeywordAlert.allowReason)
        XCTAssertTrue(hit.isElevated)
        XCTAssertEqual(hit.subtitle, "Keyword alert")
        for reason in ["chat-message", "loud-owner-mention", MentionAlert.breakthroughReason, ChatFilter.meetingStartingReason] {
            let plain = KeywordAlert.elevation(forReason: reason)
            XCTAssertFalse(plain.isElevated, "reason \(reason) is not a keyword hit")
            XCTAssertNil(plain.subtitle)
        }
    }

    // MARK: - allow-through-noisy (accept 2)

    func testAllowThroughNoisy() {
        let c = cfg([
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler"),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
        ])
        XCTAssertEqual(
            decide(msg(text: "OUTAGE in prod"), chat: "Watercooler Chat", rules: c),
            .notify(reason: "keyword-allow"))
        XCTAssertEqual(
            decide(msg(text: "lunch plans"), chat: "Watercooler Chat", rules: c),
            .skip(reason: "loud-no-mention"))
    }

    func testBlockBeatsAllow() {
        let c = cfg([
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "drill"),
        ])
        XCTAssertEqual(
            decide(msg(text: "outage drill today"), rules: c),
            .skip(reason: "keyword-block"))
        XCTAssertEqual(
            decide(msg(text: "outage in prod"), rules: c),
            .notify(reason: "keyword-allow"))
    }

    func testWholeWordBoundaries() {
        XCTAssertTrue(KeywordMatch.contains("OUTAGE in prod", ["outage"]))
        XCTAssertFalse(KeywordMatch.contains("outages everywhere", ["outage"]))
        XCTAssertFalse(KeywordMatch.contains("anything", []))
    }

    func testRegexKeywords() {
        XCTAssertTrue(KeywordMatch.contains("sev123 firing", ["re:sev-?\\d+"]))
        XCTAssertFalse(KeywordMatch.contains("all quiet", ["re:sev-?\\d+"]))
        XCTAssertFalse(KeywordMatch.contains("anything at all", ["re:([invalid"]))
    }

    // MARK: - no breakthrough through mute/DND/quiet (accept 5)

    func testAllowYieldsToChatMuted() {
        var c = cfg([NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")])
        c.mutedChatIDs = ["19:chat@thread.v2"]
        XCTAssertEqual(
            decide(msg(text: "outage now"), rules: c),
            .skip(reason: "chat-muted"))
    }

    func testAllowYieldsToDNDAndQuiet() {
        let c = cfg([NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")])
        XCTAssertEqual(
            decide(msg(text: "outage now"), rules: c, dnd: true),
            .skip(reason: "dnd"))
        XCTAssertEqual(
            decide(msg(text: "outage now"), rules: c, quiet: true),
            .skip(reason: "quiet-hours"))
    }

    // MARK: - 3-state level matrix (accept 4)

    func testMentionsOnlyScope() {
        var c = cfg()
        c.mentionOnlyChatIDs = ["19:chat@thread.v2"]
        // Plain message in a mentions-only chat: silent.
        XCTAssertEqual(
            decide(msg(text: "hello team"), rules: c),
            .skip(reason: "loud-no-mention"))
        // Owner mention notifies (noisy-rule semantics, scoped to chat).
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(
            decide(at, rules: c),
            .notify(reason: "loud-owner-mention"))
        // Channel mention notifies (noisy-channel gate defaults on).
        let blast = msg(text: "hi channel", raw: #"hi <at id="0">channel</at>"#)
        XCTAssertEqual(
            decide(blast, rules: c),
            .notify(reason: "loud-channel-mention"))
        // Other chats unaffected.
        XCTAssertEqual(
            decide(msg(chatID: "19:other@thread.v2", text: "hello"), rules: c),
            .notify(reason: "chat-message"))
    }

    func testMentionsOnlyYieldsToKeywords() {
        var c = cfg([
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "drill"),
        ])
        c.mentionOnlyChatIDs = ["19:chat@thread.v2"]
        // Allow forces notify through mentions-only (noisy parity).
        XCTAssertEqual(
            decide(msg(text: "outage now"), rules: c),
            .notify(reason: "keyword-allow"))
        // Block keeps its reason on mention hits too.
        let at = msg(text: "outage drill", raw: #"outage <at id="0">@Me</at> drill"#)
        XCTAssertEqual(
            decide(at, rules: c),
            .skip(reason: "keyword-block"))
    }

    func testMutedAbsoluteOverMentionsOnly() {
        var c = cfg()
        c.mentionOnlyChatIDs = ["19:chat@thread.v2"]
        c.mutedChatIDs = ["19:chat@thread.v2"]
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(
            decide(at, rules: c),
            .skip(reason: "chat-muted"))
    }

    func testLevelResolution() {
        var c = RulesConfig.default
        let chat = "19:chat@thread.v2"
        XCTAssertEqual(c.level(chatID: chat), .all)
        c.mentionOnlyChatIDs = [chat]
        XCTAssertEqual(c.level(chatID: chat), .mentions)
        c.mutedChatIDs = [chat]
        XCTAssertEqual(c.level(chatID: chat), .muted)
        c.mutedChatIDs = []
        XCTAssertEqual(c.level(chatID: chat), .mentions)
    }

    // MARK: - RulesStore keywords + levels (accept 1)

    func testStoreKeywordAddRemoveRoundTrip() throws {
        let path = tempPath()
        let store = RulesStore(path: path)
        XCTAssertNil(store.addAllowKeyword("outage"))
        XCTAssertNil(store.addAllowKeyword("urgent"))
        XCTAssertNil(store.addBlockKeyword("lunch"))
        XCTAssertEqual(store.config.allowKeywords, ["outage", "urgent"])
        XCTAssertEqual(store.config.blockKeywords, ["lunch"])
        // Dupes (any case) are silent no-ops.
        XCTAssertNil(store.addAllowKeyword("OUTAGE"))
        XCTAssertEqual(store.config.allowKeywords, ["outage", "urgent"])
        // Reload from disk: persisted.
        let reloaded = RulesStore(path: path)
        XCTAssertEqual(reloaded.config.allowKeywords, ["outage", "urgent"])
        XCTAssertEqual(reloaded.config.blockKeywords, ["lunch"])
        // Remove persists too; last-word removal drops the rule.
        store.removeAllowKeyword("outage")
        store.removeAllowKeyword("urgent")
        XCTAssertEqual(store.config.allowKeywords, [])
        XCTAssertFalse(RulesStore(path: path).config.notifyRules.contains {
            $0.kind == NotifyRule.keywordAllow
        })
        try? FileManager.default.removeItem(atPath: path)
    }

    func testStoreKeywordEmptyRefused() {
        let store = RulesStore(path: tempPath())
        let expected = NotifyRule(kind: NotifyRule.keywordAllow).plainIssue()
        XCTAssertNotNil(expected)
        XCTAssertEqual(store.addAllowKeyword("  "), expected)
        XCTAssertEqual(store.config.allowKeywords, [])
        let blockExpected = NotifyRule(kind: NotifyRule.keywordBlock).plainIssue()
        XCTAssertEqual(store.addBlockKeyword(""), blockExpected)
        XCTAssertEqual(store.config.blockKeywords, [])
    }

    func testStoreLevelRoundTrip() throws {
        let path = tempPath()
        let chat = "19:chat@thread.v2"
        let store = RulesStore(path: path)
        XCTAssertEqual(store.level(chatID: chat), .all)
        store.setLevel(chatID: chat, level: .mentions)
        XCTAssertEqual(store.level(chatID: chat), .mentions)
        XCTAssertFalse(store.isMuted(chatID: chat))
        store.setLevel(chatID: chat, level: .muted)
        XCTAssertEqual(store.level(chatID: chat), .muted)
        XCTAssertTrue(store.isMuted(chatID: chat))
        XCTAssertEqual(RulesStore(path: path).level(chatID: chat), .muted)
        store.setLevel(chatID: chat, level: .all)
        XCTAssertEqual(RulesStore(path: path).level(chatID: chat), .all)
        try? FileManager.default.removeItem(atPath: path)
    }

    func testMissingFileDefaults() {
        // Clean checkout, no rules.json: blank keywords, all-chat default.
        let store = RulesStore(path: tempPath())
        XCTAssertEqual(store.config.allowKeywords, [])
        XCTAssertEqual(store.config.blockKeywords, [])
        XCTAssertEqual(store.level(chatID: "19:chat@thread.v2"), .all)
        XCTAssertEqual(
            decide(msg(text: "outage"), rules: store.config),
            .notify(reason: "chat-message"))
    }

    // MARK: - elevated keyword banner (accept 3, FakeNotificationCenter)

    func testKeywordBannerElevated() async {
        let c = cfg([NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")])
        let m = msg(text: "outage in prod")
        let decision = decide(m, chat: "Watercooler Chat", rules: c)
        XCTAssertEqual(decision, .notify(reason: "keyword-allow"))
        guard case .notify(let reason) = decision else {
            return XCTFail("expected notify")
        }
        let elev = KeywordAlert.elevation(forReason: reason)
        let banner = NcDelivery.makeBanner(
            for: m, chatName: "Watercooler Chat",
            decision: decision, screenLocked: false,
            isMention: elev.isElevated, subtitle: elev.subtitle)
        let center = FakeNotificationCenter()
        if let banner {
            await center.post(PostedNotification(
                id: banner.id, chatID: banner.chatID,
                title: banner.title, body: banner.body,
                threadIdentifier: banner.threadIdentifier,
                sound: banner.sound, isMention: banner.isMention,
                subtitle: banner.subtitle))
        }
        let posted = await center.delivered()
        XCTAssertEqual(posted.count, 1)
        XCTAssertTrue(posted[0].isMention)
        XCTAssertEqual(posted[0].subtitle, "Keyword alert")
    }

    func testKeywordBannerNeverLeaksText() {
        let c = cfg([NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")])
        let m = msg(text: "outage in prod")
        let decision = decide(m, rules: c)
        let elev = KeywordAlert.elevation(forReason: "keyword-allow")
        // Preview off: body hidden, subtitle carries no keyword text.
        let hidden = NcDelivery.makeBanner(
            for: m, chatName: "Team Chat",
            decision: decision, screenLocked: false, showPreview: false,
            isMention: elev.isElevated, subtitle: elev.subtitle)
        XCTAssertEqual(hidden?.body, MessageNotifications.hiddenPreviewBody)
        XCTAssertFalse(hidden?.subtitle?.contains("outage") ?? true)
        // Locked: generic title/body, safe subtitle.
        let locked = NcDelivery.makeBanner(
            for: m, chatName: "Team Chat",
            decision: decision, screenLocked: true,
            isMention: elev.isElevated, subtitle: elev.subtitle)
        XCTAssertEqual(locked?.title, NcDelivery.redactedTitle)
        XCTAssertEqual(locked?.body, NcDelivery.redactedBody)
        XCTAssertEqual(locked?.subtitle, "Keyword alert")
    }
}
