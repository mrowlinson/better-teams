// RulesTests: om-rules notify/skip engine (TN port + OstMac adaptations).
import XCTest

@testable import OstMacCore

final class RulesTests: XCTestCase {
    // MARK: helpers

    func msg(
        chatID: String = "19:chat@thread.v2",
        msgId: String = "m1",
        sender: String = "Megan",
        senderID: String? = "8:orgid:megan",
        text: String = "hello",
        time: String = "2026-09-23T10:00:00Z",
        isEdit: Bool = false,
        editedID: String? = nil,
        raw: String? = nil,
        messageType: String? = "Text"
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: senderID, text: text, time: time,
            isEdit: isEdit, editedID: editedID, raw: raw,
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
        ownerMRI: String? = "8:orgid:me", rules: RulesConfig
    ) -> ChatFilter.Decision {
        ChatFilter.decide(message: m, chatDisplayName: chat, ownerMRI: ownerMRI, rules: rules)
    }

    // MARK: baseline gates

    func testBlankRulesNotifyEverything() {
        let d = decide(msg(), rules: cfg())
        XCTAssertEqual(d, .notify(reason: "chat-message"))
    }

    func testSkipOwnByMRI() {
        let c = cfg([NotifyRule(kind: NotifyRule.skipMyMessages)])
        let d = decide(msg(sender: "Me", senderID: "8:orgid:me", text: "echo"), rules: c)
        XCTAssertEqual(d, .skip(reason: "own-message"))
    }

    func testSkipOwnByNameBackup() {
        let c = cfg([NotifyRule(kind: NotifyRule.skipMyMessages)])
        let d = decide(msg(sender: "Me", senderID: nil, text: "echo"), rules: c)
        XCTAssertEqual(d, .skip(reason: "own-message"))
    }

    func testNameBackupOffMeansIDsOnly() {
        let c = cfg([
            NotifyRule(kind: NotifyRule.skipMyMessages),
            NotifyRule(kind: NotifyRule.nameBackup, enabled: false),
        ])
        let d = decide(msg(sender: "Me", senderID: nil, text: "echo"), rules: c)
        XCTAssertEqual(d, .notify(reason: "chat-message"))
    }

    func testTypeGate() {
        let c = cfg([NotifyRule(kind: NotifyRule.messageTypes, value: "Text, RichText")])
        XCTAssertEqual(
            decide(msg(messageType: "RichText/Html"), rules: c),
            .notify(reason: "chat-message"))
        XCTAssertEqual(
            decide(msg(messageType: "Control/Typing"), rules: c),
            .skip(reason: "type:Control"))
    }

    func testUnknownTypePassesGate() {
        // Old core omits message_type: unclassifiable, never skipped.
        let c = cfg([NotifyRule(kind: NotifyRule.messageTypes, value: "Text")])
        XCTAssertEqual(
            decide(msg(messageType: nil), rules: c),
            .notify(reason: "chat-message"))
        XCTAssertEqual(
            decide(msg(messageType: ""), rules: c),
            .notify(reason: "chat-message"))
    }

    func testEditGate() {
        let skipping = cfg([NotifyRule(kind: NotifyRule.skipEdited)])
        XCTAssertEqual(
            decide(msg(isEdit: true, editedID: "m0"), rules: skipping),
            .skip(reason: "edit"))
        // Absent skip-edited rule: edits notify (absent default ON).
        XCTAssertEqual(
            decide(msg(isEdit: true, editedID: "m0"), rules: cfg()),
            .notify(reason: "chat-message"))
    }

    func testMutedSkipsAll() {
        var c = cfg()
        c.muted = true
        XCTAssertEqual(decide(msg(), rules: c), .skip(reason: "muted"))
    }

    // MARK: noisy chats + mentions

    func testNoisyChatSkipsWithoutMention() {
        let c = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        XCTAssertEqual(
            decide(msg(), chat: "Watercooler Chat", rules: c),
            .skip(reason: "loud-no-mention"))
        XCTAssertEqual(
            decide(msg(), chat: "Team Chat", rules: c),
            .notify(reason: "chat-message"))
    }

    func testNoisyChatAtMentionNotifies() {
        let c = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        let m = msg(text: "hi Me", raw: #"hi <at id="0">Me</at>"#)
        XCTAssertEqual(
            decide(m, chat: "Watercooler Chat", rules: c),
            .notify(reason: "loud-owner-mention"))
    }

    func testNoisyChatChannelMentionGate() {
        let on = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        let off = cfg([
            NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler"),
            NotifyRule(kind: NotifyRule.noisyChannel, enabled: false),
        ])
        let m = msg(text: "hi channel", raw: #"hi <at id="0">channel</at>"#)
        XCTAssertEqual(
            decide(m, chat: "Watercooler Chat", rules: on),
            .notify(reason: "loud-channel-mention"))
        XCTAssertEqual(
            decide(m, chat: "Watercooler Chat", rules: off),
            .skip(reason: "loud-no-mention"))
    }

    // MARK: keywords (word-boundary + regex improvement)

    func testKeywordAllowThroughSkip() {
        let c = cfg([
            NotifyRule(kind: NotifyRule.skipMyMessages),
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
        ])
        let d = decide(msg(sender: "Me", senderID: "8:orgid:me", text: "outage in prod"), rules: c)
        XCTAssertEqual(d, .notify(reason: "keyword-allow"))
    }

    func testKeywordBlockBeatsAllow() {
        let c = cfg([
            NotifyRule(kind: NotifyRule.keywordAllow, value: "outage"),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch"),
        ])
        let d = decide(msg(text: "outage postmortem over lunch"), rules: c)
        XCTAssertEqual(d, .skip(reason: "keyword-block"))
    }

    func testWordBoundary() {
        XCTAssertTrue(KeywordMatch.contains("OUTAGE in prod", ["outage"]))
        XCTAssertFalse(KeywordMatch.contains("outages reported", ["outage"]))
        XCTAssertTrue(KeywordMatch.contains("fixed in c++ now", ["c++"]))
        XCTAssertTrue(KeywordMatch.contains("see #release notes", ["#release"]))
    }

    func testRegexKeyword() {
        XCTAssertTrue(KeywordMatch.contains("sev123 firing", ["re:sev-?\\d+"]))
        XCTAssertTrue(KeywordMatch.contains("SEV-9 firing", ["re:sev-?\\d+"]))
        XCTAssertFalse(KeywordMatch.contains("several things", ["re:sev-?\\d+"]))
    }

    func testInvalidRegexNeverMatches() {
        XCTAssertFalse(KeywordMatch.contains("anything", ["re:([unclosed"]))
        XCTAssertFalse(KeywordMatch.contains("anything", ["re:"]))
        XCTAssertFalse(KeywordMatch.contains("", ["outage"]))
        XCTAssertFalse(KeywordMatch.contains("outage", []))
    }

    // MARK: per-chat scope + order

    func testScopedRuleOnlyAppliesInScope() {
        let c = cfg([NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch", scope: "Watercooler")])
        XCTAssertEqual(
            decide(msg(text: "lunch?"), chat: "Watercooler Chat", rules: c),
            .skip(reason: "keyword-block"))
        XCTAssertEqual(
            decide(msg(text: "lunch?"), chat: "Team Chat", rules: c),
            .notify(reason: "chat-message"))
    }

    func testFirstInScopeKindWins() {
        // Scoped Text-only rule first, global allow-all second: chat A is
        // narrowed, chat B sees the global rule.
        let c = cfg([
            NotifyRule(kind: NotifyRule.messageTypes, value: "Text", scope: "Team A"),
            NotifyRule(kind: NotifyRule.messageTypes, value: "Text, Control"),
        ])
        XCTAssertEqual(
            decide(msg(messageType: "Control/Typing"), chat: "Team A", rules: c),
            .skip(reason: "type:Control"))
        XCTAssertEqual(
            decide(msg(messageType: "Control/Typing"), chat: "Team B", rules: c),
            .notify(reason: "chat-message"))
    }

    func testKeywordsMergeInOrderAcrossRules() {
        let c = cfg([
            NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch"),
            NotifyRule(kind: NotifyRule.keywordBlock, value: "kudos", scope: "Team Chat"),
        ])
        let eff = c.effective(forChat: "Team Chat")
        XCTAssertEqual(eff.blockKeywords, ["lunch", "kudos"])
        XCTAssertEqual(
            decide(msg(text: "kudos all around"), chat: "Team Chat", rules: c),
            .skip(reason: "keyword-block"))
        // Out-of-scope rule contributes nothing there.
        let other = c.effective(forChat: "Other")
        XCTAssertEqual(other.blockKeywords, ["lunch"])
    }

    func testScopeMatching() {
        let r = NotifyRule(kind: NotifyRule.keywordBlock, value: "x", scope: "Watercooler, BTAC")
        XCTAssertTrue(r.inScope(chatDisplayName: "watercooler chat"))
        XCTAssertTrue(r.inScope(chatDisplayName: "BTAC-ops"))
        XCTAssertFalse(r.inScope(chatDisplayName: "Team Chat"))
        XCTAssertTrue(NotifyRule(kind: NotifyRule.keywordBlock, value: "x").inScope(chatDisplayName: "Anything"))
    }

    // MARK: meeting signals + dedup

    func testPlayBeaconFirstNotifiesRepeatSuppresses() {
        var dedup = MeetingStartDedup()
        let now = Date()
        let beacon = msg(chatID: "19:meeting_abc@thread.v2", sender: "?", senderID: nil, text: "StandupPlay")
        let first = ChatFilter.decide(
            message: beacon, chatDisplayName: "Standup", ownerMRI: nil,
            rules: cfg(), meetingDedup: &dedup, now: now)
        XCTAssertEqual(first, .notify(reason: "meeting-starting"))
        let second = ChatFilter.decide(
            message: beacon, chatDisplayName: "Standup", ownerMRI: nil,
            rules: cfg(), meetingDedup: &dedup, now: now.addingTimeInterval(60))
        XCTAssertEqual(second, .skip(reason: "meeting-start-suppressed"))
        // Gap > window past the slid window: a later meeting notifies again.
        let later = ChatFilter.decide(
            message: beacon, chatDisplayName: "Standup", ownerMRI: nil,
            rules: cfg(), meetingDedup: &dedup,
            now: now.addingTimeInterval(MeetingStartDedup.windowSeconds + 120))
        XCTAssertEqual(later, .notify(reason: "meeting-starting"))
    }

    func testObserveExtendsOpenWindowOnly() {
        var dedup = MeetingStartDedup()
        let now = Date()
        dedup.observe(chatID: "c", date: now) // no window: leaves no trace
        XCTAssertEqual(dedup.count, 0)
        XCTAssertTrue(dedup.shouldNotify(chatID: "c", date: now))
        dedup.observe(chatID: "c", date: now.addingTimeInterval(3600)) // slides
        // Window now ends at +3600+7200; a signal at +7000 still folds.
        XCTAssertFalse(dedup.shouldNotify(chatID: "c", date: now.addingTimeInterval(7000)))
    }

    func testQuestionMarkSenderCountsAsUnknown() {
        // The core renders missing senders as "?"; beacons must still match.
        XCTAssertEqual(
            MeetingSignal.classify(
                text: "StandupPlay", content: "StandupPlay",
                chatID: "19:chat@thread.v2", senderName: "?",
                chatDisplayName: "Standup"),
            .playBeacon)
        XCTAssertEqual(
            MeetingSignal.classify(
                text: "StandupPlay", content: "StandupPlay",
                chatID: "19:chat@thread.v2", senderName: "Megan",
                chatDisplayName: "Standup"),
            .normal)
    }

    func testMeetingBlobStrictness() {
        // scopeId+storageId without a meeting key: plain JSON blob (skipped,
        // never opens the meeting window).
        let blob = msg(text: #"{"scopeId":"a","storageId":"b"}"#)
        XCTAssertEqual(decide(blob, rules: cfg()), .skip(reason: "json-blob"))
        let meeting = msg(text: #"{"scopeId":"a","storageId":"b","meetingTenantId":"t"}"#)
        XCTAssertEqual(decide(meeting, rules: cfg()), .notify(reason: "meeting-starting"))
    }

    func testFacilitatorOpenClose() {
        let open = msg(sender: "Facilitator", senderID: nil, text: "I am here to help with the meeting")
        XCTAssertEqual(decide(open, rules: cfg()), .notify(reason: "meeting-starting"))
        let close = msg(sender: "Facilitator", senderID: nil, text: "That’s a wrap, thanks all")
        XCTAssertEqual(decide(close, rules: cfg()), .skip(reason: "facilitator-close"))
    }

    // MARK: mentions parsing

    func testSpanMentionParse() {
        let raw = #"hi <span itemtype="http://schema.skype.com/Mention" itemid="0">Me</span>"#
        let found = Mentions.parseFromContent(raw)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].displayName, "Me")
        XCTAssertTrue(Mentions.mentionsOwner(found, ownerMRI: nil, ownerDisplayName: "Me"))
    }

    func testAtMentionParse() {
        let found = Mentions.parseAtTags(#"hi <at id="0">Me &amp; Co</at>"#)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].displayName, "Me & Co")
        // Missing id synthesizes a positional one (never drops).
        XCTAssertEqual(Mentions.parseAtTags("hi <at>Me</at>").count, 1)
    }

    func testChannelMentionClassify() {
        XCTAssertTrue(Mentions.mentionsChannelOrEveryone(
            [Mention(id: "0", mri: nil, mentionType: "Channel", displayName: "x")]))
        XCTAssertTrue(Mentions.mentionsChannelOrEveryone(
            [Mention(id: "0", mri: nil, displayName: "Everyone")]))
        XCTAssertFalse(Mentions.mentionsChannelOrEveryone(
            [Mention(id: "0", mri: nil, displayName: "Me")]))
    }

    func testOwnerMRIPreferredOverName() {
        let m = [Mention(id: "0", mri: "8:orgid:other", displayName: "Me")]
        XCTAssertFalse(Mentions.mentionsOwner(m, ownerMRI: "8:orgid:me", ownerDisplayName: "Me"))
        let hit = [Mention(id: "0", mri: "8:orgid:me", displayName: "Someone")]
        XCTAssertTrue(Mentions.mentionsOwner(hit, ownerMRI: "8:orgid:me", ownerDisplayName: "Me"))
    }

    // MARK: rules store + config

    func testRuleDecodeTolerance() throws {
        // Legacy kind maps, missing enabled/scope fall back.
        let r = try decodeOrThrow(NotifyRule.self, from: Data(#"{"kind":"skip-own"}"#.utf8))
        XCTAssertEqual(r.kind, NotifyRule.skipMyMessages)
        XCTAssertTrue(r.enabled)
        XCTAssertEqual(r.scope, "")
        // Unknown kinds round-trip.
        let custom = try decodeOrThrow(
            NotifyRule.self, from: Data(#"{"kind":"my-future","value":"v","enabled":false,"scope":"A"}"#.utf8))
        XCTAssertEqual(custom.kind, "my-future")
        XCTAssertFalse(custom.enabled)
        XCTAssertEqual(custom.scope, "A")
    }

    func testAbsentGateDefaults() {
        // Absent noisy-channel/name-backup = ON; absent skip-own = OFF.
        let eff = cfg().effective(forChat: "Anything")
        XCTAssertTrue(eff.noisyChannelMentions)
        XCTAssertTrue(eff.matchByDisplayName)
        XCTAssertFalse(eff.skipOwnMessages)
        XCTAssertTrue(eff.notifyOnEdit)
        XCTAssertEqual(eff.notifyTypes, [NotifyRule.allowAllMarker])
    }

    func testNormalizeDropsBadRules() {
        var c = cfg([
            NotifyRule(kind: "", value: "x"),
            NotifyRule(kind: NotifyRule.noisyChats, value: ""),
            NotifyRule(kind: NotifyRule.skipMyMessages),
        ])
        let warnings = c.normalizeRules()
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(c.notifyRules, [NotifyRule(kind: NotifyRule.skipMyMessages)])
    }

    func testRealtimeMessageTypeDecode() throws {
        let json = """
        {"ok":true,"resync":false,"skipped":0,"messages":[
        {"chat_id":"c","id":"1","sender":"P","text":"hi","time":"t",
         "is_edit":false,"message_type":"RichText/Html"},
        {"chat_id":"c","id":"2","sender":"P","text":"hi","time":"t",
         "is_edit":false}]}
        """
        let p = try decodeOrThrow(RealtimePoll.self, from: Data(json.utf8))
        XCTAssertEqual(p.messages[0].messageType, "RichText/Html")
        XCTAssertNil(p.messages[1].messageType)
    }

    func testConfigRoundTripAndBestEffort() throws {
        var c = cfg([NotifyRule(kind: NotifyRule.keywordAllow, value: "outage")])
        c.muted = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(RulesConfig.self, from: data)
        XCTAssertEqual(back.allowKeywords, ["outage"])
        XCTAssertTrue(back.muted)
        // Missing file -> default (never throws).
        let fresh = RulesConfig.loadBestEffort(from: "/nonexistent/ostmac-rules-test.json")
        XCTAssertEqual(fresh, RulesConfig.default)
    }
}
