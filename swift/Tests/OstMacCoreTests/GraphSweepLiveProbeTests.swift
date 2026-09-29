// GraphSweepLiveProbeTests.swift — opt-in live proof of which Microsoft
// Graph permission families the stored Teams-client Graph token can use
// (GRAPHSWEEP_LIVE=1, peer mail in GRAPHSWEEP_PEER).
//
// Read-only: decodes the token's scope claim locally (prints scope names
// only) and issues one GET per permission family the app touches. Prints
// status codes and Graph error codes only — never tokens, claims beyond
// scope names, URLs, ids or response values. Never refreshes the token
// (a stale slot skips the probe instead of rewriting the keychain).
import Foundation
import XCTest
@testable import OstMacCore

final class GraphSweepLiveProbeTests: XCTestCase {
    func testLiveGraphFamilies() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GRAPHSWEEP_LIVE"] == "1", let peer = env["GRAPHSWEEP_PEER"] else {
            throw XCTSkip("set GRAPHSWEEP_LIVE=1 and GRAPHSWEEP_PEER=<mail> to run the Graph family probe")
        }
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()) else {
            throw XCTSkip("stored Graph token missing or stale; not refreshing from a probe")
        }
        let claims = GraphTokenClaims.decode(g.token)
        let scp = ((claims["scp"] as? String) ?? "").split(separator: " ").map(String.init).sorted()
        let roles = (claims["roles"] as? [String]) ?? []
        print("GRAPHSWEEP scp count=\(scp.count) roles count=\(roles.count)")
        print("GRAPHSWEEP scp=\(scp.joined(separator: " "))")
        guard let meOid = claims["oid"] as? String else { return XCTFail("no oid claim") }

        func get(_ label: String, _ path: String) -> Data? {
            guard let url = URL(string: CoreReads.graphBase + path) else {
                print("GRAPHSWEEP \(label) bad-path"); return nil
            }
            do {
                let r = try ctx.http.get(url: url, headers: ["Authorization": "Bearer \(g.token)",
                                                            "Accept": "application/json"])
                let obj = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any]
                let code = ((obj?["error"] as? [String: Any])?["code"] as? String) ?? "-"
                print("GRAPHSWEEP \(label) status=\(r.status) error=\(code)")
                return (200 ... 299).contains(r.status) ? r.data : nil
            } catch {
                print("GRAPHSWEEP \(label) transport-error")
                return nil
            }
        }
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }

        _ = get("me(User.Read)", "/me?$select=id")
        _ = get("me-presence(Presence.Read)", "/me/presence")
        let peerData = get("user(User.ReadBasic.All)", "/users/\(enc(peer))?$select=id")
        let peerOid = peerData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["id"] as? String
        if let peerOid {
            _ = get("user-presence(Presence.Read.All)", "/users/\(peerOid)/presence")
            let a = meOid.lowercased(), b = peerOid.lowercased()
            let chat = "19:\(min(a, b))_\(max(a, b))@unq.gbl.spaces"
            _ = get("chat-members(ChatMember.Read)", "/chats/\(enc(chat))/members")
            _ = get("chat-pins(Chat.Read)", "/chats/\(enc(chat))/pinnedMessages")
        }
        _ = get("joinedTeams(Team.ReadBasic.All)", "/me/joinedTeams?$select=id")
        let now = Date(), fmt = ISO8601DateFormatter()
        _ = get("calendarView(Calendars.Read)",
                "/me/calendarView?startDateTime=\(fmt.string(from: now))&endDateTime=\(fmt.string(from: now.addingTimeInterval(86400)))&$top=1&$select=id")
        _ = get("drive-recent(Files.Read)", "/me/drive/recent?$top=1&$select=id")
        _ = get("people(People.Read)", "/me/people?$top=1&$select=id")
        _ = get("todo(Tasks.Read)", "/me/todo/lists?$top=1&$select=id")
        _ = get("planner(Tasks.Read)", "/me/planner/tasks?$top=1&$select=id")
        _ = get("onenote(Notes.Read)", "/me/onenote/notebooks?$top=1&$select=id")
        _ = get("insights(Sites.Read.All)", "/me/insights/shared?$top=1&$select=id")
    }

    /// Probe C (GRAPHSWEEP_LIVE_C=1): leftover check on the GRAPHSWEEP_PEER
    /// 1:1. Two GETs (peer object id, newest message page — no read
    /// receipt, the consumption horizon never moves); every own, undeleted
    /// message whose text is exactly "test" is deleted. Prints counts only.
    func testLiveLeftoverTestMessagesAreDeleted() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GRAPHSWEEP_LIVE_C"] == "1", let peer = env["GRAPHSWEEP_PEER"] else {
            throw XCTSkip("set GRAPHSWEEP_LIVE_C=1 and GRAPHSWEEP_PEER=<mail> to run the leftover check")
        }
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()) else {
            throw XCTSkip("stored Graph token missing or stale; not refreshing from a probe")
        }
        // The Rust client refreshes (and writes the store) when the Teams
        // AAD or skype token is stale; a probe must never do that.
        guard let aad = slots.accessToken, !aad.isExpired(now: ctx.now()),
              let sk = slots.skypeToken, !sk.isExpired(now: ctx.now())
        else { throw XCTSkip("stored Teams tokens missing or stale; not refreshing from a probe") }
        guard let meOid = (GraphTokenClaims.decode(g.token)["oid"] as? String)?.lowercased() else {
            return XCTFail("no oid claim")
        }
        let enc = peer.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? peer
        guard let url = URL(string: CoreReads.graphBase + "/users/\(enc)?$select=id") else { return XCTFail("bad path") }
        let r = try ctx.http.get(url: url, headers: ["Authorization": "Bearer \(g.token)"])
        guard (200 ... 299).contains(r.status),
              let peerOid = ((try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any])?["id"] as? String
        else { return XCTFail("peer lookup status=\(r.status)") }
        let a = meOid, b = peerOid.lowercased()
        let chat = "19:\(min(a, b))_\(max(a, b))@unq.gbl.spaces"
        let page = try RustCore.messages(chatID: chat, limit: 50)
        let plain = { (s: String) in
            s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let leftovers = page.messages.filter { $0.isOwn && !$0.deleted && plain($0.content) == "test" }
        var deleted = 0
        for m in leftovers where (try? RustCore.deleteMessage(chatID: chat, messageID: m.id))?.ok == true {
            deleted += 1
        }
        print("GRAPHSWEEP leftover scanned=\(page.messages.count) ownTestUndeleted=\(leftovers.count) deleted=\(deleted)")
        XCTAssertEqual(deleted, leftovers.count, "a leftover test message could not be deleted")
    }

    /// Probe B (GRAPHSWEEP_LIVE_B=1): the switched features on their Teams
    /// services plus the remaining Graph families. Writes: only the 1:1
    /// with GRAPHSWEEP_PEER, one message of exactly "test", deleted at once.
    /// Prints statuses, counts and sources only.
    func testLiveSwitchedFeatures() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GRAPHSWEEP_LIVE_B"] == "1", let peer = env["GRAPHSWEEP_PEER"] else {
            throw XCTSkip("set GRAPHSWEEP_LIVE_B=1 and GRAPHSWEEP_PEER=<mail> to run the switched-feature probe")
        }
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()),
              let a = slots.accessToken, !a.isExpired(now: ctx.now())
        else { throw XCTSkip("stored tokens missing or stale; not refreshing from a probe") }
        guard let meOid = (GraphTokenClaims.decode(g.token)["oid"] as? String)?.lowercased() else {
            return XCTFail("no oid claim")
        }

        // 1:1 open/create on the chat service (§106), one "test" send, deleted.
        let chat = try RustCore.chatCreateOneToOne(user: peer).chat
        print("GRAPHSWEEP 1:1 open ok=true unq=\(chat.chatId.hasSuffix("@unq.gbl.spaces"))")
        let cmid = String(UInt64.random(in: 1_000_000_000_000 ... 9_999_999_999_999))
        let sent = try RustCore.sendIdem(chatID: chat.chatId, text: "test", clientMessageID: cmid)
        var messageID = sent.id
        if messageID == nil {
            messageID = try RustCore.findClientMessage(chatID: chat.chatId, clientMessageID: cmid).message?.id
        }
        guard let messageID else { return XCTFail("SENT test message id unknown — delete by hand (client id logged locally only)") }
        let del = try RustCore.deleteMessage(chatID: chat.chatId, messageID: messageID)
        print("GRAPHSWEEP send ok=\(sent.ok) deleted ok=\(del.ok)")
        XCTAssertTrue(del.ok, "test message not deleted")

        // Switched reads: roster and pins on the chat service only.
        let roster = try RustCore.chatMembers(chatID: chat.chatId)
        print("GRAPHSWEEP roster source=\(roster.source) members=\(roster.members.count) blankNames=\(roster.members.filter { $0.displayName.isEmpty }.count)")
        let pins = try RustCore.chatPinnedMessages(chatID: chat.chatId)
        print("GRAPHSWEEP pins ok=\(pins.ok) source=\(pins.source ?? "-") count=\(pins.pins.count)")

        // Remaining Graph families (raw status only).
        func graph(_ label: String, _ path: String) -> Data? {
            guard let url = URL(string: CoreReads.graphBase + path) else { return nil }
            guard let r = try? ctx.http.get(url: url, headers: ["Authorization": "Bearer \(g.token)"]) else {
                print("GRAPHSWEEP \(label) transport-error"); return nil
            }
            let obj = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any]
            print("GRAPHSWEEP \(label) status=\(r.status) error=\(((obj?["error"] as? [String: Any])?["code"] as? String) ?? "-")")
            return (200 ... 299).contains(r.status) ? r.data : nil
        }
        _ = graph("onlineMeetings(OnlineMeetings.Read)",
                  "/me/onlineMeetings?$filter=joinMeetingIdSettings/joinMeetingId%20eq%20'000000000000'")
        if let d = graph("joinedTeams", "/me/joinedTeams?$select=id"),
           let team = (((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["value"] as? [[String: Any]])?
               .first?["id"] as? String {
            _ = graph("tags(TeamworkTag.Read)", "/teams/\(team)/tags")
        }
        let parts = chat.chatId.dropFirst(3).dropLast("@unq.gbl.spaces".count).split(separator: "_").map(String.init)
        if let peerOid = parts.first(where: { $0.lowercased() != meOid }) {
            _ = graph("manager(User.ReadBasic.All)", "/users/\(peerOid)/manager?$select=id")
        }
    }
}
