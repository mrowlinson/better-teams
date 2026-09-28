// CoreAChatGapsTests.swift — core-a: channel thread replies, chat
// roster (+ id-based owners), group chat create, who-reacted, missed-call
// caller id. Pure seams + demo/fake fetchers + FFI arg rejection (no
// network, no real user data).
import XCTest

@testable import OstMacCore

@MainActor
final class CoreAChatGapsTests: XCTestCase {

    // MARK: - 1. Thread replies

    func testChannelReplyRoutesIntoRootThread() {
        let root = ChatMessage(id: "1700", sender: "Ava", timestamp: "", content: "root")
        let reply = ChatMessage(
            id: "1701", sender: "Tom", timestamp: "", content: "r", reply_to: "1700")
        let ch = "19:c@thread.tacv2"
        XCTAssertEqual(ConversationStore.replyRoute(chatID: ch, parent: root), .thread(rootID: "1700"))
        // Replying to a reply stays in the same chain (root, not the reply).
        XCTAssertEqual(ConversationStore.replyRoute(chatID: ch, parent: reply), .thread(rootID: "1700"))
        XCTAssertEqual(
            ConversationStore.replyRoute(chatID: "19:c@thread.skype", parent: root), .thread(rootID: "1700"))
        XCTAssertEqual(
            ConversationStore.replyRoute(chatID: "demo-chan-shipping", parent: reply), .thread(rootID: "1700"))
        // Chats keep quote replies to the bubble itself.
        XCTAssertEqual(
            ConversationStore.replyRoute(chatID: "19:g@thread.v2", parent: reply), .quote(parentID: "1701"))
        XCTAssertEqual(
            ConversationStore.replyRoute(chatID: "19:a_b@unq.gbl.spaces", parent: root), .quote(parentID: "1700"))
        XCTAssertEqual(ConversationStore.replyRoute(chatID: nil, parent: root), .quote(parentID: "1700"))
    }

    func testDemoChannelReplyBubbleLinksRoot() {
        let conv = ConversationStore()
        let root = ChatMessage(id: "r1", sender: "Ava", timestamp: "", content: "root")
        let child = ChatMessage(id: "c1", sender: "Tom", timestamp: "", content: "c", reply_to: "r1")
        conv.showDemo(chatID: "demo-chan-shipping", chatName: "Shipping", messages: [root, child], failed: [])
        conv.beginReply(to: child)
        conv.send(text: "on it")
        XCTAssertEqual(conv.messages.last?.reply_to, "r1")
    }

    func testThreadReplyFFIRejectsBadArgsWithoutNetwork() {
        XCTAssertThrowsError(try RustCore.threadReply(channelID: "19:g@thread.v2", rootID: "1", text: "x"))
        XCTAssertThrowsError(try RustCore.threadReply(channelID: "19:c@thread.tacv2", rootID: "", text: "x"))
        XCTAssertThrowsError(try RustCore.threadReply(channelID: "19:c@thread.tacv2", rootID: "1", text: " "))
    }

    // MARK: - 2. Chat roster

    func testRosterDecodeAndOwnerIsIDBased() throws {
        let json = Data("""
        {"ok":true,"chat_id":"19:g@thread.v2","source":"chatsvc","members":[
          {"mri":"8:orgid:aad-1","user_id":"aad-1","display_name":"","email":null,"roles":["admin"],"is_owner":true},
          {"mri":"8:orgid:aad-2","user_id":null,"display_name":"Tom","roles":["user"],"is_owner":false}
        ]}
        """.utf8)
        let resp = try JSONDecoder().decode(ChatMembersResponse.self, from: json)
        XCTAssertEqual(resp.source, "chatsvc")
        XCTAssertEqual(resp.members.count, 2)
        XCTAssertEqual(resp.members[1].presenceID, "aad-2") // MRI → object id
        XCTAssertTrue(RosterOwnership.isOwner(resp.members, ownUserID: "AAD-1"))
        XCTAssertTrue(RosterOwnership.isOwner(resp.members, ownUserID: "8:orgid:aad-1"))
        XCTAssertFalse(RosterOwnership.isOwner(resp.members, ownUserID: "aad-2"))
        XCTAssertFalse(RosterOwnership.isOwner(resp.members, ownUserID: nil))
        // Team roster: same id rule, display names never match.
        let team = [
            TeamMember(id: "m1", displayName: "Me", userId: "u-other", isOwner: true),
            TeamMember(id: "m2", displayName: "Alex", userId: "u-me", isOwner: false),
        ]
        XCTAssertFalse(RosterOwnership.isOwner(team, ownUserID: "u-me"))
        XCTAssertTrue(RosterOwnership.isOwner(team, ownUserID: "u-other"))
    }

    func testRosterStoreLoadsViaFetcherAndSortsOwnersFirst() async {
        let store = ChatRosterStore(fetcher: { id in
            ChatMembersResponse(ok: true, chatId: id, source: "graph", members: [
                ChatMember(mri: "8:orgid:b", userId: "b", displayName: "Zed"),
                ChatMember(mri: "8:orgid:a", userId: "a", displayName: "Ava", roles: ["owner"], isOwner: true),
                ChatMember(mri: "8:orgid:c", userId: "c", displayName: "Bea"),
            ])
        })
        XCTAssertNil(store.peopleCount)
        await store.load(chatID: "19:g@thread.v2")
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.peopleCount, 3)
        XCTAssertEqual(store.members.map(\.displayName), ["Ava", "Bea", "Zed"])
        XCTAssertEqual(store.displayName(forID: "8:orgid:c"), "Bea")
        XCTAssertEqual(store.displayName(forID: "B"), "Zed")
        XCTAssertTrue(store.isOwner(ownUserID: "a"))
        XCTAssertEqual(store.presenceIDs, ["a", "c", "b"])
    }

    func testRosterStoreErrorAndDemoPresence() async {
        struct Boom: Error {}
        let failing = ChatRosterStore(fetcher: { _ in throw Boom() })
        await failing.load(chatID: "19:g@thread.v2")
        if case .error = failing.state {} else { XCTFail("expected error state") }
        XCTAssertNil(failing.peopleCount)

        let demo = ChatRosterStore(demo: true)
        await demo.load(chatID: DemoData.standupID)
        XCTAssertEqual(demo.peopleCount, 4)
        XCTAssertTrue(demo.isOwner(ownUserID: "demo-u-me"))
        await demo.load(chatID: DemoData.avaID)
        XCTAssertEqual(demo.members.map(\.displayName).sorted(), ["Ava Lindqvist", "Me"])
        let presence = PresenceStore(
            ownFetcher: { throw Boom() }, setFetcher: { _ in throw Boom() },
            userFetcher: { _ in throw Boom() }, resolveFetcher: { _ in throw Boom() })
        await demo.refreshPresence(into: presence)
        XCTAssertEqual(presence.peers["demo-u-ava"]?.availability, "Busy")
    }

    func testChatMembersFFIRejectsBlankID() {
        XCTAssertThrowsError(try RustCore.chatMembers(chatID: "  "))
    }

    // MARK: - 3. Group chat create

    func testGroupRefsTopicAndName() {
        let people = [
            TeamMember(id: "1", displayName: "Ava Lindqvist", userId: "u-ava"),
            TeamMember(id: "2", displayName: "Tom Becker", email: "tom@example.com"),
            TeamMember(id: "3", displayName: "Ava Again", userId: "U-AVA"),
            TeamMember(id: "4", displayName: "No Ref"),
        ]
        XCTAssertEqual(GroupChat.userRefs(for: people), ["u-ava", "tom@example.com"])
        XCTAssertNil(GroupChat.cleanTopic("   "))
        XCTAssertEqual(GroupChat.cleanTopic("  Launch "), "Launch")
        XCTAssertEqual(GroupChat.cleanTopic(String(repeating: "x", count: 400))?.count, GroupChat.maxTopic)
        XCTAssertEqual(GroupChat.defaultName(for: Array(people.prefix(2))), "Ava and Tom")
        XCTAssertEqual(
            GroupChat.demoChatID(refs: ["B", "a"], topic: nil),
            GroupChat.demoChatID(refs: ["a", "b"], topic: nil))
        XCTAssertTrue(DemoData.isDemoID(GroupChat.demoChatID(refs: ["a"], topic: "T")))
    }

    func testGroupCreateFFIRejectsEmptyMembersWithoutNetwork() {
        XCTAssertThrowsError(try RustCore.chatCreateGroup(users: [], topic: "T"))
        XCTAssertThrowsError(try RustCore.chatCreateGroup(users: ["  "], topic: nil))
    }

    // MARK: - 4. Who reacted

    func testReactorsDecodeOptionalAndResolveNames() throws {
        let old = try JSONDecoder().decode(ReactionCount.self, from: Data(#"{"emoji":"👍","count":2}"#.utf8))
        XCTAssertEqual(old.reactors, [])
        let new = try JSONDecoder().decode(ReactionCount.self, from: Data("""
        {"emoji":"👍","count":3,"reactors":[
          {"id":"8:orgid:a","name":""},{"id":"aad-b","name":"Bea"},{"id":"8:orgid:z","name":""}]}
        """.utf8))
        XCTAssertEqual(new.reactors.count, 3)
        let roster = ["8:orgid:a": "Ava"]
        XCTAssertEqual(new.reactorNames(resolve: { roster[$0] }), ["Ava", "Bea"])
        // Local toggles keep the server's reactor list.
        let bumped = ConversationStore.withReactionAdded([new], emoji: "👍")
        XCTAssertEqual(bumped[0].count, 4)
        XCTAssertEqual(bumped[0].reactors, new.reactors)
    }

    // MARK: - 5. Missed-call caller id

    private let missedRaw = """
    <partlist type="missed" alt=""><part identity="8:orgid:caller-1"><name>Doe, Jane</name></part></partlist>
    """

    func testCallEventPayloadParse() {
        XCTAssertTrue(CallEventPayload.isCallEvent("Event/Call"))
        XCTAssertFalse(CallEventPayload.isCallEvent("RichText/Html"))
        XCTAssertEqual(CallEventPayload.partlistType(missedRaw), "missed")
        let caller = CallEventPayload.missedCaller(raw: missedRaw, senderID: nil, ownerMRI: "8:orgid:me")
        XCTAssertEqual(caller, .init(identity: "8:orgid:caller-1", name: "Doe, Jane"))
        // Ended calls are not missed; owner-only parts fall back to sender.
        XCTAssertNil(CallEventPayload.missedCaller(
            raw: missedRaw.replacingOccurrences(of: "missed", with: "ended"), senderID: nil, ownerMRI: nil))
        let ownOnly = #"<partlist type='missed'><part identity='8:orgid:me'><name>Me</name></part></partlist>"#
        XCTAssertEqual(
            CallEventPayload.missedCaller(raw: ownOnly, senderID: "8:orgid:s", ownerMRI: "8:orgid:ME")?.identity,
            "8:orgid:s")
        XCTAssertNil(CallEventPayload.missedCaller(raw: ownOnly, senderID: "Jane", ownerMRI: "8:orgid:me"))
    }

    func testMissedCallEventPopulatesCallerIDAndDedups() {
        let suite = "test-core-a-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = ActivityStore(defaults: defaults)
        let msg = RealtimeMessage(
            chatID: "19:a_b@unq.gbl.spaces", msgId: "ev-1", sender: "Doe, Jane",
            senderID: "8:orgid:caller-1", text: "", time: "", isEdit: false,
            raw: missedRaw, messageType: "Event/Call")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        // Open chat does not suppress a missed call.
        s.ingest(realtime: msg, ownName: "Smith, Alex", ownerMRI: "8:orgid:me",
                 openChatID: msg.chatID, chatName: "", at: at)
        XCTAssertEqual(s.items.count, 1)
        XCTAssertEqual(s.items[0].kind, .missedCall)
        XCTAssertEqual(s.items[0].callerID, "8:orgid:caller-1")
        XCTAssertEqual(s.items[0].actor, "Doe, Jane")
        XCTAssertNil(s.items[0].messageID)
        // The live-call record of the same call does not double-list.
        s.noteCallRecord(CallRecord(
            id: "call-1", direction: .missed, peer: "8:orgid:CALLER-1", peerName: "Doe, Jane",
            thread: "", startedAt: 1_800_000_060, endedAt: 1_800_000_070), chatName: "")
        XCTAssertEqual(s.items.count, 1)
        // Own outgoing call events never list.
        let own = RealtimeMessage(
            chatID: "19:x", msgId: "ev-2", sender: "Smith, Alex", senderID: "8:orgid:me",
            text: "", time: "", isEdit: false, raw: missedRaw, messageType: "Event/Call")
        s.ingest(realtime: own, ownName: "Smith, Alex", ownerMRI: "8:orgid:me",
                 openChatID: nil, chatName: "", at: at)
        XCTAssertEqual(s.items.count, 1)
    }
}
