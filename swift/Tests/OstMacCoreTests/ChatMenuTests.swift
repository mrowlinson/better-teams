// ChatMenuTests.swift — chatmenu lane: which conversations reach the
// chat list, mute/hide sync with rollback, Teams folders, demo seed.
// Fixture ids and props only; zero network.
import XCTest

@testable import OstMacCore

// MARK: - chat list filter through the list read

extension FfiLaterB4ChatsTests {
    /// One conversation per kind the chat service returns for
    /// `view=mychats`; only chats Teams shows under Chat survive.
    func testChatListKeepsOnlyTeamsChatKinds() throws {
        signIn()
        let convs = [
            // Shown: 1:1, group (muted), meeting with a recording.
            #"{"id":"19:a_b@unq.gbl.spaces","threadProperties":{"threadType":"chat","productThreadType":"OneToOneChat","topic":"One"},"lastMessage":{"content":"x"}}"#,
            #"{"id":"19:g@thread.v2","threadProperties":{"threadType":"chat","productThreadType":"Chat","topic":"Group"},"properties":{"alerts":"false"},"lastMessage":{"content":"x"}}"#,
            #"{"id":"19:meeting_r@thread.v2","threadProperties":{"threadType":"meeting","productThreadType":"Meeting","topic":"Meet"},"lastMessage":{"messagetype":"RichText/Media_CallRecording"}}"#,
            // Hidden: empty meeting and empty group (string and bool flag).
            #"{"id":"19:meeting_e@thread.v2","threadProperties":{"threadType":"meeting","productThreadType":"Meeting","topic":"M"},"properties":{"isemptyconversation":"True"}}"#,
            #"{"id":"19:e@thread.v2","threadProperties":{"threadType":"chat","topic":"E"},"properties":{"isemptyconversation":true}}"#,
            // Hidden: system streams.
            #"{"id":"48:mentions","threadProperties":{"threadType":"streamofmentions"}}"#,
            #"{"id":"48:notifications","threadProperties":{"threadType":"streamofnotifications"}}"#,
            #"{"id":"48:calllogs","threadProperties":{"threadType":"streamofcalllogs"}}"#,
            // Shown: the chat with yourself, even with no messages.
            #"{"id":"48:notes","threadProperties":{"threadType":"streamofnotes"},"properties":{"isemptyconversation":"True"}}"#,
            // Hidden: team and channel threads.
            #"{"id":"19:t@thread.skype","threadProperties":{"threadType":"space","productThreadType":"TeamsTeam","topic":"T"},"properties":{"favorite":true}}"#,
            #"{"id":"19:c@thread.tacv2","threadProperties":{"threadType":"topic","productThreadType":"TeamsStandardChannel","topic":"C"}}"#,
            // Hidden: hidden, left.
            #"{"id":"19:h@thread.v2","threadProperties":{"threadType":"chat","topic":"H","hidden":"true"}}"#,
            #"{"id":"19:l@thread.v2","threadProperties":{"threadType":"chat","topic":"L","lastjoinat":"100","lastleaveat":"200"}}"#,
            // Shown: left then rejoined; an odd-shaped flag never fails the list.
            #"{"id":"19:rj@thread.v2","threadProperties":{"threadType":"chat","topic":"Back","lastjoinat":300,"lastleaveat":"200"},"lastMessage":{"content":"x"}}"#,
            #"{"id":"19:o@thread.v2","threadProperties":{"threadType":"chat","topic":"Odd","hidden":{"x":1}},"lastMessage":{"content":"x"}}"#,
        ]
        http.routes[csaURL()] = (200, #"{"conversations":["# + convs.joined(separator: ",") + "]}")
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"OID-SELF","displayName":"Self"}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(r.chats.map(\.chatId), [
            "19:a_b@unq.gbl.spaces", "19:g@thread.v2", "19:meeting_r@thread.v2",
            "48:notes", "19:rj@thread.v2", "19:o@thread.v2",
        ])
        XCTAssertEqual(r.chats.first { $0.chatId == "48:notes" }?.name, "Self (You)")
        XCTAssertEqual(r.chats.first { $0.chatId == "19:g@thread.v2" }?.muted, true)
        XCTAssertNil(r.chats.first { $0.chatId == "19:a_b@unq.gbl.spaces" }?.muted)
    }
}

// MARK: - pure rule, stores, demo

@MainActor
final class ChatMenuTests: XCTestCase {
    private func excl(_ id: String, type: String? = nil, product: String? = nil, hidden: String? = nil,
                      join: String? = nil, leave: String? = nil, empty: String? = nil) -> ChatListFilter.Exclusion? {
        ChatListFilter.exclusion(id: id, threadType: type, productThreadType: product, hidden: hidden,
                                 lastJoinAt: join, lastLeaveAt: leave, isEmpty: empty)
    }

    func testExclusionPerKind() {
        XCTAssertNil(excl("19:a_b@unq.gbl.spaces", type: "chat", product: "OneToOneChat"))
        XCTAssertNil(excl("19:g@thread.v2", type: "chat", product: "Chat"))
        XCTAssertNil(excl("19:meeting_x@thread.v2", type: "meeting", product: "Meeting"))
        XCTAssertNil(excl("48:notes", type: "streamofnotes", empty: "True"))
        XCTAssertNil(excl("19:g@thread.v2"), "no props = shown (older payloads)")
        XCTAssertEqual(excl("48:calllogs"), .systemStream)
        XCTAssertEqual(excl("19:x@thread.v2", type: "streamofmentions"), .systemStream)
        XCTAssertEqual(excl("19:t@thread.skype", type: "space", product: "TeamsTeam"), .channel)
        XCTAssertEqual(excl("19:c@thread.tacv2"), .channel)
        XCTAssertEqual(excl("19:p@thread.v2", product: "TeamsPrivateChannel"), .channel)
        XCTAssertEqual(excl("19:h@thread.v2", hidden: "True"), .hidden)
        XCTAssertEqual(excl("19:l@thread.v2", leave: "5"), .left)
        XCTAssertEqual(excl("19:l@thread.v2", join: "1", leave: "5"), .left)
        XCTAssertNil(excl("19:l@thread.v2", join: "9", leave: "5"))
        XCTAssertEqual(excl("19:meeting_e@thread.v2", type: "meeting", empty: "True"), .empty)
        XCTAssertNil(excl("19:meeting_e@thread.v2", type: "meeting", empty: "False"))
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    private struct Refused: Error {}

    private func store(_ calls: Calls, fail: Bool) -> RulesStore {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chatmenu-\(UUID().uuidString).json").path
        let s = RulesStore(path: path)
        s.remote = ChatRemoteSync(
            setMuted: { id, on in calls.add("mute \(id) \(on)"); if fail { throw Refused() } },
            setHidden: { id, on in calls.add("hide \(id) \(on)"); if fail { throw Refused() } })
        return s
    }

    func testMuteAndHideSyncAndStay() async {
        let calls = Calls()
        let s = store(calls, fail: false)
        await s.setLevel(chatID: "19:g@thread.v2", level: .muted)?.value
        await s.setHidden(chatID: "19:g@thread.v2", hidden: true)?.value
        XCTAssertEqual(calls.all, ["mute 19:g@thread.v2 true", "hide 19:g@thread.v2 true"])
        XCTAssertEqual(s.level(chatID: "19:g@thread.v2"), .muted)
        XCTAssertTrue(s.isHidden(chatID: "19:g@thread.v2"))
        XCTAssertNil(s.syncError)
    }

    func testRefusedWritesRollBackWithQuietError() async {
        let calls = Calls()
        let s = store(calls, fail: true)
        await s.setLevel(chatID: "19:g@thread.v2", level: .muted)?.value
        XCTAssertEqual(s.level(chatID: "19:g@thread.v2"), .all)
        XCTAssertNotNil(s.syncError)
        await s.setHidden(chatID: "19:g@thread.v2", hidden: true)?.value
        XCTAssertFalse(s.isHidden(chatID: "19:g@thread.v2"))
        s.clearSyncError()
        XCTAssertNil(s.syncError)
    }

    func testChannelsStayLocal() {
        let calls = Calls()
        let s = store(calls, fail: true)
        XCTAssertNil(s.setHidden(chatID: "19:c@thread.tacv2", hidden: true))
        XCTAssertTrue(s.isHidden(chatID: "19:c@thread.tacv2"))
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testAdoptServerMutes() {
        let s = store(Calls(), fail: false)
        s.adoptServerMutes([
            ChatItem(chatId: "19:a@thread.v2", name: "A", muted: true),
            ChatItem(chatId: "19:b@thread.v2", name: "B", muted: nil),
        ])
        XCTAssertEqual(s.level(chatID: "19:a@thread.v2"), .muted)
        XCTAssertEqual(s.level(chatID: "19:b@thread.v2"), .all)
        s.adoptServerMutes([ChatItem(chatId: "19:a@thread.v2", name: "A", muted: false)])
        XCTAssertEqual(s.level(chatID: "19:a@thread.v2"), .all)
    }

    private func folders() -> FolderStore {
        FolderStore(defaults: UserDefaults(suiteName: "chatmenu-\(UUID().uuidString)") ?? .standard)
    }

    func testServerFoldersFavoritesAndPrecedence() {
        let f = folders()
        f.applyServer([
            ServerChatFolder(id: "fav", name: "Favorites", folder_type: "Favorites", item_ids: ["c1", "c2"]),
            ServerChatFolder(id: "u1", name: "Work", item_ids: ["c2", "c3"]),
        ])
        XCTAssertEqual(f.favoriteIDs, ["c1", "c2"])
        XCTAssertEqual(f.serverAssignments["c2"], "fav", "first folder listing a chat wins")
        XCTAssertEqual(f.allFolders.map(\.id).prefix(2), ["fav", "u1"])
        XCTAssertTrue(f.isServerFolder("u1"))
        let mine = f.createFolder(name: "Mine")!
        f.assign(chatID: "c3", folderID: mine.id)
        XCTAssertEqual(f.folderID(for: ChatItem(chatId: "c3", name: "c")), mine.id, "a move here wins")
        XCTAssertEqual(f.folderID(for: ChatItem(chatId: "c1", name: "c")), "fav")
        f.applyServer([])
        XCTAssertTrue(f.favoriteIDs.isEmpty)
    }

    func testDemoFolderSeedIsIdempotent() {
        let f = folders()
        DemoData.seedFolders(f)
        DemoData.seedFolders(f)
        XCTAssertEqual(f.favoriteIDs, ["demo-2", DemoData.tomID])
        XCTAssertEqual(f.folders.filter { $0.name == "Projects" }.count, 1)
        let projects = f.folders.first { $0.name == "Projects" }!.id
        XCTAssertEqual(f.overrides["demo-3"], projects)
    }
}
