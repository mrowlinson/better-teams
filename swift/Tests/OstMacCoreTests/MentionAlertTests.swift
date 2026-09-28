// MentionAlertTests — om-mention-alerts: breakthrough matrix (mute vs
// DND vs quiet), elevated banner style, Mentions-row dock badge.
import XCTest

@testable import OstMacCore

@MainActor
final class MentionAlertTests: XCTestCase {
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
            senderID: senderID, text: text,
            time: "2026-09-23T10:00:00Z",
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
        ownerMRI: String? = "8:orgid:me", rules: RulesConfig,
        teamsMuted: Set<String> = [], dnd: Bool = false, quiet: Bool = false
    ) -> ChatFilter.Decision {
        ChatFilter.decide(
            message: m, chatDisplayName: chat, ownerMRI: ownerMRI,
            rules: rules, teamsMutedChatIDs: teamsMuted,
            dndActive: dnd, quietActive: quiet)
    }

    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-mention-alerts-\(UUID().uuidString)") ?? .standard
    }

    func fixedCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return cal
    }

    func dateAt(hour: Int, minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 23,
            hour: hour, minute: minute)) ?? Date()
    }

    // MARK: - breakthrough matrix: mute

    func testMutedPlainSkips() {
        var c = cfg()
        c.muted = true
        XCTAssertEqual(
            decide(msg(), rules: c),
            .skip(reason: "muted"))
    }

    func testMutedOwnerMentionBreaksThrough() {
        var c = cfg()
        c.muted = true
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(
            decide(at, rules: c),
            .notify(reason: MentionAlert.breakthroughReason))
        let span = msg(
            text: "hi Me",
            raw: #"hi <span itemtype="http://schema.skype.com/Mention" itemid="0">Me</span>"#)
        XCTAssertEqual(
            decide(span, rules: c),
            .notify(reason: MentionAlert.breakthroughReason))
    }

    func testMutedTeamMentionBreaksThrough() {
        var c = cfg()
        c.muted = true
        for name in ["channel", "team", "everyone"] {
            let m = msg(text: "hi \(name)", raw: #"hi <at id="0">\#(name)</at>"#)
            XCTAssertEqual(
                decide(m, rules: c),
                .notify(reason: MentionAlert.breakthroughReason),
                "muted @\(name) should break through")
        }
    }

    func testTeamsMutedMentionBreaksThroughPlainSkips() {
        let c = cfg()
        let muted: Set<String> = ["19:chat@thread.v2"]
        XCTAssertEqual(
            decide(msg(), rules: c, teamsMuted: muted),
            .skip(reason: "teams-muted"))
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(
            decide(at, rules: c, teamsMuted: muted),
            .notify(reason: MentionAlert.breakthroughReason))
    }

    func testUnmutedMentionKeepsNormalReason() {
        // Breakthrough is mute-only: unmuted mentions notify with the
        // regular reasons (no elevated banner outside mute).
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(
            decide(at, rules: cfg()),
            .notify(reason: "chat-message"))
        let noisy = cfg([NotifyRule(kind: NotifyRule.noisyChats, value: "Watercooler")])
        XCTAssertEqual(
            decide(at, chat: "Watercooler Chat", rules: noisy),
            .notify(reason: "loud-owner-mention"))
    }

    // MARK: - breakthrough matrix: DND vs quiet

    func testDNDSuppressesMentionMutedOrNot() {
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(
            decide(at, rules: cfg(), dnd: true),
            .skip(reason: MentionAlert.dndReason))
        var c = cfg()
        c.muted = true
        XCTAssertEqual(
            decide(at, rules: c, dnd: true),
            .skip(reason: MentionAlert.dndReason))
        XCTAssertEqual(
            decide(msg(), rules: c, dnd: true),
            .skip(reason: MentionAlert.dndReason))
    }

    func testQuietSuppressesMentionMutedOrNot() {
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(
            decide(at, rules: cfg(), quiet: true),
            .skip(reason: MentionAlert.quietReason))
        var c = cfg()
        c.muted = true
        XCTAssertEqual(
            decide(at, rules: c, quiet: true),
            .skip(reason: MentionAlert.quietReason))
        XCTAssertEqual(
            decide(msg(), rules: c, quiet: true),
            .skip(reason: MentionAlert.quietReason))
    }

    func testDNDBeatsQuietBeatsMute() {
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        var c = cfg()
        c.muted = true
        XCTAssertEqual(
            decide(at, rules: c, dnd: true, quiet: true),
            .skip(reason: MentionAlert.dndReason))
    }

    // MARK: - breakthrough limits

    func testOwnMentionNeverBreaksThrough() {
        var c = cfg([NotifyRule(kind: NotifyRule.skipMyMessages)])
        c.muted = true
        // Self-mention by MRI.
        let mri = msg(
            sender: "Me", senderID: "8:orgid:me", text: "note to self @Me",
            raw: #"note to self <at id="0">@Me</at>"#)
        XCTAssertEqual(decide(mri, rules: c), .skip(reason: "muted"))
        // Self-mention by name backup (no sender MRI).
        let named = msg(
            sender: "Me", senderID: nil, text: "note to self @Me",
            raw: #"note to self <at id="0">@Me</at>"#)
        XCTAssertEqual(decide(named, rules: c), .skip(reason: "muted"))
    }

    func testBlockedMentionNeverBreaksThrough() {
        var c = cfg([NotifyRule(kind: NotifyRule.keywordBlock, value: "lunch")])
        c.muted = true
        let m = msg(
            text: "lunch with @Me?",
            raw: #"lunch with <at id="0">@Me</at>?"#)
        XCTAssertEqual(decide(m, rules: c), .skip(reason: "muted"))
    }

    func testStructuralMentionNeverBreaksThrough() {
        var c = cfg()
        c.muted = true
        // JSON blob body carrying raw mention markup: never notifiable.
        let blob = msg(
            text: #"{"a":1}"#,
            raw: #"<p>{"a":1} <at id="0">@Me</at></p>"#)
        XCTAssertEqual(decide(blob, rules: c), .skip(reason: "muted"))
        // Muted beacons stay muted (no window claim on the skip path).
        let beacon = msg(
            chatID: "19:meeting_abc@thread.v2", sender: "?",
            senderID: nil, text: "StandupPlay")
        XCTAssertEqual(
            decide(beacon, chat: "Standup", rules: c),
            .skip(reason: "muted"))
    }

    func testEditAndTypeGatesHoldThroughMute() {
        // Skipped edits don't break through.
        var skipping = cfg([NotifyRule(kind: NotifyRule.skipEdited)])
        skipping.muted = true
        let edit = msg(
            text: "hi @Me", isEdit: true, editedID: "m0",
            raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(decide(edit, rules: skipping), .skip(reason: "muted"))
        // …but notifying edits do.
        var notifying = cfg()
        notifying.muted = true
        XCTAssertEqual(
            decide(edit, rules: notifying),
            .notify(reason: MentionAlert.breakthroughReason))
        // Unlisted types don't break through.
        var typed = cfg([NotifyRule(kind: NotifyRule.messageTypes, value: "Text")])
        typed.muted = true
        let control = msg(
            text: "hi Me", raw: #"hi <at id="0">@Me</at>"#,
            messageType: "Control/Typing")
        XCTAssertEqual(decide(control, rules: typed), .skip(reason: "muted"))
    }

    func testNameBackupOffBlocksNameBreakthrough() {
        var c = cfg([NotifyRule(kind: NotifyRule.nameBackup, enabled: false)])
        c.muted = true
        // IDs only: a name-mined mention (live path carries no MRI)
        // cannot break through.
        let m = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        XCTAssertEqual(decide(m, rules: c), .skip(reason: "muted"))
    }

    // MARK: - elevated classification

    func testIsElevated() {
        // Owner by MRI (properties path).
        XCTAssertTrue(MentionAlert.isElevated(
            mentions: [Mention(id: "0", mri: "8:orgid:me", displayName: "Someone")],
            ownerMRI: "8:orgid:me", ownerDisplayName: "Me"))
        // Owner by name backup.
        XCTAssertTrue(MentionAlert.isElevated(
            mentions: [Mention(id: "0", mri: nil, displayName: "@Me")],
            ownerMRI: nil, ownerDisplayName: "Me"))
        XCTAssertFalse(MentionAlert.isElevated(
            mentions: [Mention(id: "0", mri: nil, displayName: "@Me")],
            ownerMRI: nil, ownerDisplayName: "Me", matchByName: false))
        // Channel/team/everyone by type or spelling.
        XCTAssertTrue(MentionAlert.isElevated(
            mentions: [Mention(id: "0", mri: nil, mentionType: "Team", displayName: "x")],
            ownerMRI: nil, ownerDisplayName: "Me"))
        XCTAssertTrue(MentionAlert.isElevated(
            mentions: [Mention(id: "0", mri: nil, displayName: "everyone")],
            ownerMRI: nil, ownerDisplayName: "Me"))
        // Plain mention of someone else: not elevated.
        XCTAssertFalse(MentionAlert.isElevated(
            mentions: [Mention(id: "0", mri: nil, displayName: "Bo")],
            ownerMRI: nil, ownerDisplayName: "Me"))
        XCTAssertFalse(MentionAlert.isElevated(
            mentions: [], ownerMRI: nil, ownerDisplayName: "Me"))
    }

    func testSubtitle() {
        XCTAssertEqual(
            MentionAlert.subtitle(ownerMention: true, channelMention: false),
            "Mentioned you")
        XCTAssertEqual(
            MentionAlert.subtitle(ownerMention: false, channelMention: true),
            "Channel mention")
        // Owner wins when both hit.
        XCTAssertEqual(
            MentionAlert.subtitle(ownerMention: true, channelMention: true),
            "Mentioned you")
        XCTAssertNil(MentionAlert.subtitle(ownerMention: false, channelMention: false))
    }

    func testSoundAndCategories() {
        XCTAssertEqual(MentionAlert.sound(isMention: true), .critical)
        XCTAssertEqual(MentionAlert.sound(isMention: false), .default)
        XCTAssertEqual(MentionAlert.categoryID, "OM_MENTION")
        XCTAssertEqual(MentionAlert.categoryNoReplyID, "OM_MENTION_NOREPLY")
    }

    func testIsDND() {
        XCTAssertTrue(MentionAlert.isDND(ownAvailability: "DoNotDisturb"))
        XCTAssertFalse(MentionAlert.isDND(ownAvailability: "Busy"))
        XCTAssertFalse(MentionAlert.isDND(ownAvailability: "Available"))
        XCTAssertFalse(MentionAlert.isDND(ownAvailability: nil))
        XCTAssertFalse(MentionAlert.isDND(ownAvailability: ""))
    }

    // MARK: - legacy banner: rules gate + elevated style

    func testHandleRespectsRulesSkip() async {
        let fake = FakeNotificationCenter()
        let notifs = MessageNotifications(backend: fake, defaults: isolatedDefaults())
        await notifs.handle(
            msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#),
            ownDisplayName: "Me",
            decision: .skip(reason: "muted"))
        let skipped = await fake.posted
        XCTAssertEqual(skipped.count, 0)
        // …and posts on notify (nil decision keeps the legacy behavior).
        await notifs.handle(
            msg(msgId: "m2"), ownDisplayName: "Me",
            decision: .notify(reason: "chat-message"))
        await notifs.handle(msg(msgId: "m3"), ownDisplayName: "Me")
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 2)
    }

    func testMakeNotificationFlagsMentionStyle() {
        let at = MessageNotifications.makeNotification(
            for: msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#),
            ownDisplayName: "Me")
        XCTAssertEqual(at?.isMention, true)
        XCTAssertEqual(at?.subtitle, "Mentioned you")
        // Channel mentions elevate without any owner identity.
        let channel = MessageNotifications.makeNotification(
            for: msg(text: "hi team", raw: #"hi <at id="0">team</at>"#))
        XCTAssertEqual(channel?.isMention, true)
        XCTAssertEqual(channel?.subtitle, "Channel mention")
        // Plain messages stay plain.
        let plain = MessageNotifications.makeNotification(
            for: msg(), ownDisplayName: "Me")
        XCTAssertEqual(plain?.isMention, false)
        XCTAssertNil(plain?.subtitle)
    }

    // MARK: - Mentions-row dock badge

    func testMentionBadgeLabelPure() {
        XCTAssertNil(MentionStore.badgeLabel(forCount: 0))
        XCTAssertEqual(MentionStore.badgeLabel(forCount: 1), "1")
        XCTAssertEqual(MentionStore.badgeLabel(forCount: 12), "12")
    }

    func testMentionIngestDrivesDock() {
        let dock = FakeDockBadge()
        let store = MentionStore(dock: dock)
        let mining = #"hi <at id="0">@Me</at>"#
        store.ingest(
            realtime: msg(chatID: "a", raw: mining),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        store.ingest(
            realtime: msg(chatID: "b", raw: mining),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        XCTAssertEqual(store.badgeLabel, "2")
        XCTAssertEqual(dock.labels, ["1", "2"])
        // Re-flagging the same thread writes nothing new.
        store.ingest(
            realtime: msg(chatID: "a", msgId: "m2", raw: mining),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        XCTAssertEqual(dock.labels, ["1", "2"])
        // Non-mentions never touch the dock.
        store.ingest(
            realtime: msg(chatID: "c", text: "hello"),
            ownName: "Me", ownerMRI: "8:orgid:me", openChatID: nil)
        XCTAssertEqual(dock.labels, ["1", "2"])
    }

    func testMentionMarkReadSyncsDock() {
        let dock = FakeDockBadge()
        let store = MentionStore(dock: dock)
        store.adopt(["a", "b"])
        XCTAssertEqual(dock.labels, ["2"])
        store.markRead(chatID: "a")
        XCTAssertEqual(store.badgeLabel, "1")
        XCTAssertEqual(dock.labels, ["2", "1"])
        // Unknown id: no dock write.
        store.markRead(chatID: "zzz")
        XCTAssertEqual(dock.labels, ["2", "1"])
        store.markAllRead()
        XCTAssertNil(store.badgeLabel)
        XCTAssertEqual(dock.labels, ["2", "1", nil])
        // Empty + identical adopt: no dock write.
        store.markAllRead()
        store.adopt([])
        XCTAssertEqual(dock.labels, ["2", "1", nil])
    }

    func testMentionNoteThreadDrivesDock() {
        let dock = FakeDockBadge()
        let store = MentionStore(dock: dock)
        let mining = ChatMessage(
            id: "1", sender: "Megan", timestamp: "2026-09-23T10:00:00Z",
            content: "hi @Me", raw: #"<p>hi <at id="0">@Me</at></p>"#)
        store.noteThread(chatID: "t", messages: [mining], ownName: "Me")
        XCTAssertEqual(dock.labels, ["1"])
        // No mined mention: no write.
        let plain = ChatMessage(
            id: "2", sender: "Megan", timestamp: "2026-09-23T10:00:00Z",
            content: "hello")
        store.noteThread(chatID: "u", messages: [plain], ownName: "Me")
        XCTAssertEqual(dock.labels, ["1"])
    }

    // MARK: - breakthrough accrues unread (badge path)

    func testBreakthroughAccruesUnreadSuppressedDoesNot() {
        var dedup = MeetingStartDedup()
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        var c = cfg()
        c.muted = true
        let at = msg(text: "hi Me", raw: #"hi <at id="0">@Me</at>"#)
        let d1 = unread.ingest(
            message: at, chatDisplayName: "Team Chat",
            ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil)
        XCTAssertEqual(d1, .notify(reason: MentionAlert.breakthroughReason))
        XCTAssertEqual(unread.total, 1)
        // DND + quiet mentions accrue nothing.
        let d2 = unread.ingest(
            message: msg(msgId: "m2", text: "hi Me", raw: #"hi <at id="0">@Me</at>"#),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil, dndActive: true)
        XCTAssertEqual(d2, .skip(reason: MentionAlert.dndReason))
        let d3 = unread.ingest(
            message: msg(msgId: "m3", text: "hi Me", raw: #"hi <at id="0">@Me</at>"#),
            chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me", rules: c,
            meetingDedup: &dedup, now: Date(), openChatID: nil, quietActive: true)
        XCTAssertEqual(d3, .skip(reason: MentionAlert.quietReason))
        XCTAssertEqual(unread.total, 1)
        XCTAssertEqual(dock.labels, ["1"])
    }

    // MARK: - quiet hours (shared QuietHoursStore/Window — HEAD API)

    func testQuietDisabledOrDegenerateNeverFires() {
        let cal = fixedCalendar()
        let noon = dateAt(hour: 12, calendar: cal)
        XCTAssertFalse(QuietHoursWindow(enabled: false).contains(noon, calendar: cal))
        // Equal bounds = empty window, even when enabled.
        XCTAssertFalse(QuietHoursWindow(enabled: true, startMinutes: 60, endMinutes: 60)
            .contains(dateAt(hour: 1, calendar: cal), calendar: cal))
    }

    func testQuietSameDayWindow() {
        let cal = fixedCalendar()
        let q = QuietHoursWindow(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60)
        XCTAssertFalse(q.contains(dateAt(hour: 8, minute: 59, calendar: cal), calendar: cal))
        XCTAssertTrue(q.contains(dateAt(hour: 9, calendar: cal), calendar: cal))
        XCTAssertTrue(q.contains(dateAt(hour: 12, calendar: cal), calendar: cal))
        XCTAssertFalse(q.contains(dateAt(hour: 17, calendar: cal), calendar: cal))
    }

    func testQuietOvernightWindow() {
        let cal = fixedCalendar()
        let q = QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60)
        XCTAssertTrue(q.contains(dateAt(hour: 23, calendar: cal), calendar: cal))
        XCTAssertTrue(q.contains(dateAt(hour: 0, calendar: cal), calendar: cal))
        XCTAssertTrue(q.contains(dateAt(hour: 6, minute: 59, calendar: cal), calendar: cal))
        XCTAssertFalse(q.contains(dateAt(hour: 7, calendar: cal), calendar: cal))
        XCTAssertFalse(q.contains(dateAt(hour: 12, calendar: cal), calendar: cal))
        XCTAssertFalse(q.contains(dateAt(hour: 21, minute: 59, calendar: cal), calendar: cal))
        XCTAssertTrue(q.contains(dateAt(hour: 22, calendar: cal), calendar: cal))
    }

    func testQuietSummaryAndClamp() {
        XCTAssertEqual(
            QuietHoursWindow(enabled: true, startMinutes: 22 * 60, endMinutes: 7 * 60).rangeLabel,
            "22:00–07:00")
        XCTAssertTrue(QuietHoursWindow(enabled: true, startMinutes: 60, endMinutes: 60).isEmpty)
        // Out-of-range bounds normalize into the day.
        XCTAssertEqual(QuietHoursWindow.norm(-5), 0)
        XCTAssertEqual(QuietHoursWindow.norm(9999), 1439)
    }

    func testQuietMinutesRoundTrip() {
        let cal = fixedCalendar()
        let at = dateAt(hour: 22, minute: 30, calendar: cal)
        XCTAssertEqual(QuietHoursWindow.minutes(of: at, calendar: cal), 22 * 60 + 30)
        // Picker dates carry the stored minutes back.
        let back = QuietHoursStore.timeOfDay(minutes: 7 * 60 + 5, now: at, calendar: cal)
        XCTAssertEqual(QuietHoursStore.minutes(ofTime: back, calendar: cal), 7 * 60 + 5)
    }

    func testQuietStorePersists() {
        let defaults = isolatedDefaults()
        let first = QuietHoursStore(defaults: defaults)
        XCTAssertFalse(first.windowEnabled)
        first.windowEnabled = true
        first.startMinutes = 60
        first.endMinutes = 120
        XCTAssertTrue(defaults.bool(forKey: QuietHoursStore.enabledKey))
        XCTAssertEqual(defaults.integer(forKey: QuietHoursStore.startKey), 60)
        XCTAssertEqual(defaults.integer(forKey: QuietHoursStore.endKey), 120)
        let second = QuietHoursStore(defaults: defaults)
        XCTAssertTrue(second.windowEnabled)
        XCTAssertEqual(second.startMinutes, 60)
        XCTAssertEqual(second.endMinutes, 120)
        let cal = fixedCalendar()
        XCTAssertTrue(second.isQuiet(at: dateAt(hour: 1, calendar: cal), calendar: cal))
        XCTAssertFalse(second.isQuiet(at: dateAt(hour: 3, calendar: cal), calendar: cal))
    }

    // MARK: - Diagnostics formatters

    func testMentionDiagnosticsLines() {
        XCTAssertEqual(DiagnosticsFormat.mentionsLine(count: 0), "0 threads")
        XCTAssertEqual(DiagnosticsFormat.mentionsLine(count: 3), "3 threads")
        XCTAssertEqual(
            DiagnosticsFormat.unreadLine(total: 5, chats: 2),
            "5 messages · 2 chats")
        XCTAssertEqual(
            DiagnosticsFormat.mentionAlertsLine(breakthroughs: 1, dnd: 2, quiet: 3),
            "1 breakthroughs · 2 DND · 3 quiet")
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: false, schedule: false, suppressed: 0),
            "off · 0 suppressed")
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: false, schedule: true, suppressed: 3),
            "on (schedule) · 3 suppressed")
        XCTAssertEqual(
            DiagnosticsFormat.quietHoursLine(dnd: true, schedule: false, suppressed: 1),
            "on (DND) · 1 suppressed")
    }
}
