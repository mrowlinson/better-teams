// ChatSync2bLiveProbeTests.swift — opt-in live proof for CHATSYNC2b.
//
// CHATSYNC2B_LIVE=1: read-only. One chat-list GET (the owner's own
// per-chat properties) and one policy query (the Teams web client's
// `useraggregatesettings` read, a POST with a namespace list and no
// side effects). Prints shapes only: counts, booleans, enum values.
// Never tokens, names, ids, URLs or message text.
import COstMac
import Foundation
import XCTest
@testable import OstMacCore

final class ChatSync2bLiveProbeTests: XCTestCase {
    func testLiveMuteAndDeletePolicyShapes() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CHATSYNC2B_LIVE"] == "1" else {
            throw XCTSkip("set CHATSYNC2B_LIVE=1 to run the read-only probe")
        }
        let ctx = try CoreReads.production()
        let profile = TomlConfig.normalize(CoreLocal.activeProfileID())
        let slots = ctx.store.load(profile: profile)
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()),
              let sk = slots.skypeToken, !sk.isExpired(now: ctx.now()) else {
            print("CHATSYNC2B BLOCKED stored tokens missing or stale; not refreshing from a probe")
            throw XCTSkip("stale tokens")
        }
        guard let meData = try? CoreReads.graphGET("/me?$select=id", code: "probe", token: g.token, http: ctx.http),
              let me = ((try? JSONSerialization.jsonObject(with: meData)) as? [String: Any])?["id"] as? String else {
            print("CHATSYNC2B FAIL identity"); return
        }
        let svc = CoreReads.chatServiceURL(slots)
        guard let d = try? CoreReads.chatGET("\(svc)/v1/users/ME/conversations?view=mychats&pageSize=100",
                                             code: "probe", skype: sk.token, http: ctx.http),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            print("CHATSYNC2B FAIL chat list GET"); return
        }
        let convs = (obj["conversations"] as? [[String: Any]]) ?? []
        var hist: [String: Int] = [:]
        var mismatches = 0
        var meetingKeys: [String: Int] = [:]
        var tpKeys: [String: Int] = [:]
        var creatorShapes: [String: Int] = [:]
        var infoKeys: [String: Int] = [:]
        for c in convs {
            let id = (c["id"] as? String) ?? ""
            let props = (c["properties"] as? [String: Any]) ?? [:]
            let tp = (c["threadProperties"] as? [String: Any]) ?? [:]
            let kind = id.hasPrefix("19:meeting") ? "meeting"
                : id.contains("@unq.gbl.spaces") ? "oneOnOne"
                : id.contains("thread") ? "group" : "other"
            let alerts = (props["alerts"] as? String).map { $0.lowercased() } ?? "nil"
            let creator = ((tp["creator"] as? String) ?? "").lowercased()
            let creatorSelf = creator.hasSuffix(me.lowercased())
            let meetingInfo = props["meetingInfo"] as? String
            let rsvp = ChatMuteRule.rsvpStatus(meetingInfo: meetingInfo)
            let old: Bool? = alerts == "false" ? true : alerts == "true" ? false : nil
            let teams = ChatMuteRule.isMuted(chatID: id, alerts: props["alerts"] as? String,
                                             meetingInfo: meetingInfo, creatorIsSelf: creatorSelf)
            if (old ?? false) != teams { mismatches += 1 }
            let key = "\(kind) alerts=\(alerts) rsvp=\(kind == "meeting" ? rsvp : "-") creatorSelf=\(creatorSelf) old=\(old.map(String.init) ?? "nil") teams=\(teams)"
            hist[key, default: 0] += 1
            if kind == "meeting" { for k in props.keys { meetingKeys[k, default: 0] += 1 } }
            for k in tp.keys { tpKeys["\(kind).\(k)", default: 0] += 1 }
            if !creator.isEmpty { creatorShapes["\(kind).\(creator.hasPrefix("8:orgid:") ? "orgid" : "other")", default: 0] += 1 }
            if let mi = meetingInfo, let md = mi.data(using: .utf8),
               let mo = (try? JSONSerialization.jsonObject(with: md)) as? [String: Any] {
                for k in mo.keys { infoKeys[k, default: 0] += 1 }
            }
        }
        print("CHATSYNC2B threadPropKeys \(tpKeys.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        print("CHATSYNC2B creatorShapes \(creatorShapes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        print("CHATSYNC2B meetingInfoKeys \(infoKeys.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")
        print("CHATSYNC2B chats=\(convs.count) muteMismatches=\(mismatches)")
        for (k, n) in hist.sorted(by: { $0.key < $1.key }) { print("CHATSYNC2B mute \(n)x \(k)") }
        print("CHATSYNC2B meetingPropKeys \(meetingKeys.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))")

        // Delete-chat policy: the Teams client's own policy read.
        let policy = MessagingPolicyReader.fetchRaw(slots: slots, now: ctx.now())
        print("CHATSYNC2B policy status=\(policy.status) resultCode=\(policy.resultCode ?? "nil") "
              + "allowUserDeleteChat=\(policy.allowUserDeleteChat.map(String.init) ?? "absent") "
              + "valueKeys=\(policy.valueKeyCount)")
    }
}

// R3: does our Trouter socket carry read-state changes? CHATSYNC2B_TROUTER=1
// with CHATSYNC_MATE=<test account UPN>: starts a Trouter session in this
// process (fresh endpoint; the running app's own session is untouched),
// then moves ONLY the owner's 1:1 with the test account: Mark as unread
// (bookmark) and back to read (horizon + bookmark cleared), as ReadSync
// does. Prints event shapes only (resource types, property names, whether
// the frame names that chat); never ids, names or text.

extension ChatSync2bLiveProbeTests {
    func testLiveTrouterCarriesReadState() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CHATSYNC2B_TROUTER"] == "1", let mateUPN = env["CHATSYNC_MATE"], !mateUPN.isEmpty else {
            throw XCTSkip("set CHATSYNC2B_TROUTER=1 and CHATSYNC_MATE=<upn>")
        }
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()),
              let sk = slots.skypeToken, !sk.isExpired(now: ctx.now()) else {
            print("CHATSYNC2B BLOCKED stale tokens"); throw XCTSkip("stale tokens")
        }
        func graph(_ path: String) -> String? {
            guard let d = try? CoreReads.graphGET(path, code: "probe", token: g.token, http: ctx.http) else { return nil }
            return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["id"] as? String
        }
        guard let me = graph("/me?$select=id"), let mate = graph("/users/\(mateUPN)?$select=id") else {
            print("CHATSYNC2B FAIL identity"); return
        }
        let pair = [me.lowercased(), mate.lowercased()].sorted()
        let chatID = "19:\(pair[0])_\(pair[1])@unq.gbl.spaces"
        let svc = CoreReads.chatServiceURL(slots)
        guard let cd = try? CoreReads.chatGET("\(svc)/v1/users/ME/conversations/\(chatID)", code: "probe",
                                             skype: sk.token, http: ctx.http),
              let conv = (try? JSONSerialization.jsonObject(with: cd)) as? [String: Any],
              let lastID = (conv["lastMessage"] as? [String: Any])?["id"] as? String,
              let last = Int64(lastID) else { print("CHATSYNC2B FAIL conversation"); return }

        XCTAssertEqual(ostmac_trouter_start(), 0, "trouter start")
        defer { _ = ostmac_trouter_stop() }
        // CHATSYNC2B_TYPED=1: through the lane core's typed envelope (the
        // app's own path): read_states for the test chat and the verdict
        // the app would apply. Booleans only.
        func drainTyped(seconds: Double, label: String) {
            let deadline = Date().addingTimeInterval(seconds)
            var lines: [String: Int] = [:]
            while Date() < deadline {
                guard let p = try? RustCore.trouterPollTypedWait(timeoutMs: 1000) else { continue }
                for ev in p.readStates ?? [] {
                    let seed = ChatListSeed.pushedSeed(ev, ownerOID: me, muted: false)
                    let k = "forTestChat=\(ev.chatID == chatID) horizon=\(ev.horizon != nil) bookmark=\(ev.bookmark != nil) "
                        + "lastMsg=\(ev.lastMessageID != nil) time=\(ev.time.flatMap(ChatListFormat.parse) != nil) "
                        + "unread=\(seed.map { String($0.unread) } ?? "nil") marked=\(seed.map { String($0.markedUnread) } ?? "nil")"
                    lines[k, default: 0] += 1
                }
            }
            print("CHATSYNC2B typed \(label) read_states:")
            for (k, n) in lines.sorted(by: { $0.key < $1.key }) { print("CHATSYNC2B   \(n)x \(k)") }
        }
        if env["CHATSYNC2B_TYPED"] == "1" {
            drainTyped(seconds: 10, label: "connect")
            let t1 = Int64(Date().timeIntervalSince1970 * 1000)
            try ReadSync.livePut(chatID: chatID, name: "consumptionHorizonBookmark",
                                 body: ReadSync.body("consumptionHorizonBookmark",
                                                     ReadSync.bookmarkValue(arrivalMs: last, nowMs: t1, clientMessageID: nil)))
            drainTyped(seconds: 12, label: "after-mark-unread")
            let t2 = Int64(Date().timeIntervalSince1970 * 1000)
            try ReadSync.livePut(chatID: chatID, name: "consumptionhorizon",
                                 body: ReadSync.body("consumptionhorizon",
                                                     ReadSync.horizonValue(arrivalMs: last, nowMs: t2, clientMessageID: nil)))
            try ReadSync.livePut(chatID: chatID, name: "consumptionHorizonBookmark",
                                 body: ReadSync.body("consumptionHorizonBookmark", ReadSync.clearedBookmark(nowMs: t2)))
            drainTyped(seconds: 12, label: "after-mark-read")
            return
        }
        func drain(seconds: Double, label: String) {
            let deadline = Date().addingTimeInterval(seconds)
            var shapes: [String: Int] = [:]
            while Date() < deadline {
                guard let raw = ostmac_trouter_poll_wait(1000) else { continue }
                let s = String(cString: raw); ostmac_free(raw)
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
                      let events = obj["events"] as? [Any] else { continue }
                for e in events {
                    let text = (try? JSONSerialization.data(withJSONObject: e)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let types = ["ConversationUpdate", "ThreadUpdate", "NewMessage", "MessageUpdate",
                                 "EndpointPresence", "UserPresence", "trouter.connected", "message_loss"]
                        .filter { text.contains($0) }
                    let props = ["consumptionhorizon", "consumptionHorizonBookmark", "\\\"properties\\\"", "\"properties\""]
                        .filter { text.contains($0) }.map { $0.replacingOccurrences(of: "\\\"", with: "").replacingOccurrences(of: "\"", with: "") }
                    let forChat = text.contains(chatID)
                    if forChat, types.contains("ConversationUpdate"), env["CHATSYNC2B_SHAPE"] == "1" {
                        print("CHATSYNC2B shape " + Self.skeleton(e, depth: 0).joined(separator: " "))
                    }
                    shapes["types=\(types.joined(separator: "+")) props=\(Set(props).sorted().joined(separator: "+")) forTestChat=\(forChat)", default: 0] += 1
                }
            }
            print("CHATSYNC2B trouter \(label) frames:")
            for (k, n) in shapes.sorted(by: { $0.key < $1.key }) { print("CHATSYNC2B   \(n)x \(k)") }
        }
        drain(seconds: 12, label: "connect")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try ReadSync.livePut(chatID: chatID, name: "consumptionHorizonBookmark",
                             body: ReadSync.body("consumptionHorizonBookmark",
                                                 ReadSync.bookmarkValue(arrivalMs: last, nowMs: now, clientMessageID: nil)))
        drain(seconds: 15, label: "after-mark-unread")
        let now2 = Int64(Date().timeIntervalSince1970 * 1000)
        try ReadSync.livePut(chatID: chatID, name: "consumptionhorizon",
                             body: ReadSync.body("consumptionhorizon",
                                                 ReadSync.horizonValue(arrivalMs: last, nowMs: now2, clientMessageID: nil)))
        try ReadSync.livePut(chatID: chatID, name: "consumptionHorizonBookmark",
                             body: ReadSync.body("consumptionHorizonBookmark", ReadSync.clearedBookmark(nowMs: now2)))
        drain(seconds: 15, label: "after-mark-read")
    }
}

extension ChatSync2bLiveProbeTests {
    /// Key paths with value kinds only (no values; id-like keys masked).
    static func skeleton(_ v: Any, depth: Int, path: String = "") -> [String] {
        guard depth < 8 else { return ["\(path)=…"] }
        func mask(_ k: String) -> String { (k.contains("19:") || k.contains("@") || k.count > 40) ? "<id>" : k }
        switch v {
        case let d as [String: Any]:
            return d.keys.sorted().flatMap { skeleton(d[$0]!, depth: depth + 1, path: path + "." + mask($0)) }
        case let a as [Any]:
            return a.prefix(2).enumerated().flatMap { skeleton($0.element, depth: depth + 1, path: path + "[\($0.offset)]") }
        case let s as String:
            if s.hasPrefix("{"), let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) {
                return skeleton(o, depth: depth + 1, path: path + "<json>")
            }
            return ["\(path)=s\(s.count)"]
        case is NSNumber: return ["\(path)=n"]
        default: return ["\(path)=?"]
        }
    }
}
