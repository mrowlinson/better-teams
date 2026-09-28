// GapG1Tests.swift — gap-g1: background events + unified notif roll-up
// for inactive accounts. Stub fetchers only; zero network. Fixture
// tokens ONLY.
import UserNotifications
import XCTest

@testable import OstMacCore

final class GapG1Tests: XCTestCase {
    static let now: UInt64 = 1_760_000_000

    var store: MemoryTokenStore!
    var http: StubReadFetcher!
    var grants: StubGrantFetcher!

    override func setUp() {
        super.setUp()
        CoreReads.whoamiCacheClearAll()
        store = MemoryTokenStore(now: { Self.now })
        http = StubReadFetcher()
        http.testCase = self
        grants = StubGrantFetcher()
    }

    override func tearDown() {
        CoreReads.whoamiCacheClearAll()
        super.tearDown()
    }

    // MARK: - helpers

    func ctx() -> ReadContext {
        ReadContext(
            store: store, http: http, refresher: grants,
            now: { Self.now }
        )
    }

    func signIn(profile: String) {
        try! store.save(TokenSlots(
            accessToken: StoredTokenValue(
                token: "FIXTURE-AAD", now: Self.now, expiresIn: 3_600
            ),
            refreshToken: "FIXTURE-RT",
            skypeToken: StoredTokenValue(
                token: "FIXTURE-SKYPE", now: Self.now, expiresIn: 3_600
            ),
            graphToken: StoredTokenValue(
                token: "FIXTURE-GRAPH", now: Self.now, expiresIn: 3_600
            )
        ), profile: profile)
    }

    func accounts() -> [AccountRecord] {
        [
            AccountRecord(id: "acct-a", displayName: "Amy Active", userID: "oid-a"),
            AccountRecord(id: "acct-b", displayName: "Beth Away", userID: "oid-b"),
        ]
    }

    func chat(
        id: String = "19:grp@thread.v2", name: String = "Grp",
        time: String? = "t1", sender: String? = "Ava", preview: String? = "hi"
    ) -> ChatItem {
        ChatItem(
            chatId: id, name: name, is_group: true,
            last_message_time: time, last_message_sender: sender,
            last_message_preview: preview)
    }

    // MARK: - poller diff

    func testFirstSweepSeedsSilently() {
        let poller = BackgroundAccountPoller(fetch: { _ in
            ChatsResponse(ok: true, chats: [self.chat()])
        })
        let events = poller.pollOnce(accounts: accounts(), activeID: "acct-a")
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(poller.snapshotAccountIDs, ["acct-b"])
    }

    func testChangedFingerprintEmitsEvent() {
        let preview = LockedBox("hi")
        let poller = BackgroundAccountPoller(fetch: { _ in
            ChatsResponse(ok: true, chats: [self.chat(preview: preview.value)])
        })
        XCTAssertTrue(poller.pollOnce(accounts: accounts(), activeID: "acct-a").isEmpty)
        preview.value = "hi again"
        let events = poller.pollOnce(accounts: accounts(), activeID: "acct-a")
        XCTAssertEqual(events.count, 1)
        let ev = events[0]
        XCTAssertEqual(ev.accountID, "acct-b")
        XCTAssertEqual(ev.accountName, "Beth Away")
        XCTAssertEqual(ev.chatID, "19:grp@thread.v2")
        XCTAssertEqual(ev.chatName, "Grp")
        XCTAssertTrue(ev.isGroup)
        XCTAssertEqual(ev.sender, "Ava")
        XCTAssertEqual(ev.text, "hi again")
        // Live-shaped: stamped with the owning (inactive) account.
        XCTAssertEqual(ev.asRealtimeMessage.accountID, "acct-b")
        XCTAssertEqual(ev.asRealtimeMessage.chatID, "19:grp@thread.v2")
    }

    func testUnchangedEmitsNothing() {
        let poller = BackgroundAccountPoller(fetch: { _ in
            ChatsResponse(ok: true, chats: [self.chat()])
        })
        let acc = accounts()
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
    }

    func testActiveAccountNeverFetched() {
        let fetched = LockedBox<[String]>([])
        let poller = BackgroundAccountPoller(fetch: { profile in
            fetched.mutate { $0.append(profile) }
            return ChatsResponse(ok: true, chats: [])
        })
        _ = poller.pollOnce(accounts: accounts(), activeID: "acct-a")
        XCTAssertEqual(fetched.value, ["acct-b"])
    }

    func testNewChatOnLaterSweepEmits() {
        let chats = LockedBox([chat(id: "19:old@thread.v2", name: "Old")])
        let poller = BackgroundAccountPoller(fetch: { _ in
            ChatsResponse(ok: true, chats: chats.value)
        })
        let acc = accounts()
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
        let added = chat(id: "19:new@thread.v2", name: "New")
        chats.mutate { $0.append(added) }
        let events = poller.pollOnce(accounts: acc, activeID: "acct-a")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].chatID, "19:new@thread.v2")
    }

    func testVanishedChatForgottenSilently() {
        let chats = LockedBox([chat()])
        let poller = BackgroundAccountPoller(fetch: { _ in
            ChatsResponse(ok: true, chats: chats.value)
        })
        let acc = accounts()
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
        chats.value = []
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
    }

    func testEmptyChatNeverEmits() {
        let chats = LockedBox([chat(id: "19:seed@thread.v2", name: "Seed")])
        let poller = BackgroundAccountPoller(fetch: { _ in
            ChatsResponse(ok: true, chats: chats.value)
        })
        let acc = accounts()
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
        chats.mutate { $0.append(ChatItem(chatId: "19:empty@thread.v2", name: "Empty")) }
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
    }

    func testFetchFailureSkipsAccountKeepsOthers() {
        struct Boom: Error {}
        let failB = LockedBox(true)
        let poller = BackgroundAccountPoller(fetch: { profile in
            if profile == "acct-b", failB.value { throw Boom() }
            return ChatsResponse(ok: true, chats: [])
        })
        let acc = accounts() + [AccountRecord(id: "acct-c", displayName: "Cid")]
        // acct-b fails, acct-c seeds — no throw, no events.
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
        XCTAssertNotNil(poller.lastError(for: "acct-b"))
        XCTAssertNil(poller.lastError(for: "acct-c"))
        // Success clears the recorded error.
        failB.value = false
        XCTAssertTrue(poller.pollOnce(accounts: acc, activeID: "acct-a").isEmpty)
        XCTAssertNil(poller.lastError(for: "acct-b"))
    }

    func testDropAndReset() {
        let poller = BackgroundAccountPoller(fetch: { _ in
            ChatsResponse(ok: true, chats: [self.chat()])
        })
        _ = poller.pollOnce(accounts: accounts(), activeID: "acct-a")
        poller.drop(accountID: "acct-b")
        XCTAssertTrue(poller.snapshotAccountIDs.isEmpty)
        _ = poller.pollOnce(accounts: accounts(), activeID: "acct-a")
        XCTAssertEqual(poller.snapshotAccountIDs, ["acct-b"])
        poller.reset()
        XCTAssertTrue(poller.snapshotAccountIDs.isEmpty)
    }

    func testMessageIDStableAndDistinct() {
        let a = BackgroundChatEvent.messageID(
            accountID: "b", chatID: "c", fingerprint: "f")
        let b = BackgroundChatEvent.messageID(
            accountID: "b", chatID: "c", fingerprint: "f")
        let c = BackgroundChatEvent.messageID(
            accountID: "b", chatID: "c", fingerprint: "g")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("bg-"))
        XCTAssertNotEqual(a, c)
    }

    // MARK: - per-account rules snapshot

    func testSnapshotStampsOwner() {
        var base = RulesConfig.default
        base.owner = RulesOwner(displayName: "Amy Active", mri: "8:orgid:oid-a")
        base.mutedChatIDs = ["19:muted@thread.v2"]
        let snap = BackgroundRules.snapshot(
            base: base,
            account: AccountRecord(id: "acct-b", displayName: "Beth Away", userID: "oid-b"))
        XCTAssertEqual(snap.owner.displayName, "Beth Away")
        XCTAssertEqual(snap.owner.mri, "8:orgid:oid-b")
        // Non-identity gates ride the global config.
        XCTAssertEqual(snap.mutedChatIDs, ["19:muted@thread.v2"])
        XCTAssertEqual(BackgroundRules.ownerMRI(
            account: AccountRecord(id: "acct-b", displayName: "Beth Away", userID: "oid-b")),
            "8:orgid:oid-b")
    }

    func testSnapshotUnknownUserIDFallsBackToName() {
        var base = RulesConfig.default
        base.owner = RulesOwner(displayName: "Amy Active", mri: "8:orgid:oid-a")
        let snap = BackgroundRules.snapshot(
            base: base,
            account: AccountRecord(id: "acct-b", displayName: "Beth Away"))
        XCTAssertEqual(snap.owner.displayName, "Beth Away")
        // Never the ACTIVE account's MRI — empty falls back to name match.
        XCTAssertEqual(snap.owner.mri, "")
        XCTAssertNil(BackgroundRules.ownerMRI(
            account: AccountRecord(id: "acct-b", displayName: "Beth Away")))
    }

    func testSnapshotDrivesOwnMessageSkip() {
        // Blank rules = notify everything (own included): enable the
        // skip-own gate like a configured rules.json does.
        var base = RulesConfig.default
        base.notifyRules = [NotifyRule(kind: NotifyRule.skipMyMessages, enabled: true)]
        let snap = BackgroundRules.snapshot(
            base: base,
            account: AccountRecord(id: "acct-b", displayName: "Beth Away", userID: "oid-b"))
        let own = RealtimeMessage(
            chatID: "19:g@thread.v2", msgId: "m1", sender: "Beth Away",
            text: "from my other account", time: "t", isEdit: false,
            accountID: "acct-b")
        let peer = RealtimeMessage(
            chatID: "19:g@thread.v2", msgId: "m2", sender: "Ava",
            text: "hello beth", time: "t", isEdit: false,
            accountID: "acct-b")
        if case .skip = ChatFilter.decide(
            message: own, chatDisplayName: "Grp",
            ownerMRI: "8:orgid:oid-b", rules: snap) {} else {
            XCTFail("background own-message must skip")
        }
        if case .notify = ChatFilter.decide(
            message: peer, chatDisplayName: "Grp",
            ownerMRI: "8:orgid:oid-b", rules: snap) {} else {
            XCTFail("background peer message must notify")
        }
    }

    // MARK: - roll-up stash

    func testRollupNoteTakeDropClear() {
        var roll = BackgroundUnreadRollup()
        XCTAssertTrue(roll.isEmpty)
        roll.note(accountID: "acct-b", chatID: "19:x")
        roll.note(accountID: "acct-b", chatID: "19:x")
        roll.note(accountID: "acct-b", chatID: "19:y")
        roll.note(accountID: "acct-c", chatID: "19:z")
        roll.note(accountID: "  ", chatID: "19:blank") // no-op
        roll.note(accountID: "acct-b", chatID: "") // no-op
        XCTAssertEqual(roll.total(for: "acct-b"), 3)
        XCTAssertEqual(roll.counts(for: "acct-b"), ["19:x": 2, "19:y": 1])
        XCTAssertEqual(roll.grandTotal, 4)
        // Switch handoff drains exactly one account.
        XCTAssertEqual(
            roll.take(accountID: "acct-b"), ["19:x": 2, "19:y": 1])
        XCTAssertEqual(roll.total(for: "acct-b"), 0)
        XCTAssertEqual(roll.grandTotal, 1)
        XCTAssertEqual(roll.take(accountID: "acct-unknown"), [:])
        roll.drop(accountID: "acct-c")
        XCTAssertTrue(roll.isEmpty)
        roll.note(accountID: "acct-b", chatID: "19:x")
        roll.clear()
        XCTAssertTrue(roll.isEmpty)
    }

    // MARK: - banner naming + userInfo routing

    func testAccountUserInfoRoundTrip() {
        let info = OmReplyInfo.userInfo(chatID: "19:x", accountID: "acct-b")
        XCTAssertEqual(info[OmReplyInfo.chatIDKey], "19:x")
        XCTAssertEqual(info[OmReplyInfo.accountIDKey], "acct-b")
        XCTAssertEqual(NcDelivery.accountID(from: info), "acct-b")
        XCTAssertNil(NcDelivery.accountID(from: [:]))
        XCTAssertNil(NcDelivery.accountID(from: [OmReplyInfo.accountIDKey: ""]))
    }

    func testActiveUserInfoOmitsAccount() {
        let info = OmReplyInfo.userInfo(chatID: "19:x")
        XCTAssertNil(info[OmReplyInfo.accountIDKey])
        XCTAssertNil(NcDelivery.accountID(from: info))
    }

    func testMakeBannerNamesAccount() {
        let msg = RealtimeMessage(
            chatID: "19:g@thread.v2", msgId: "m1", sender: "Ava",
            text: "hello", time: "t", isEdit: false, accountID: "acct-b")
        let banner = NcDelivery.makeBanner(
            for: msg, chatName: "Grp",
            decision: .notify(reason: "chat-message"), screenLocked: false,
            accountName: "Beth Away")
        XCTAssertEqual(banner?.title, "[Beth Away] Ava in Grp")
        // 1:1 collapse keeps the prefix.
        let solo = NcDelivery.makeBanner(
            for: msg, chatName: "Ava",
            decision: .notify(reason: "chat-message"), screenLocked: false,
            accountName: "Beth Away")
        XCTAssertEqual(solo?.title, "[Beth Away] Ava")
        // Nil/blank = live behavior, verbatim title.
        let live = NcDelivery.makeBanner(
            for: msg, chatName: "Grp",
            decision: .notify(reason: "chat-message"), screenLocked: false)
        XCTAssertEqual(live?.title, "Ava in Grp")
    }

    func testMakeBannerLockedHidesAccount() {
        let msg = RealtimeMessage(
            chatID: "19:g@thread.v2", msgId: "m1", sender: "Ava",
            text: "secret", time: "t", isEdit: false, accountID: "acct-b")
        let banner = NcDelivery.makeBanner(
            for: msg, chatName: "Grp",
            decision: .notify(reason: "chat-message"), screenLocked: true,
            accountName: "Beth Away")
        XCTAssertEqual(banner?.title, NcDelivery.redactedTitle)
        XCTAssertEqual(banner?.body, NcDelivery.redactedBody)
    }

    func testMakeBannerPreviewOffKeepsAccount() {
        let msg = RealtimeMessage(
            chatID: "19:g@thread.v2", msgId: "m1", sender: "Ava",
            text: "secret", time: "t", isEdit: false, accountID: "acct-b")
        let banner = NcDelivery.makeBanner(
            for: msg, chatName: "Grp",
            decision: .notify(reason: "chat-message"), screenLocked: false,
            showPreview: false, accountName: "Beth Away")
        XCTAssertEqual(banner?.title, "[Beth Away] Ava in Grp")
        XCTAssertEqual(banner?.body, MessageNotifications.hiddenPreviewBody)
    }

    func testDispatchBroadcastsAccount() {
        let openExp = expectation(forNotification: .omNotifOpenChat, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:x"
                && $0.userInfo?["accountID"] as? String == "acct-b"
        }
        let r = MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: OmReplyInfo.userInfo(chatID: "19:x", accountID: "acct-b"))
        XCTAssertEqual(r, .open(chatID: "19:x"))
        wait(for: [openExp], timeout: 1)

        let replyExp = expectation(forNotification: .omNotifReply, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:x"
                && $0.userInfo?["text"] as? String == "yo"
                && $0.userInfo?["accountID"] as? String == "acct-b"
        }
        let r2 = MessageNotifications.dispatch(
            actionID: OmReplyInfo.replyActionID,
            userInfo: OmReplyInfo.userInfo(chatID: "19:x", accountID: "acct-b"),
            replyText: "yo")
        XCTAssertEqual(r2, .reply(chatID: "19:x", text: "yo"))
        wait(for: [replyExp], timeout: 1)
    }

    func testDispatchActiveOmitsAccount() {
        let exp = expectation(forNotification: .omNotifOpenChat, object: nil) {
            $0.userInfo?["chatID"] as? String == "19:x"
                && $0.userInfo?["accountID"] == nil
        }
        _ = MessageNotifications.dispatch(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: OmReplyInfo.userInfo(chatID: "19:x"))
        wait(for: [exp], timeout: 1)
    }

    // MARK: - feed profile concept

    func testAccountIDDecode() throws {
        let withAcct = """
            {"chat_id":"19:x","id":"m1","sender":"A","text":"t","time":"t",\
            "is_edit":false,"account_id":"acct-b"}
            """.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(RealtimeMessage.self, from: withAcct).accountID,
            "acct-b")
        let without = """
            {"chat_id":"19:x","id":"m1","sender":"A","text":"t","time":"t",\
            "is_edit":false}
            """.data(using: .utf8)!
        XCTAssertNil(
            try JSONDecoder().decode(RealtimeMessage.self, from: without).accountID)
    }

    func testStamped() {
        let msg = RealtimeMessage(
            chatID: "19:x", msgId: "m1", sender: "A",
            text: "t", time: "t", isEdit: false)
        XCTAssertNil(msg.accountID)
        XCTAssertEqual(msg.stamped(accountID: "acct-b").accountID, "acct-b")
        XCTAssertNil(
            msg.stamped(accountID: "acct-b").stamped(accountID: nil).accountID)
    }

    // MARK: - per-profile chat list (no active flip)

    func testChatsForProfile() throws {
        signIn(profile: "acct-b") // tokens ONLY under acct-b
        http.routes["\(FfiLaterB4ChatsTests.csaBase)/teams/users/ME/conversations?view=mychats&pageSize=20"] =
            (200, #"{"conversations":[{"id":"19:b@thread.v2","threadProperties":{"topic":"Bee"},"lastMessage":{"composetime":"t","imdisplayname":"s","content":"p"}}]}"#)
        let r = try CoreReads.chats(limit: 20, profile: "acct-b", ctx: ctx())
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.chats.count, 1)
        XCTAssertEqual(r.chats[0].chatId, "19:b@thread.v2")
        // A profile with no tokens fails even though acct-b is signed in.
        XCTAssertThrowsError(
            try CoreReads.chats(limit: 20, profile: "acct-c", ctx: ctx()))
    }
}

/// gap-g1 switch handoff needs the main actor (UnreadStore).
@MainActor
final class GapG1UnreadTests: XCTestCase {
    func testIngestBackgroundMergesAndBadges() {
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        unread.ingestBackground(["19:x": 2, "19:y": 1])
        XCTAssertEqual(unread.count(for: "19:x"), 2)
        XCTAssertEqual(unread.count(for: "19:y"), 1)
        XCTAssertEqual(unread.total, 3)
        XCTAssertEqual(dock.labels.last, "3")
        // Additive merge, blanks/zeros dropped.
        unread.ingestBackground(["19:x": 1, "  ": 9, "19:z": 0])
        XCTAssertEqual(unread.count(for: "19:x"), 3)
        XCTAssertEqual(unread.total, 4)
        // Empty input writes no dock label.
        let writes = dock.labels.count
        unread.ingestBackground([:])
        unread.ingestBackground(["19:z": 0])
        XCTAssertEqual(dock.labels.count, writes)
        // Opening clears seeded counts like live ones.
        unread.markRead(chatID: "19:x")
        XCTAssertEqual(unread.total, 1)
    }
}
