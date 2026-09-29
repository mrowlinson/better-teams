// ChatListFilterSeedTests.swift — chat list filters after launch: Unread
// seeds from the chat list read horizon, Mentions from the activity
// feed; Muted, Favorites/folders, Hidden and Snoozed read their stores.
// Fixtures are shaped like the chat service payloads with fake content
// and fixture ids only. Stub fetchers; zero network.
import XCTest

@testable import OstMacCore

@MainActor
final class ChatListFilterSeedTests: XCTestCase {
    static let now: UInt64 = 1_760_000_000
    static let csaURL = "https://teams.microsoft.com/api/csa/api/v1/teams/users/ME/conversations?view=mychats&pageSize=20"
    static let feedURL = "https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations/48:notifications/messages?pageSize=50"
    static let ownerOID = "00000000-0000-0000-0000-00000000abcd"
    static let otherMRI = "8:orgid:00000000-0000-0000-0000-00000000beef"
    // Message 1760000100000 ms = 2025-10-09T08:55:00Z.
    static let msgID = "1760000100000"
    static let msgTime = "2025-10-09T08:55:00.000Z"
    static let behind = "1750000000000;1750000000000;1750000000000"
    static let ahead = "1770000000000;1770000000000;1770000000000"

    var store: MemoryTokenStore!
    var http: StubReadFetcher!

    override func setUp() async throws {
        CoreReads.whoamiCacheClearAll()
        store = MemoryTokenStore(now: { Self.now })
        http = StubReadFetcher()
        http.testCase = self
        try store.save(TokenSlots(
            accessToken: StoredTokenValue(token: "FIXTURE-AAD", now: Self.now, expiresIn: 3_600),
            refreshToken: "FIXTURE-RT",
            skypeToken: StoredTokenValue(token: "FIXTURE-SKYPE", now: Self.now, expiresIn: 3_600),
            graphToken: StoredTokenValue(token: "FIXTURE-GRAPH", now: Self.now, expiresIn: 3_600)
        ), profile: "default")
        CoreReads.whoamiCacheStore(profile: "default", value: WhoamiResponse(
            ok: true, id: Self.ownerOID, display_name: "Emma Carter", mail: nil))
    }

    override func tearDown() async throws {
        CoreReads.whoamiCacheClearAll()
    }

    func ctx() -> ReadContext {
        ReadContext(store: store, http: http, refresher: StubGrantFetcher(), now: { Self.now })
    }

    /// One chat-list conversation shaped like the chat service's.
    static func conv(
        _ id: String, topic: String, horizon: String?, from: String,
        type: String = "RichText/Html", alerts: String? = nil
    ) -> String {
        var props: [String] = [#""isemptyconversation":"False""#]
        if let horizon { props.append(#""consumptionhorizon":"\#(horizon)""#) }
        if let alerts { props.append(#""alerts":"\#(alerts)""#) }
        return #"""
        {"id":"\#(id)","threadProperties":{"topic":"\#(topic)","threadType":"chat"},
         "properties":{\#(props.joined(separator: ","))},
         "lastMessage":{"id":"\#(msgID)","composetime":"\#(msgTime)","originalarrivaltime":"\#(msgTime)",
          "content":"<p>Lunch at noon?</p>","messagetype":"\#(type)","imdisplayname":"Liam Brooks",
          "from":"https://amer.ng.msg.teams.microsoft.com/v1/users/ME/contacts/\#(from)"}}
        """#
    }

    // MARK: Unread

    func testHorizonParse() {
        XCTAssertEqual(ChatListSeed.horizon("1;2;3")?.readMs, 1)
        XCTAssertEqual(ChatListSeed.horizon("1;2;1760000000100")?.messageID, 1_760_000_000_100)
        // CHATSYNC: a third field that is not an epoch-ms message id (Teams
        // writes the clientmessageid there) leaves the id axis open.
        XCTAssertEqual(ChatListSeed.horizon("1;2;3")?.messageID, 0)
        XCTAssertEqual(ChatListSeed.horizon("5;0")?.messageID, 0)
        XCTAssertNil(ChatListSeed.horizon(""))
        XCTAssertNil(ChatListSeed.horizon(nil))
    }

    func testUnreadRule() {
        func u(_ h: String?, type: String = "RichText/Html", own: Bool = false) -> Bool? {
            ChatListSeed.isUnread(horizon: h, lastMessageID: Self.msgID, lastMessageTime: Self.msgTime,
                                  messageType: type, fromOwner: own)
        }
        XCTAssertEqual(u(Self.behind), true)
        XCTAssertEqual(u(Self.ahead), false)
        XCTAssertEqual(u(Self.behind, own: true), false, "own last message = read")
        XCTAssertEqual(u(Self.behind, type: "ThreadActivity/AddMember"), false)
        XCTAssertEqual(u(Self.behind, type: "RichText/Media_CallRecording"), true)
        // Read time behind the message but its id already acked: read.
        XCTAssertEqual(u("1750000000000;0;\(Self.msgID)"), false)
        // Id behind but read after the message arrived: read.
        XCTAssertEqual(u("1770000000000;0;1"), false)
        XCTAssertNil(u(nil), "no horizon = unknown")
    }

    func testChatListDecodeCarriesReadState() throws {
        let owner = "8:orgid:\(Self.ownerOID)"
        let body = #"{"conversations":["# + [
            Self.conv("19:fixture-a@thread.v2", topic: "Design Review", horizon: Self.behind, from: Self.otherMRI),
            Self.conv("19:fixture-b@thread.v2", topic: "Weekly Sync", horizon: Self.ahead, from: Self.otherMRI, alerts: "false"),
            Self.conv("19:fixture-c@thread.v2", topic: "Offsite", horizon: Self.behind, from: owner),
            Self.conv("19:fixture-d@thread.v2", topic: "Hiring", horizon: nil, from: Self.otherMRI),
        ].joined(separator: ",") + "]}"
        http.routes[Self.csaURL] = (200, body)
        let r = try CoreReads.chats(limit: 20, profile: "default", ctx: ctx())
        let byID = Dictionary(uniqueKeysWithValues: r.chats.map { ($0.id, $0) })
        XCTAssertEqual(byID["19:fixture-a@thread.v2"]?.unread, true)
        XCTAssertEqual(byID["19:fixture-b@thread.v2"]?.unread, false)
        XCTAssertEqual(byID["19:fixture-b@thread.v2"]?.muted, true, "Muted filter source")
        XCTAssertEqual(byID["19:fixture-c@thread.v2"]?.unread, false)
        XCTAssertNil(byID["19:fixture-d@thread.v2"]?.unread)
        XCTAssertEqual(byID["19:fixture-a@thread.v2"]?.read_horizon, Self.behind)
        XCTAssertEqual(http.calls.count, 1, "owner came from the whoami cache")
    }

    func testUnreadStoreSeed() {
        let dock = FakeDockBadge()
        let s = UnreadStore(dock: dock)
        let at = ChatListFormat.parse(Self.msgTime)
        s.ingest(decision: .notify(reason: "t"), chatID: "live", openChatID: nil)
        s.markUnread(chatID: "manual")
        s.seed([
            UnreadSeed(chatID: "a", unread: true, lastMessageAt: at),
            UnreadSeed(chatID: "m", unread: true, lastMessageAt: at, muted: true),
            UnreadSeed(chatID: "live", unread: false, lastMessageAt: at),
            UnreadSeed(chatID: "manual", unread: false, lastMessageAt: at),
        ])
        XCTAssertTrue(s.isUnread(chatID: "a"))
        XCTAssertTrue(s.isUnread(chatID: "m"), "muted chats still list as unread")
        XCTAssertTrue(s.isUnread(chatID: "live"), "live counts survive a read seed")
        XCTAssertTrue(s.isUnread(chatID: "manual"), "mark-unread survives a read seed")
        XCTAssertEqual(s.total, 3, "muted seed stays out of the dock")
        // Same seed again: no publish, no dock write.
        let writes = dock.labels.count
        s.seed([UnreadSeed(chatID: "a", unread: true, lastMessageAt: at)])
        XCTAssertEqual(dock.labels.count, writes)
        // Teams now says read: the seeded count clears.
        s.seed([UnreadSeed(chatID: "a", unread: false, lastMessageAt: at)])
        XCTAssertFalse(s.isUnread(chatID: "a"))
        // Opened here after the message: a stale seed does not re-mark it.
        s.markRead(chatID: "m")
        s.seed([UnreadSeed(chatID: "m", unread: true, lastMessageAt: at)])
        XCTAssertFalse(s.isUnread(chatID: "m"))
    }

    // MARK: Mentions

    static let feed = #"""
    {"messages":[
     {"id":"1","properties":{"isread":"false","activity":{"activityType":"mentionInChat","activitySubtype":"person",
       "sourceThreadId":"19:fixture-a@thread.v2","sourceMessageId":"1760000100000","sourceUserImDisplayName":"Liam Brooks"}}},
     {"id":"2","properties":{"isread":"true","activity":"{\"activityType\":\"mentionInChat\",\"activitySubtype\":\"everyone\",\"sourceThreadId\":\"19:fixture-b@thread.v2\",\"sourceMessageId\":\"1760000100000\"}"}},
     {"id":"3","properties":{"isread":"true","activity":{"activityType":"mentionInChat","activitySubtype":"person",
       "sourceThreadId":"19:fixture-c@thread.v2","sourceMessageId":1760000100000}}},
     {"id":"4","properties":{"isread":"false","activity":{"activityType":"reactionInChat",
       "sourceThreadId":"19:fixture-d@thread.v2","sourceMessageId":"1760000100000"}}},
     {"id":"5","properties":{"isread":"false","activity":{"activityType":"mention","activitySubtype":"team",
       "sourceThreadId":"19:fixture-e@thread.tacv2","sourceMessageId":"1760000100000"}}}
    ]}
    """#

    func testMentionActivityReadAndParse() throws {
        http.routes[Self.feedURL] = (200, Self.feed)
        let acts = try CoreReads.mentionActivity(profile: "default", ctx: ctx())
        XCTAssertEqual(acts.map(\.chatID), ["19:fixture-a@thread.v2", "19:fixture-b@thread.v2", "19:fixture-c@thread.v2"])
        XCTAssertEqual(acts.map(\.isRead), [false, true, true])
        XCTAssertEqual(acts.map(\.everyone), [false, true, false])
        XCTAssertEqual(acts[2].messageID, 1_760_000_100_000)
        XCTAssertEqual(http.calls.first?.headers["Authentication"], "skypetoken=FIXTURE-SKYPE")
        XCTAssertTrue(ChatListSeed.parseMentionActivity(Data("nope".utf8)).isEmpty)
    }

    func testMentionedChatsRule() {
        let acts = ChatListSeed.parseMentionActivity(Data(Self.feed.utf8))
        let flagged = ChatListSeed.mentionedChats(acts, horizons: [
            "19:fixture-a@thread.v2": Self.ahead, // feed-unread wins
            "19:fixture-b@thread.v2": Self.behind, // feed-read but past the horizon
            "19:fixture-c@thread.v2": Self.ahead, // read everywhere
        ])
        XCTAssertEqual(Set(flagged.keys), ["19:fixture-a@thread.v2", "19:fixture-b@thread.v2"])
        // Unknown horizon: the feed flag alone decides.
        XCTAssertEqual(Set(ChatListSeed.mentionedChats(acts, horizons: [:]).keys), ["19:fixture-a@thread.v2"])
    }

    func testMentionStoreSeed() {
        let dock = FakeDockBadge()
        let s = MentionStore(dock: dock)
        let at = Date(timeIntervalSince1970: 1_760_000_100)
        s.seed(["a": at, "b": at])
        XCTAssertEqual(s.mentionedIDs, ["a", "b"])
        XCTAssertEqual(dock.labels.last, "2")
        let writes = dock.labels.count
        s.seed(["a": at, "b": at])
        XCTAssertEqual(dock.labels.count, writes, "no change, no write")
        // Live flag survives a seed that omits it; seeded "b" clears.
        s.ingest(realtime: msg(chatID: "live", raw: #"<at id="0">Emma Carter</at> ping"#),
                 ownName: "Emma Carter", ownerMRI: nil, openChatID: nil)
        s.seed(["a": at])
        XCTAssertEqual(s.mentionedIDs, ["a", "live"])
        // Opened here after the mention: no re-flag.
        s.markRead(chatID: "a")
        s.seed(["a": at])
        XCTAssertFalse(s.contains(chatID: "a"))
    }

    func testLiveEveryoneFlagsChatsNotChannels() {
        let s = MentionStore(dock: FakeDockBadge())
        let raw = #"<at id="0">everyone</at> standup moved"#
        s.ingest(realtime: msg(chatID: "19:fixture-g@thread.v2", raw: raw), ownName: "Emma Carter", ownerMRI: nil, openChatID: nil)
        s.ingest(realtime: msg(chatID: "19:fixture-h@thread.tacv2", raw: raw), ownName: "Emma Carter", ownerMRI: nil, openChatID: nil)
        XCTAssertEqual(s.mentionedIDs, ["19:fixture-g@thread.v2"])
    }

    func msg(chatID: String, raw: String) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: "m1", sender: "Liam Brooks", text: "hi",
            time: Self.msgTime, isEdit: false, raw: raw, messageType: "RichText/Html")
    }

    // MARK: Muted / folders / hidden / snoozed (store reads)

    func testFolderFilterSource() {
        let d = UserDefaults(suiteName: "ChatListFilterSeedTests-\(UUID().uuidString)")!
        let f = FolderStore(defaults: d, accountID: "fixture")
        f.applyServer([ServerChatFolder(id: "fav", name: "Favorites", folder_type: "Favorites",
                                        item_ids: ["19:fixture-a@thread.v2", "19:fixture-z@thread.v2"])])
        XCTAssertEqual(f.folderID(for: ChatItem(chatId: "19:fixture-a@thread.v2", name: "Design Review")), "fav")
        XCTAssertNil(f.folderID(for: ChatItem(chatId: "19:fixture-b@thread.v2", name: "Weekly Sync")))
    }

    func testHiddenFilterSource() {
        let path = NSTemporaryDirectory() + "ChatListFilterSeedTests-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = RulesStore(path: path)
        r.setHidden(chatID: "19:fixture-a@thread.v2", hidden: true)
        XCTAssertTrue(r.isHidden(chatID: "19:fixture-a@thread.v2"))
        XCTAssertFalse(r.isHidden(chatID: "19:fixture-b@thread.v2"))
    }

    func testSnoozeFilterSource() {
        let d = UserDefaults(suiteName: "ChatListFilterSeedTests-\(UUID().uuidString)")!
        let s = SnoozeStore(defaults: d)
        s.snooze(chatID: "19:fixture-a@thread.v2", until: Date().addingTimeInterval(3_600))
        XCTAssertTrue(s.isSnoozed(chatID: "19:fixture-a@thread.v2"))
        XCTAssertFalse(s.isSnoozed(chatID: "19:fixture-b@thread.v2"))
    }
}
