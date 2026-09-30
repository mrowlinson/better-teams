// ChatSyncTests.swift — CHATSYNC S1–S5 with fake transports: Teams read
// position on view (never for prefetch), Mark as read/unread both ways,
// Delete chat, unread seeds from Teams bookmarks/horizons, 1:1 names
// when the mate never wrote, and a source guard that only the on-screen
// timeline reports views.
import Foundation
import XCTest
@testable import OstMacCore

/// Records every conversation-property write (chat, name, value).
final class FakePropertyWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var _puts: [(chat: String, name: String, value: Any)] = []
    var fail = false

    var puts: [(chat: String, name: String, value: Any)] { lock.lock(); defer { lock.unlock() }; return _puts }

    var writer: ReadSync.Writer {
        { [self] chat, name, body in
            if fail { throw CoreCallError.failed("read_state: \(name) HTTP 500") }
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            lock.lock(); _puts.append((chat, name, obj?[name] ?? NSNull())); lock.unlock()
        }
    }
}

@MainActor
final class ChatSyncTests: XCTestCase {
    let chat = "19:a_b@unq.gbl.spaces"
    let open = ReadViewGate(isOpen: true, windowActive: true, atLatest: true, loaded: true)

    func msg(_ id: String, cid: String? = nil) -> ChatMessage {
        ChatMessage(id: id, sender: "Emma Clark", timestamp: "", content: "hi", clientMessageID: cid)
    }

    func sync(_ w: FakePropertyWriter) -> ReadSync { ReadSync(writer: w.writer, now: { 1_760_000_000_999 }) }

    // S3a: one view → exactly one horizon write at the newest message,
    // in the Teams format "<arrival>;<now>;<clientMessageId>".
    func testViewSendsExactlyOneHorizonAtNewestMessage() async {
        let w = FakePropertyWriter(), s = sync(w)
        let msgs = [msg("1760000000100", cid: "11"), msg("1760000000300", cid: "33"),
                    msg("1760000000200", cid: "22"), msg("local-9f2")] // pending send: no server id
        await s.viewed(chatID: chat, messages: msgs, gate: open)?.value
        XCTAssertEqual(w.puts.count, 1)
        XCTAssertEqual(w.puts.first?.name, "consumptionhorizon")
        XCTAssertEqual(w.puts.first?.value as? String, "1760000000300;1760000000999;33")
        // Same tail again: nothing. A newer message: one more.
        await s.viewed(chatID: chat, messages: msgs, gate: open)?.value
        XCTAssertEqual(w.puts.count, 1)
        await s.viewed(chatID: chat, messages: msgs + [msg("1760000000400")], gate: open)?.value
        XCTAssertEqual(w.puts.count, 2)
        XCTAssertEqual(w.puts.last?.value as? String, "1760000000400;1760000000999;0")
    }

    // S5 guard: background prefetch / hidden / scrolled-up / half-loaded
    // timelines never move the read position.
    func testPrefetchAndHiddenTimelinesSendNothing() async {
        let w = FakePropertyWriter(), s = sync(w)
        let msgs = [msg("1760000000100")]
        for g in [ReadViewGate(isOpen: false, windowActive: true, atLatest: true, loaded: true),   // prefetch / not on screen
                  ReadViewGate(isOpen: true, windowActive: false, atLatest: true, loaded: true),   // window not active
                  ReadViewGate(isOpen: true, windowActive: true, atLatest: false, loaded: true),   // scrolled up
                  ReadViewGate(isOpen: true, windowActive: true, atLatest: true, loaded: false)] { // loading
            XCTAssertNil(s.viewed(chatID: chat, messages: msgs, gate: g))
        }
        XCTAssertEqual(w.puts.count, 0)
    }

    func testReadElsewhereAndGhostSendNothing() async {
        let w = FakePropertyWriter(), s = sync(w)
        s.adopt(horizons: [chat: "1760000000100;1760000000500;4581237865384574321"], markedUnread: [], listed: [chat])
        XCTAssertNil(s.viewed(chatID: chat, messages: [msg("1760000000100")], gate: open))
        let ghost = GhostStore(defaults: MemoryDefaults())
        ghost.master = true
        ghost.suppressReceipts = true
        s.ghost = ghost
        XCTAssertNil(s.viewed(chatID: chat, messages: [msg("1760000000200")], gate: open))
        XCTAssertEqual(w.puts.count, 0)
    }

    func testFailedViewStaysRetryable() async {
        let w = FakePropertyWriter(), s = sync(w)
        w.fail = true
        await s.viewed(chatID: chat, messages: [msg("1760000000100")], gate: open)?.value
        XCTAssertNotNil(s.lastError)
        w.fail = false
        await s.viewed(chatID: chat, messages: [msg("1760000000100")], gate: open)?.value
        XCTAssertEqual(w.puts.count, 1)
    }

    // S3c: Mark as unread = Teams bookmark just behind the newest message;
    // the next view clears it with the horizon; Mark as read = both.
    func testMarkUnreadThenViewAndMarkRead() async throws {
        let w = FakePropertyWriter(), s = sync(w)
        try await s.markUnread(chatID: chat, lastMessageMs: 1_760_000_000_300)
        XCTAssertEqual(w.puts.map(\.name), ["consumptionHorizonBookmark"])
        XCTAssertEqual(w.puts[0].value as? String, "1760000000299;1760000000999;0")
        await s.viewed(chatID: chat, messages: [msg("1760000000300")], gate: open)?.value
        XCTAssertEqual(w.puts.map(\.name), ["consumptionHorizonBookmark", "consumptionhorizon", "consumptionHorizonBookmark"])
        XCTAssertEqual(w.puts[2].value as? String, "0;1760000000999;0")
        try await s.markRead(chatID: chat, lastMessageMs: 1_760_000_000_500)
        XCTAssertEqual(w.puts.suffix(2).map(\.name), ["consumptionhorizon", "consumptionHorizonBookmark"])
        XCTAssertEqual(w.puts[3].value as? String, "1760000000500;1760000000999;0")
    }

    // S1: Delete chat = clearHistoryTime just past the newest message;
    // the row leaves only once Teams accepted; a failure keeps it.
    func testDeleteChatWritesClearHistoryAndRemovesRowAsDiff() async throws {
        let w = FakePropertyWriter(), s = sync(w)
        let rows = [ChatItem(chatId: "19:x@thread.v2", name: "Emma Clark", last_message_time: "2025-10-09T08:53:20.300Z"),
                    ChatItem(chatId: chat, name: "Oliver Bennett", last_message_time: "2025-10-09T08:50:00.000Z")]
        let vm = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: rows, next_link: nil) })
        await vm.load()
        vm.deleter = { id, ms in try await s.deleteChat(chatID: id, lastMessageMs: ms) }
        w.fail = true
        await vm.delete(chatID: "19:x@thread.v2")
        XCTAssertEqual(vm.chats.map(\.id), rows.map(\.id))
        XCTAssertNotNil(vm.deleteError)
        w.fail = false
        await vm.delete(chatID: "19:x@thread.v2")
        XCTAssertEqual(vm.chats.map(\.id), [chat])
        XCTAssertNil(vm.deleteError)
        XCTAssertEqual(w.puts.map(\.name), ["clearHistoryTime"])
        XCTAssertEqual((w.puts[0].value as? NSNumber)?.int64Value, 1_760_000_000_301)
    }

    func testDeletedChatStaysOutOfTheListUntilANewerMessage() {
        func excl(_ clear: String?, _ last: Int64?) -> ChatListFilter.Exclusion? {
            ChatListFilter.exclusion(id: chat, threadType: "chat", productThreadType: "OneToOneChat", hidden: nil,
                                     lastJoinAt: nil, lastLeaveAt: nil, isEmpty: nil,
                                     clearHistoryTime: clear, lastMessageMs: last)
        }
        XCTAssertEqual(excl("1760000000301", 1_760_000_000_300), .deleted)
        XCTAssertNil(excl("1760000000301", 1_760_000_000_400))
        XCTAssertNil(excl(nil, 1_760_000_000_300))
    }

    // S4: Teams writes the clientmessageid (19 digits) in the horizon's
    // third field. A newer message is unread; the horizon at it is read.
    func testTeamsWrittenHorizonDecidesOnArrivalTime() {
        let teams = "1760000000100;1760000000500;4581237865384574321"
        XCTAssertEqual(ChatListSeed.horizon(teams)?.messageID, 0)
        XCTAssertEqual(ChatListSeed.horizon("1760000000100;1760000000500;1760000000100")?.messageID, 1_760_000_000_100)
        XCTAssertEqual(ChatListSeed.isUnread(horizon: teams, lastMessageID: "1760000000200",
                                             lastMessageTime: "2025-10-09T08:53:20.200Z",
                                             messageType: "RichText/Html", fromOwner: false), true)
        XCTAssertEqual(ChatListSeed.isUnread(horizon: "1760000000200;1760000000500;4581237865384574321",
                                             lastMessageID: "1760000000200",
                                             lastMessageTime: "2025-10-09T08:53:20.200Z",
                                             messageType: "RichText/Html", fromOwner: false), false)
    }

    func testBookmarkMarksUnread() {
        XCTAssertTrue(ChatListSeed.isMarkedUnread(bookmark: "1760000000199;1760000000999;0",
                                                  lastMessageTime: "2025-10-09T08:53:20.200Z"))
        XCTAssertFalse(ChatListSeed.isMarkedUnread(bookmark: "0;1760000000999;0",
                                                   lastMessageTime: "2025-10-09T08:53:20.200Z"))
        XCTAssertFalse(ChatListSeed.isMarkedUnread(bookmark: nil, lastMessageTime: nil))
        let seeds = ChatListSeed.unreadSeeds([ChatItem(chatId: chat, name: "Oliver Bennett",
            last_message_time: "2025-10-09T08:53:20.200Z", unread: false, read_bookmark: "1760000000199;1;0")])
        XCTAssertEqual(seeds.first?.markedUnread, true)
        XCTAssertEqual(seeds.first?.unread, true)
    }

    // S3b/S3c/S4: Teams read state applied as diffs to the unread store.
    func testSeedsFollowTeamsBothWays() {
        let u = UnreadStore(dock: FakeDockBadge())
        let at = Date(timeIntervalSince1970: 1_760_000_000.2)
        u.markRead(chatID: chat)                       // opened here earlier
        let fetch = Date().addingTimeInterval(1)       // list fetch started later
        u.seed([UnreadSeed(chatID: chat, unread: true, lastMessageAt: at, markedUnread: true)], asOf: fetch)
        XCTAssertTrue(u.isUnread(chatID: chat), "marked unread in Teams shows unread here")
        u.seed([UnreadSeed(chatID: chat, unread: false, lastMessageAt: at)], asOf: fetch.addingTimeInterval(1))
        XCTAssertFalse(u.isUnread(chatID: chat), "read in Teams clears it here")
        // A local Mark as unread newer than the fetch survives a stale answer.
        u.markUnread(chatID: chat)
        u.seed([UnreadSeed(chatID: chat, unread: false, lastMessageAt: at)], asOf: Date().addingTimeInterval(-5))
        XCTAssertTrue(u.isUnread(chatID: chat))
        // Seeded unread (read nowhere) → read in Teams → cleared.
        let other = "19:g@thread.v2"
        u.seed([UnreadSeed(chatID: other, unread: true, lastMessageAt: at)], asOf: Date())
        XCTAssertTrue(u.isUnread(chatID: other))
        u.seed([UnreadSeed(chatID: other, unread: false, lastMessageAt: at)], asOf: Date())
        XCTAssertFalse(u.isUnread(chatID: other))
    }

    // S5 guard: read-position writes live in ReadSync only, and the only
    // view report comes from the on-screen timeline. Stores that load or
    // prefetch messages (conversation, pop-outs, Catch Up, search, files)
    // never reach it.
    func testOnlyTheOnScreenTimelineReportsViews() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        var viewCallers: Set<String> = [], writers: Set<String> = []
        for dir in ["Sources/OstMacCore", "Sources/BetterTeamsUI"] {
            let base = root.appendingPathComponent(dir)
            for case let url as URL in fm.enumerator(at: base, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = url.lastPathComponent
                if text.contains("noteViewingLatest(") && !text.contains("func noteViewingLatest(") { viewCallers.insert(name) }
                if text.contains("readSync.viewed(") { viewCallers.insert(name) }
                if text.contains("\"consumptionhorizon\"") || text.contains("\"consumptionHorizonBookmark\"") { writers.insert(name) }
            }
        }
        XCTAssertEqual(viewCallers, ["TimelineViewController.swift", "AppState.swift"])
        XCTAssertEqual(writers, ["ReadSync.swift"])
        let appState = try String(contentsOf: root.appendingPathComponent("Sources/OstMacCore/AppState.swift"), encoding: .utf8)
        XCTAssertEqual(appState.components(separatedBy: "readSync.viewed(").count - 1, 1,
                       "AppState forwards views from noteViewingLatest only")
    }

    // R4: read-state actions live only in the list's row menu (and the
    // Activity feed rows), never in the chat or its info panel.
    func testReadStateActionsOnlyInRowMenu() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = root.appendingPathComponent("Sources/BetterTeamsUI")
        var hits: Set<String> = []
        for case let url as URL in FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["\"Mark as Read\"", "\"Mark as Unread\"", "setChatUnread("] where text.contains(needle) {
                hits.insert(url.lastPathComponent); break
            }
        }
        // CHATSYNC2b R5: the message menu carries Teams' message-level
        // "Mark as Unread" (never "Mark as Read").
        // REGFIX-B R3: the Conversation menu's "Mark as Unread" (Shift-Cmd-U,
        // Mail-style, ChatCommands/ChatSection) is back, Mark as Unread ONLY;
        // the info panel and the chat view still carry none.
        let allowed: Set<String> = ["ChatRowMenu.swift", "ActivitySection.swift", "TeamsListPane.swift",
                                    "MessageContextMenu.swift", "ChatCommands.swift", "ChatSection.swift"]
        XCTAssertTrue(hits.isSubset(of: allowed), "read-state action outside the row menu: \(hits.subtracting(allowed))")
        XCTAssertTrue(hits.contains("ChatRowMenu.swift"))
        let messageMenu = try String(contentsOf: base.appendingPathComponent("Timeline/MessageContextMenu.swift"), encoding: .utf8)
        XCTAssertFalse(messageMenu.contains("\"Mark as Read\""), "no Mark as Read inside a chat")
        for f in ["Sections/Chat/ChatCommands.swift", "Sections/Chat/ChatSection.swift"] {
            let text = try String(contentsOf: base.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(text.contains("\"Mark as Read\""), "\(f): the Conversation menu has no Mark as Read")
        }
    }

    // R5: read positions only move forward; a newer queued write supersedes
    // an older one still waiting.
    func testReadPositionWritesAreMonotonic() async throws {
        let w = FakePropertyWriter(), s = sync(w)
        let older = Task { try await s.markRead(chatID: chat, lastMessageMs: 1_760_000_000_100) }
        let newer = Task { try await s.markRead(chatID: chat, lastMessageMs: 1_760_000_000_300) }
        try await older.value; try await newer.value
        let h = w.puts.filter { $0.name == "consumptionhorizon" }.compactMap { $0.value as? String }
        XCTAssertEqual(h, ["1760000000300;1760000000999;0"], "older superseded by the queued newer one")
        // Later, an older position after the acked newer one: never sent.
        try await s.markRead(chatID: chat, lastMessageMs: 1_760_000_000_200)
        XCTAssertEqual(w.puts.filter { $0.name == "consumptionhorizon" }.count, 1)
    }
}

// S2: a 1:1 whose mate never wrote (only the owner did, or everything
// was deleted) is named from the directory, never "[Direct message]" or
// the owner's own name.
extension FfiLaterB4ChatsTests {
    func testOneToOneWithoutMateMessagesTakesDirectoryName() throws {
        signIn()
        let me = "aaaaaaaa-1111-2222-3333-444444444444"
        let mate = "bbbbbbbb-1111-2222-3333-444444444444"
        let id = "19:\(me)_\(mate)@unq.gbl.spaces"
        let conv = #"{"id":"\#(id)","threadProperties":{"threadType":"chat","productThreadType":"OneToOneChat"},"lastMessage":{"id":"1760000000100","messagetype":"RichText/Html","content":"","imdisplayname":"Owner Name","from":"https://h/v1/users/ME/contacts/8:orgid:\#(me)"}}"#
        http.routes[csaURL()] = (200, #"{"conversations":["# + conv + "]}")
        http.routes["https://graph.microsoft.com/v1.0/me"] = (200, #"{"id":"\#(me)","displayName":"Owner Name"}"#)
        http.routes["\(Self.svcBase)/v1/threads/\(id)/members"] = (200, #"{"members":[{"id":"8:orgid:\#(me)"},{"id":"8:orgid:\#(mate)"}]}"#)
        http.routes["\(Self.svcBase)/v1/users/ME/conversations/\(id)/messages?pageSize=25"] =
            (200, #"{"messages":[{"id":"1760000000100","messagetype":"RichText/Html","content":"","imdisplayname":"Owner Name","from":"8:orgid:\#(me)"}]}"#)
        http.routes["https://graph.microsoft.com/v1.0/users/\(mate)?$select=displayName"] = (200, #"{"displayName":"Oliver Bennett"}"#)
        let r = try CoreReads.chats(limit: 20, ctx: ctx())
        XCTAssertEqual(r.chats.map(\.name), ["Oliver Bennett"])
    }
}
