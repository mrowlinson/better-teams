// ChatSyncLiveProbeTests.swift — opt-in live proof for CHATSYNC, locked
// to ONE chat: the owner's 1:1 with the test account named by
// CHATSYNC_MATE (a UPN; nothing is hard-coded here).
//
// CHATSYNC_LIVE=1: read-only GETs of that chat (conversation, newest
// page) and prints shapes only — counts, booleans, digit lengths. Never
// tokens, names, ids, URLs or message text.
// CHATSYNC_LIVE_WRITE=1 additionally moves that chat's read state the
// way the app does (ReadSync): read position to the newest message,
// Mark as unread (bookmark), Mark as read (bookmark cleared), re-reading
// after each step. No messages are sent. Never refreshes a token (a
// stale slot skips the probe).
import Foundation
import XCTest
@testable import OstMacCore

final class ChatSyncLiveProbeTests: XCTestCase {
    @MainActor
    func testLiveTestUserChat() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CHATSYNC_LIVE"] == "1", let mateUPN = env["CHATSYNC_MATE"], !mateUPN.isEmpty else {
            throw XCTSkip("set CHATSYNC_LIVE=1 and CHATSYNC_MATE=<upn> to run the one-chat probe")
        }
        let ctx = try CoreReads.production()
        let profile = TomlConfig.normalize(CoreLocal.activeProfileID())
        let slots = ctx.store.load(profile: profile)
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()),
              let sk = slots.skypeToken, !sk.isExpired(now: ctx.now()) else {
            print("CHATSYNC BLOCKED stored tokens missing or stale; not refreshing from a probe")
            throw XCTSkip("stale tokens")
        }
        func graph(_ path: String) -> [String: Any]? {
            guard let d = try? CoreReads.graphGET(path, code: "probe", token: g.token, http: ctx.http) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        guard let me = graph("/me?$select=id")?["id"] as? String,
              let mate = graph("/users/\(mateUPN)?$select=id")?["id"] as? String else {
            print("CHATSYNC FAIL identity lookups"); return
        }
        let pair = [me.lowercased(), mate.lowercased()].sorted()
        let chatID = "19:\(pair[0])_\(pair[1])@unq.gbl.spaces"
        let svc = CoreReads.chatServiceURL(slots)
        func conv() -> [String: Any]? {
            guard let d = try? CoreReads.chatGET("\(svc)/v1/users/ME/conversations/\(chatID)", code: "probe",
                                                 skype: sk.token, http: ctx.http) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        func digits(_ raw: String?) -> String {
            guard let raw else { return "nil" }
            return raw.split(separator: ";", omittingEmptySubsequences: false).map { "\($0.count)" }.joined(separator: "/")
        }
        func props(_ c: [String: Any]?) -> [String: Any] { (c?["properties"] as? [String: Any]) ?? [:] }
        guard let c = conv() else { print("CHATSYNC FAIL conversation GET"); return }
        let last = c["lastMessage"] as? [String: Any] ?? [:]
        let from = (last["from"] as? String) ?? ""
        let topic = ((c["threadProperties"] as? [String: Any])?["topic"] as? String) ?? ""
        let p = props(c)
        print("CHATSYNC conv topicEmpty=\(topic.isEmpty) lastType=\(last["messagetype"] as? String ?? "nil") "
              + "lastFromSelf=\(from.lowercased().contains(me.lowercased())) "
              + "lastNameEmpty=\(((last["imdisplayname"] as? String) ?? "").isEmpty) "
              + "lastContentEmpty=\(((last["content"] as? String) ?? "").isEmpty) "
              + "lastDeleted=\(((last["properties"] as? [String: Any])?["deletetime"]) != nil) "
              + "horizonDigits=\(digits(p["consumptionhorizon"] as? String)) "
              + "bookmarkDigits=\(digits(p["consumptionHorizonBookmark"] as? String)) "
              + "clearHistory=\(p["clearHistoryTime"] != nil)")
        let page = (try? CoreReads.chatGET("\(svc)/v1/users/ME/conversations/\(chatID)/messages?pageSize=25",
                                           code: "probe", skype: sk.token, http: ctx.http))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let msgs = (page?["messages"] as? [[String: Any]]) ?? []
        let fromMate = msgs.filter { (($0["from"] as? String) ?? "").lowercased().contains(mate.lowercased()) }.count
        let userMsgs = msgs.filter { (($0["messagetype"] as? String) ?? "").hasPrefix("Text") || (($0["messagetype"] as? String) ?? "").hasPrefix("RichText") }
        print("CHATSYNC page messages=\(msgs.count) user=\(userMsgs.count) fromMate=\(fromMate) "
              + "emptyContent=\(userMsgs.filter { (($0["content"] as? String) ?? "").isEmpty }.count)")
        let byMessages = CoreReads.resolveMateName(chatID: chatID, selfOID: me, skype: sk.token, svc: svc, ctx: ctx)
        let byDirectory = CoreReads.mateDisplayName(chatID: chatID, selfOID: me, profile: profile, ctx: ctx)
        print("CHATSYNC S2 mateFromMessages=\(byMessages != nil) mateFromDirectory=\(byDirectory != nil) "
              + "oldTitle=\(CoreReads.conversationName(topic: topic, mate: byMessages, sender: last["imdisplayname"] as? String, chatID: chatID).hasPrefix("[") ? "placeholder" : "name") "
              + "newTitleIsName=\(!(byMessages ?? byDirectory ?? "[").hasPrefix("["))")

        guard env["CHATSYNC_LIVE_WRITE"] == "1" else { return }
        let newest = userMsgs.compactMap { ($0["id"] as? String).flatMap { Int64($0) } }.max()
            ?? (last["id"] as? String).flatMap { Int64($0) }
        guard let newest else { print("CHATSYNC S3 BLOCKED no message to read through"); return }
        let sync = ReadSync()
        let t0 = Date()
        let task = sync.viewed(chatID: chatID, messages: [ChatMessage(id: String(newest), sender: "", timestamp: "", content: "", isOwn: false)],
                               gate: ReadViewGate(isOpen: true, windowActive: true, atLatest: true, loaded: true))
        await task?.value
        let h1 = ChatListSeed.horizon(props(conv())["consumptionhorizon"] as? String)
        print("CHATSYNC S3a view write=\(sync.writes) err=\(sync.lastError != nil) horizonAtNewest=\(h1?.readMs == newest) "
              + "ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        try await sync.markUnread(chatID: chatID, lastMessageMs: newest)
        let c2 = props(conv())
        let marked = ChatListSeed.isMarkedUnread(bookmark: c2["consumptionHorizonBookmark"] as? String,
                                                 lastMessageTime: nil)
        let behind = ChatListSeed.horizon(c2["consumptionHorizonBookmark"] as? String)?.readMs == newest - 1
        print("CHATSYNC S3c unread bookmarkSet=\(marked) bookmarkBehindNewest=\(behind) bookmarkDigits=\(digits(c2["consumptionHorizonBookmark"] as? String))")
        try await sync.markRead(chatID: chatID, lastMessageMs: newest)
        let c3 = props(conv())
        let cleared = !ChatListSeed.isMarkedUnread(bookmark: c3["consumptionHorizonBookmark"] as? String, lastMessageTime: nil)
        let h3 = ChatListSeed.horizon(c3["consumptionhorizon"] as? String)
        print("CHATSYNC S3c read bookmarkCleared=\(cleared) horizonAtNewest=\(h3?.readMs == newest) writes=\(sync.writes)")
    }
}
