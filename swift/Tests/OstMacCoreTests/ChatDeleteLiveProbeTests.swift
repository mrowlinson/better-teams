// ChatDeleteLiveProbeTests.swift — CHATSYNC3 R5: opt-in live proof of
// Delete chat on the owner-designated test chat (the 1:1 with Test User5).
//
// Needs CHATDELETE_LIVE=1 AND a mode word in `tmp/cleanup/mode.txt`
// (found by walking up from this file). Default = skip everything:
//   mode "send"    -> testLiveDeleteChatOnTheTestUserChat (sends ONE "test")
//   mode "cleanup" -> testLiveCleanupLeftoverTestMessage (deletes only;
//                     no send path is reachable from it)
// Run:
//   CHATDELETE_LIVE=1 swift test --filter ChatDeleteLiveProbeTests --package-path <swift dir>
//
// Send mode, through the app's shipped code paths:
//   1. the 1:1 with Test User5 is resolved directly (directory GET for the
//      one user with that account + the owner's id -> the 1:1 thread id;
//      the thread is read before anything is sent);
//   2. one send of exactly "test" (SendTransport.live) — a failed send
//      aborts the run, never retried;
//   3. the "test" message is deleted FIRST (soft delete, the request
//      Teams web makes) and the deletion confirmed by a re-read — a
//      message cleared from view by Delete chat must never be left behind;
//   4. Delete chat (ChatListViewModel.delete -> ReadSync.deleteChat, the
//      `clearHistoryTime` write AppState wires) -> the row leaves the
//      list; a fresh Teams list read and the conversation's own
//      properties confirm it.
// Prints step names, HTTP status codes, booleans and counts only, to the
// test's stdout — never tokens, ids, names, URLs or message text.
import Foundation
import XCTest
@testable import OstMacCore

@MainActor
final class ChatDeleteLiveProbeTests: XCTestCase {
    /// Set CHATDELETE_PEER_UPN to the test user's UPN for a live run.
    static let peerUPN = ProcessInfo.processInfo.environment["CHATDELETE_PEER_UPN"] ?? "test-user@contoso.example"

    private func say(_ s: String) {
        print("CHATDELETE \(s)")
        fflush(stdout)
    }

    /// "HTTP 404" style status from a core/read error, else "error".
    private func status(_ e: Error) -> String {
        let s = "\(e)"
        guard let r = s.range(of: #"HTTP \d{3}"#, options: .regularExpression) else { return "error" }
        return String(s[r])
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The run mode from the nearest ancestor's `tmp/cleanup/mode.txt`;
    /// nil (skip) when absent.
    static func mode(file: String = #filePath) -> String? {
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/" {
            let f = dir.appendingPathComponent("tmp/cleanup/mode.txt")
            if let s = try? String(contentsOf: f, encoding: .utf8) {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func requireMode(_ want: String) throws {
        guard ProcessInfo.processInfo.environment["CHATDELETE_LIVE"] == "1" else {
            throw XCTSkip("set CHATDELETE_LIVE=1 (and tmp/cleanup/mode.txt = \(want)) to run")
        }
        let got = Self.mode()
        guard got == want else {
            say("step=mode want=\(want) got=\(got ?? "none") skipped=true")
            throw XCTSkip("mode is not \(want)")
        }
    }

    private struct Target {
        let ctx: ReadContext
        let skype: String
        let svc: String
        let chat: String
        let meOid: String
        /// Path form (the list/properties reads use this).
        var encChat: String { chat.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chat }
    }

    /// Resolve the Test User5 1:1 (read-only GETs) and read its thread.
    private func resolve() throws -> Target? {
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard let sk = slots.skypeToken, !sk.isExpired(now: ctx.now()) else {
            say("BLOCKED stored Teams token missing or stale")
            throw XCTSkip("stale tokens")
        }
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()),
              let meOid = (GraphTokenClaims.decode(g.token)["oid"] as? String)?.lowercased()
        else {
            say("BLOCKED stored Graph token missing or stale")
            throw XCTSkip("stale Graph token")
        }
        let upn = Self.peerUPN
        var q = URLComponents(string: CoreReads.graphBase + "/users")
        q?.queryItems = [URLQueryItem(name: "$filter", value: "userPrincipalName eq '\(upn)' or mail eq '\(upn)'"),
                         URLQueryItem(name: "$select", value: "id")]
        guard let usersURL = q?.url else { XCTFail("bad directory URL"); return nil }
        let dir = try ctx.http.get(url: usersURL, headers: ["Authorization": "Bearer \(g.token)"])
        let ids = (((try? JSONSerialization.jsonObject(with: dir.data)) as? [String: Any])?["value"] as? [[String: Any]] ?? [])
            .compactMap { ($0["id"] as? String)?.lowercased() }
        say("step=resolve directory=\(dir.status) matches=\(ids.count)")
        guard (200 ... 299).contains(dir.status), ids.count == 1, let peerOid = ids.first, peerOid != meOid else {
            XCTFail("need exactly one directory user for the Test User5 account")
            return nil
        }
        let t = Target(ctx: ctx, skype: sk.token, svc: CoreReads.chatServiceURL(slots),
                       chat: "19:\(min(meOid, peerOid))_\(max(meOid, peerOid))@unq.gbl.spaces", meOid: meOid)
        do {
            _ = try CoreReads.chatGET("\(t.svc)/v1/users/ME/conversations/\(t.encChat)?view=msnp24Equivalent",
                                      code: "chatdelete", skype: t.skype, http: t.ctx.http)
            say("step=thread status=200")
        } catch {
            say("step=thread status=\(status(error))")
            XCTFail("the Test User5 1:1 thread could not be read")
            return nil
        }
        return t
    }

    /// Soft-delete one own message: the request Teams web makes
    /// (`DELETE .../conversations/{encodeURIComponent(conv)}/messages/{id}?behavior=softDelete`).
    /// A bare DELETE (no `behavior=softDelete`) is a hard delete, which the
    /// chat service refuses for a user with HTTP 403.
    private func softDelete(_ t: Target, messageID: String) throws -> Int {
        var comp = CharacterSet.alphanumerics
        comp.insert(charactersIn: "-_.!~*'()")
        let conv = t.chat.addingPercentEncoding(withAllowedCharacters: comp) ?? t.chat
        let mid = messageID.addingPercentEncoding(withAllowedCharacters: comp) ?? messageID
        guard let url = URL(string: "\(t.svc)/v1/users/ME/conversations/\(conv)/messages/\(mid)?behavior=softDelete") else {
            return 0
        }
        let r = try URLSessionCalendarHTTP().send("DELETE", url: url,
                                                  headers: ["Authentication": "skypetoken=\(t.skype)"], body: nil)
        return r.status
    }

    /// Re-read one message: deleted when it carries `deletetime`, has
    /// empty content, or is gone (404).
    private func confirmDeleted(_ t: Target, messageID: String) -> Bool {
        do {
            let d = try CoreReads.chatGET("\(t.svc)/v1/users/ME/conversations/\(t.encChat)/messages/\(messageID)",
                                          code: "chatdelete", skype: t.skype, http: t.ctx.http)
            let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            let props = obj?["properties"] as? [String: Any]
            let deleted = props?["deletetime"] != nil
            let content = ((obj?["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            say("step=message-reread status=200 deletetime=\(deleted) contentEmpty=\(content.isEmpty)")
            return deleted || content.isEmpty
        } catch {
            let st = status(error)
            say("step=message-reread status=\(st)")
            return st == "HTTP 404"
        }
    }

    /// True for an undeleted message the owner sent whose text is exactly "test".
    private static func isOwnLiveTest(_ m: [String: Any], meOid: String) -> Bool {
        let from = ((m["from"] as? String) ?? "").lowercased()
        guard from.hasSuffix("8:orgid:\(meOid)") else { return false }
        let props = m["properties"] as? [String: Any]
        guard props?["deletetime"] == nil else { return false }
        let raw = (m["content"] as? String) ?? ""
        let text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "test"
    }

    /// Shape only (no text, ids or names): sender is owner, type,
    /// deleted flag, content length, age in minutes.
    private static func shape(_ m: [String: Any], meOid: String) -> String {
        let from = ((m["from"] as? String) ?? "").lowercased()
        let props = m["properties"] as? [String: Any]
        let len = ((m["content"] as? String) ?? "").count
        let idMs = Int64((m["id"] as? String) ?? "") ?? 0
        let age = idMs > 0 ? (Int64(Date().timeIntervalSince1970 * 1000) - idMs) / 60000 : -1
        let type = ((m["messagetype"] as? String) ?? "none").prefix(24)
        return "own=\(from.hasSuffix("8:orgid:\(meOid)")) type=\(type) deletetime=\(props?["deletetime"] != nil) len=\(len) ageMin=\(age)"
    }

    // MARK: - cleanup mode (delete only; no send path)

    func testLiveCleanupLeftoverTestMessage() async throws {
        try requireMode("cleanup")
        guard let t = try resolve() else { return }

        // After Delete chat the chat service hides every message older than
        // the owner's clearHistoryTime from the owner: the message list reads
        // empty and a GET or DELETE of such a message by id returns 403.
        // The conversation summary still names the last message, which is
        // the leftover "test".
        let convURL = "\(t.svc)/v1/users/ME/conversations/\(t.encChat)?view=msnp24Equivalent"
        func conversation() throws -> [String: Any] {
            let d = try CoreReads.chatGET(convURL, code: "chatdelete", skype: t.skype, http: t.ctx.http)
            return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
        }
        func clearTime(_ c: [String: Any]) -> Int64? {
            ((c["properties"] as? [String: Any])?["clearHistoryTime"]).flatMap { Int64("\($0)") }
        }
        let conv = try conversation()
        guard let last = conv["lastMessage"] as? [String: Any], let mid = last["id"] as? String,
              let midMs = Int64(mid) else {
            say("step=last-message present=false")
            return XCTFail("no last message")
        }
        let c0 = clearTime(conv)
        let from = ((last["from"] as? String) ?? "").lowercased()
        let type = (last["messagetype"] as? String) ?? ""
        let deleted = (last["properties"] as? [String: Any])?["deletetime"] != nil
        let ageMin = (Int64(Date().timeIntervalSince1970 * 1000) - midMs) / 60000
        let hidden = (c0 ?? 0) > midMs
        say("step=last-message \(Self.shape(last, meOid: t.meOid)) hiddenByClear=\(hidden)")
        guard from.hasSuffix("8:orgid:\(t.meOid)"), type == "RichText/Html" || type == "Text",
              !deleted, (0 ... 180).contains(ageMin) else {
            return XCTFail("last message is not a recent undeleted own text message; nothing deleted")
        }

        // 1. Direct soft delete (Teams web's request).
        let st = (try? softDelete(t, messageID: mid)) ?? 0
        say("step=soft-delete-direct status=\(st)")
        if (200 ... 299).contains(st) {
            await pause(2)
            let after = try conversation()
            let lm = after["lastMessage"] as? [String: Any]
            say("step=verify-summary \(lm.map { Self.shape($0, meOid: t.meOid) } ?? "none")")
            return
        }

        // Refused: the message is older than the owner's clearHistoryTime, so
        // the chat service hides it from the owner (GET by id is 403 too).
        // Deleting it needs the chat un-cleared first; not done here.
        XCTFail("soft delete refused (status \(st)); hiddenByClear=\(hidden)")
    }

    // MARK: - send mode (one "test" send, then delete it, then Delete chat)

    func testLiveDeleteChatOnTheTestUserChat() async throws {
        try requireMode("send")
        guard let t = try resolve() else { return }
        let chat = t.chat

        // The app's own list read (paged view model); the row may be absent
        // until the send below brings the chat back.
        let list = ChatListViewModel(pins: UserPinStore(defaults: MemoryDefaults()),
                                     blocked: BlockedStore(defaults: nil),
                                     folders: FolderStore(defaults: MemoryDefaults()))
        await list.load(limit: 50)
        func row() -> ChatItem? { list.chat(id: chat) }
        say("step=list rows=\(list.chats.count) listedBeforeSend=\(row() != nil)")

        // 2. One send of exactly "test" (the composer's wire). No retry.
        let cmid = String(UInt64.random(in: 1_000_000_000_000 ... 9_999_999_999_999))
        let send = OutgoingSend(chatID: chat, text: "test", clientMessageID: cmid)
        var messageID: String?
        do {
            messageID = try SendTransport.live.post(send)
            say("step=send ok=true idInReply=\(messageID != nil)")
        } catch {
            say("step=send ok=false status=\(status(error)) (aborted, not retried)")
            return XCTFail("send failed; aborted without retry")
        }
        if messageID == nil {
            messageID = try? SendTransport.live.find(chat, cmid)?.id
            say("step=send-lookup found=\(messageID != nil)")
        }
        guard let messageID, let sentMs = ReadSync.arrivalMs(ChatMessage(id: messageID, sender: "", timestamp: "", content: "")) else {
            return XCTFail("sent message id unknown — run cleanup mode")
        }

        // Wait for the list row to carry the send (Delete chat clears past it).
        var rowReady = false
        for attempt in 1 ... 6 {
            await list.load(limit: 50)
            if let row = row(), let last = CoreReads.arrivalMs(id: nil, time: row.last_message_time),
               last >= sentMs {
                rowReady = true
                say("step=row-has-send attempt=\(attempt)")
                break
            }
            await pause(2.5)
        }

        // 3. Delete the "test" message FIRST and confirm.
        do {
            let st = try softDelete(t, messageID: messageID)
            say("step=delete-message status=\(st)")
            XCTAssertTrue((200 ... 299).contains(st), "test message not deleted — run cleanup mode")
        } catch {
            say("step=delete-message status=error")
            return XCTFail("test message delete failed — run cleanup mode")
        }
        await pause(2)
        XCTAssertTrue(confirmDeleted(t, messageID: messageID), "Teams still shows the test message")

        // 4. Delete chat.
        guard rowReady else {
            say("step=row-has-send ok=false (Delete chat not attempted)")
            return XCTFail("the list never showed the sent message; Delete chat not attempted")
        }
        list.deleter = { id, lastMs in try await ReadSync().deleteChat(chatID: id, lastMessageMs: lastMs) }
        await list.delete(chatID: chat)
        let localGone = list.chat(id: chat) == nil
        say("step=delete-chat error=\(list.deleteError != nil) rowGoneLocally=\(localGone)")
        XCTAssertNil(list.deleteError, "Delete chat write failed")
        XCTAssertTrue(localGone, "row still listed after Delete chat")

        // Teams re-read: a fresh list read no longer lists it.
        await pause(2)
        let fresh = ChatListViewModel(pins: UserPinStore(defaults: MemoryDefaults()),
                                      blocked: BlockedStore(defaults: nil),
                                      folders: FolderStore(defaults: MemoryDefaults()))
        await fresh.load(limit: 50)
        let listedAgain = fresh.chat(id: chat) != nil
        say("step=reread rows=\(fresh.chats.count) listed=\(listedAgain)")
        XCTAssertFalse(listedAgain, "Teams still lists the deleted chat")

        // The conversation's own properties: clearHistoryTime past the send.
        do {
            let d = try CoreReads.chatGET("\(t.svc)/v1/users/ME/conversations/\(t.encChat)?view=msnp24Equivalent",
                                          code: "chatdelete", skype: t.skype, http: t.ctx.http)
            let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            let props = obj?["properties"] as? [String: Any]
            let clear = (props?["clearHistoryTime"]).flatMap { Int64("\($0)") }
            say("step=properties status=200 hasClearHistoryTime=\(clear != nil) pastSend=\((clear ?? 0) > sentMs)")
            XCTAssertGreaterThan(clear ?? 0, sentMs, "clearHistoryTime not past the sent message")
        } catch {
            say("step=properties status=\(status(error))")
            XCTFail("conversation properties read failed")
        }
    }
}
