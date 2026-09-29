// ContactCard2LiveProbeTests.swift — opt-in live proof (CONTACTCARD2_LIVE=1)
// of unified presence, profile photos, the card's calendar fields and
// the Activity feed through the app's own read paths. Read-only: GETs
// plus two read queries (getpresence, getSchedule) that change nothing.
// Never opens a chat, never marks anything read, never sets presence.
// Prints counts, status codes and key names only — never names, ids,
// message text, tokens or URLs. Photo cache goes to
// CONTACTCARD2_CACHE (a scratch dir), never the user's caches.
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import OstMacCore

/// Counts every network call against the lane cap.
private final class CountingFetcher: ReadFetcher, @unchecked Sendable {
    let inner: any ReadFetcher
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var last = Data()
    init(_ inner: any ReadFetcher) { self.inner = inner }
    func get(url: URL, headers: [String: String]) throws -> ReadHTTPResponse {
        let r = try inner.get(url: url, headers: headers)
        lock.lock(); count += 1; last = r.data; lock.unlock()
        return r
    }
}

private final class CountingAuthFetcher: TeamsAuthFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var last = Data()
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> AuthHTTPResponse {
        let r = try await URLSessionAuthFetcher().send(method: method, url: url, headers: headers, body: body)
        lock.lock(); count += 1; last = r.data; lock.unlock()
        return r
    }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var s: [String: Int] = [:]
    func set(_ k: String, _ v: Int) { lock.lock(); s[k] = v; lock.unlock() }
    func get(_ k: String) -> Int? { lock.lock(); defer { lock.unlock() }; return s[k] }
    var count: Int { lock.lock(); defer { lock.unlock() }; return s.count }
}

final class ContactCard2LiveProbeTests: XCTestCase {
    static var testUser: String { ProcessInfo.processInfo.environment["CONTACTCARD2_LIVE_PEER"] ?? "" }
    static let getCap = 20

    @MainActor
    func testLiveProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CONTACTCARD2_LIVE"] == "1", let cachePath = env["CONTACTCARD2_CACHE"],
              env["CONTACTCARD2_LIVE_PEER"] != nil else {
            throw XCTSkip("set CONTACTCARD2_LIVE=1, CONTACTCARD2_CACHE=<scratch dir> and CONTACTCARD2_LIVE_PEER=<mail> to run the live probe")
        }
        var net = 0
        func spend(_ n: Int = 1) throws {
            net += n
            if net > Self.getCap { throw XCTSkip("network cap reached") }
        }
        let base = try CoreReads.production()
        let http = CountingFetcher(base.http)
        let ctx = ReadContext(store: base.store, http: http, refresher: base.refresher, now: base.now)
        let profile = CoreLocal.activeProfileID()
        let graph = try CoreReads.graphToken(profile: profile, code: "probe", ctx: ctx)
        let own = UnifiedPresence.ownUserID() ?? (GraphTokenClaims.decode(graph)["oid"] as? String)
        print("PROBE own id known=\(own != nil)")

        // 1. Chat list (one page, chat service) → 1:1 peers from chat ids.
        let (skype, slots) = try CoreReads.skypeToken(profile: profile, code: "probe", ctx: ctx)
        try spend()
        let list = try CoreReads.chatGET(
            "\(CoreReads.chatServiceURL(slots))/v1/users/ME/conversations?view=mychats&pageSize=50",
            code: "probe", skype: skype, http: http)
        let convs = ((try? JSONSerialization.jsonObject(with: list)) as? [String: Any])?["conversations"] as? [[String: Any]] ?? []
        let chatIDs = convs.compactMap { $0["id"] as? String }
        var peers: [String] = []
        for c in chatIDs {
            if let p = UnifiedPresence.peerUserID(chatID: c, ownUserID: own), !peers.contains(p) { peers.append(p) }
        }
        print("PROBE chats=\(chatIDs.count) oneOnOnePeers=\(peers.count)")

        // 2. Activity feed through the app's read + parser.
        try spend()
        let items = try CoreReads.activityFeed(profile: profile, ctx: ctx)
        let raw = http.last
        let msgs = ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        var typeCounts: [String: Int] = [:]
        var withActivity = 0
        for m in msgs {
            let props = m["properties"] as? [String: Any] ?? [:]
            guard let act = ChatListSeed.object(props["activity"]) else { continue }
            withActivity += 1
            let t = (act["activityType"] as? String) ?? "?"
            let sub = (act["activitySubtype"] as? String).map { "/" + $0 } ?? ""
            typeCounts[t + sub, default: 0] += 1
        }
        var kindCounts: [String: Int] = [:]
        for i in items { kindCounts["\(i.kind)", default: 0] += 1 }
        print("PROBE activity raw=\(msgs.count) withActivity=\(withActivity) parsed=\(items.count) unread=\(items.filter { !$0.reviewed }.count)")
        print("PROBE activity kinds=\(kindCounts.sorted { $0.key < $1.key })")
        print("PROBE activity types=\(typeCounts.sorted { $0.key < $1.key })")
        for (t, n) in typeCounts.sorted(by: { $0.key < $1.key }) {
            let parts = t.split(separator: "/", maxSplits: 1).map(String.init)
            print("PROBE activity type \(t) n=\(n) → \(ActivityFeed.kind(type: parts[0], subtype: parts.count > 1 ? parts[1] : nil))")
        }
        let keyNames = Set(msgs.compactMap { m -> [String]? in
            ChatListSeed.object((m["properties"] as? [String: Any])?["activity"]).map { Array($0.keys) }
        }.flatMap { $0 })
        print("PROBE activity keys=\(keyNames.sorted().joined(separator: ","))")
        let dropped = msgs.compactMap { m -> String? in
            guard let act = ChatListSeed.object((m["properties"] as? [String: Any])?["activity"]) else { return nil }
            let chat = (act["sourceThreadId"] as? String) ?? ""
            let src = (act["sourceMessageId"] as? String) ?? ((act["sourceMessageId"] as? NSNumber)?.stringValue ?? "")
            let aid = (act["activityId"] as? String) ?? ((act["activityId"] as? NSNumber)?.stringValue ?? "")
            return "\(act["activityType"] as? String ?? "?") chat=\(!chat.isEmpty) src=\(!src.isEmpty && src != "0") aid=\(!aid.isEmpty)"
        }
        print("PROBE activity shapes=\(Dictionary(grouping: dropped, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key })")

        // 3. Test user profile (Graph).
        try spend()
        let tuData = try? CoreReads.graphGET(ContactReads.userPath(Self.testUser) + "?$select=" + ContactReads.profileSelect,
                                             code: "probe", token: graph, http: http)
        let tu = tuData.flatMap { try? ContactReads.parseProfile($0) }
        print("PROBE testUser profile ok=\(tu != nil) fields=\(tuData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }.map { $0.filter { !($0.value is NSNull) && !$0.key.hasPrefix("@") }.keys.sorted().joined(separator: ",") } ?? "-")")

        // 4. Presence: one unified batch (own + peers + test user).
        var ids = [own].compactMap { $0 } + Array(peers.prefix(25))
        if let id = tu?.id { ids.append(id) }
        let auth = CountingAuthFetcher()
        try spend()
        let presence = try await UnifiedPresence.fetch(ids: ids, fetcher: auth)
        let rawPresence = (try? JSONSerialization.jsonObject(with: auth.last)) as? [[String: Any]] ?? []
        let pKeys = Set(rawPresence.compactMap { ($0["presence"] as? [String: Any]).map { Array($0.keys) } }.flatMap { $0 })
        let calKeys = Set(rawPresence.compactMap { (($0["presence"] as? [String: Any])?["calendarData"] as? [String: Any]).map { Array($0.keys) } }.flatMap { $0 })
        print("PROBE presence requests=\(auth.count) asked=\(ids.count) answered=\(presence.count)")
        print("PROBE presence keys=\(pKeys.sorted().joined(separator: ",")) calendarData=\(calKeys.sorted().joined(separator: ","))")
        var hist: [String: Int] = [:]
        for p in presence.values { hist[p.availability, default: 0] += 1 }
        print("PROBE presence availability=\(hist.sorted { $0.key < $1.key })")
        let known = presence.values.filter { $0.availability != "PresenceUnknown" }.count
        print("PROBE presence nonUnknown=\(known) notes=\(presence.values.filter { $0.statusMessage != nil }.count) ooo=\(presence.values.filter(\.outOfOffice).count) oooNotes=\(presence.values.filter { $0.outOfOfficeNote != nil }.count)")
        if let own { print("PROBE presence own=\(presence[own]?.availability ?? "missing")/\(presence[own]?.activity ?? "-")") }
        if let id = tu?.id { print("PROBE presence testUser=\(presence[id]?.availability ?? "missing")") }

        // 5. Photos through the app's photo store (live Graph fetcher,
        // scratch cache): stop after two photos.
        let cache = URL(fileURLWithPath: cachePath).appendingPathComponent("photos")
        let statuses = StatusBox()
        let store = ProfilePhotoStore(directory: ContactDirectory(), cacheDir: cache) { key, etag in
            let r = try GraphPhotoFetcher.fetch(userKey: key, etag: etag)
            statuses.set(key.lowercased(), r.status)
            return r
        }
        var photoTargets = Array(peers.prefix(7))
        if let id = tu?.id { photoTargets.insert(id, at: 0) }
        var withPhoto: [String] = []
        var tried = 0
        for id in photoTargets where withPhoto.count < 2 || id == tu?.id {
            guard net < Self.getCap else { break }
            try spend()
            tried += 1
            let ref = ContactRef(name: "Person", userID: id, email: nil)
            let slot = store.slot(for: ref)
            store.request(ref)
            let deadline = Date().addingTimeInterval(10)
            while statuses.get(id.lowercased()) == nil || (statuses.get(id.lowercased()) == 200 && slot.image == nil),
                  Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let status = statuses.get(id.lowercased()) ?? 0
            print("PROBE photo \(id == tu?.id ? "testUser" : "peer\(tried)") status=\(status) image=\(slot.image != nil)")
            if status == 200, slot.image != nil, id != tu?.id { withPhoto.append(id) }
        }
        print("PROBE photo 200s=\(withPhoto.count) of \(tried)")
        // Fresh store on the same cache: first render has the photo, no network.
        let reread = ProfilePhotoStore(directory: ContactDirectory(), cacheDir: cache) { _, _ in
            XCTFail("a fresh cache must not refetch"); return PhotoFetchResult(status: 500)
        }
        for (i, id) in withPhoto.enumerated() {
            let ref = ContactRef(name: "Person", userID: id, email: nil)
            let slot = reread.slot(for: ref)
            reread.request(ref)
            var opaque = 0
            if let img = slot.image {
                let renderer = ImageRenderer(content: Image(nsImage: img).resizable().frame(width: 40, height: 40)
                    .clipShape(Circle()))
                renderer.scale = 2
                if let cg = renderer.cgImage, let data = cg.dataProvider?.data as Data? {
                    let bpp = cg.bitsPerPixel / 8
                    for p in stride(from: 0, to: data.count - bpp, by: bpp) where data[p + (bpp - 1)] > 0 { opaque += 1 }
                }
            }
            print("PROBE photo cached\(i + 1) firstRender=\(slot.image != nil) renderedOpaquePixels=\(opaque)")
        }

        // 6. Card fields: one getSchedule for up to 3 people, files for one.
        var mails: [String] = []
        if let m = tu?.email { mails.append(m) }
        let lookup = Array(peers.prefix(4))
        if !lookup.isEmpty, net < Self.getCap {
            try spend()
            let filter = "id in (" + lookup.map { "'\($0)'" }.joined(separator: ",") + ")"
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+'$")
            let path = "/users?$filter=\(filter.addingPercentEncoding(withAllowedCharacters: allowed) ?? filter)&$select=id,mail,userPrincipalName"
            if let data = try? CoreReads.graphGET(path, code: "probe", token: graph, http: http),
               let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["value"] as? [[String: Any]] {
                for r in rows { if let m = (r["mail"] as? String)?.nonBlank { mails.append(m) } }
            }
        }
        mails = Array(mails.prefix(4))
        if !mails.isEmpty, net < Self.getCap {
            try spend()
            let now = Date()
            let one = try JSONSerialization.jsonObject(with: ContactExtrasReads.scheduleBody(mail: mails[0], now: now)) as? [String: Any] ?? [:]
            var body = one
            body["schedules"] = mails
            let resp = try ContactExtrasReads.livePoster(
                URL(string: CoreReads.graphBase + ContactExtrasReads.schedulePath)!,
                ["Authorization": "Bearer \(graph)", "Content-Type": "application/json", "Prefer": "outlook.timezone=\"UTC\""],
                try JSONSerialization.data(withJSONObject: body))
            let values = ((try? JSONSerialization.jsonObject(with: resp.data)) as? [String: Any])?["value"] as? [[String: Any]] ?? []
            var zones = 0, parsed = 0, busy = 0
            var states: [String: Int] = [:]
            for v in values {
                let wrapped = try JSONSerialization.data(withJSONObject: ["value": [v]])
                if let s = ContactExtrasReads.parseSchedule(wrapped, now: now) {
                    parsed += 1
                    if s.timeZone != nil { zones += 1 }
                    if s.state != .free { busy += 1 }
                    states[s.state.rawValue, default: 0] += 1
                }
            }
            print("PROBE schedule status=\(resp.status) asked=\(mails.count) parsed=\(parsed) zonesMapped=\(zones) notFree=\(busy) states=\(states.sorted { $0.key < $1.key })")
        }
        if let mail = mails.first, net < Self.getCap {
            try spend()
            do {
                let data = try CoreReads.graphGET(ContactExtrasReads.filesPath(sharedBy: mail), code: "probe", token: graph, http: http)
                print("PROBE files status=200 count=\(ContactExtrasReads.parseFiles(data).count)")
            } catch CoreCallError.failed(let m) {
                let code = m.range(of: "HTTP [0-9]+", options: .regularExpression).map { String(m[$0]) } ?? "error"
                print("PROBE files \(code)")
            }
        }
        print("PROBE network calls=\(net) (graph/chat GETs counted=\(http.count), presence POSTs=\(auth.count))")
    }

    /// Per-person cross-check (CONTACTCARD2_LIVE2=1): presence vs the
    /// same people's calendar right now. 3 calls: id→mail lookup,
    /// getSchedule, getpresence. Prints agreement counts only.
    @MainActor
    func testLivePresenceAgreesWithCalendar() async throws {
        guard ProcessInfo.processInfo.environment["CONTACTCARD2_LIVE2"] == "1" else {
            throw XCTSkip("set CONTACTCARD2_LIVE2=1 to run the presence/calendar cross-check")
        }
        let ctx = try CoreReads.production()
        let profile = CoreLocal.activeProfileID()
        let graph = try CoreReads.graphToken(profile: profile, code: "probe", ctx: ctx)
        let own = UnifiedPresence.ownUserID()
        // Peers from the locally cached chat list would need the app's
        // defaults; reuse the chat service page (1 GET) instead.
        let (skype, slots) = try CoreReads.skypeToken(profile: profile, code: "probe", ctx: ctx)
        let list = try CoreReads.chatGET(
            "\(CoreReads.chatServiceURL(slots))/v1/users/ME/conversations?view=mychats&pageSize=50",
            code: "probe", skype: skype, http: ctx.http)
        let convs = ((try? JSONSerialization.jsonObject(with: list)) as? [String: Any])?["conversations"] as? [[String: Any]] ?? []
        var peers: [String] = []
        for c in convs.compactMap({ $0["id"] as? String }) {
            if let p = UnifiedPresence.peerUserID(chatID: c, ownUserID: own), !peers.contains(p) { peers.append(p) }
        }
        let lookup = Array(peers.prefix(8))
        let filter = "id in (" + lookup.map { "'\($0)'" }.joined(separator: ",") + ")"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+'$")
        let path = "/users?$filter=\(filter.addingPercentEncoding(withAllowedCharacters: allowed) ?? filter)&$select=id,mail"
        let rows = ((try? JSONSerialization.jsonObject(with: try CoreReads.graphGET(path, code: "probe", token: graph, http: ctx.http)))
            as? [String: Any])?["value"] as? [[String: Any]] ?? []
        var mailByID: [String: String] = [:]
        for r in rows { if let id = r["id"] as? String, let m = (r["mail"] as? String)?.nonBlank { mailByID[id.lowercased()] = m } }
        let ids = lookup.filter { mailByID[$0] != nil }
        let now = Date()
        var body = try JSONSerialization.jsonObject(with: ContactExtrasReads.scheduleBody(mail: "x", now: now)) as? [String: Any] ?? [:]
        body["schedules"] = ids.compactMap { mailByID[$0] }
        let resp = try ContactExtrasReads.livePoster(
            URL(string: CoreReads.graphBase + ContactExtrasReads.schedulePath)!,
            ["Authorization": "Bearer \(graph)", "Content-Type": "application/json", "Prefer": "outlook.timezone=\"UTC\""],
            try JSONSerialization.data(withJSONObject: body))
        let values = ((try? JSONSerialization.jsonObject(with: resp.data)) as? [String: Any])?["value"] as? [[String: Any]] ?? []
        let presence = try await UnifiedPresence.fetch(ids: ids)
        var agree = 0, disagree = 0, calBusyPresBusy = 0, calFreePresFree = 0, unknown = 0
        for (i, id) in ids.enumerated() where i < values.count {
            let wrapped = try JSONSerialization.data(withJSONObject: ["value": [values[i]]])
            guard let cal = ContactExtrasReads.parseSchedule(wrapped, now: now), let p = presence[id] else { unknown += 1; continue }
            let presBusy = ["Busy", "DoNotDisturb"].contains(p.availability)
                || ["InAMeeting", "InACall", "InAConferenceCall", "Presenting"].contains(p.activity)
            let calBusy = cal.state == .busy || cal.state == .outOfOffice
            let offline = p.availability == "Offline" || p.availability == "Away" || p.availability == "BeRightBack"
            // A meeting on the calendar shows as Busy/In a meeting unless the
            // person is offline/away; a free calendar can still be Busy (calls, manual).
            if calBusy && (presBusy || offline) { agree += 1; if presBusy { calBusyPresBusy += 1 } }
            else if !calBusy && !(p.activity == "InAMeeting") { agree += 1; if !presBusy { calFreePresFree += 1 } }
            else { disagree += 1 }
        }
        print("PROBE2 people=\(ids.count) scheduleStatus=\(resp.status) agree=\(agree) disagree=\(disagree) unknown=\(unknown) calBusy&presBusy=\(calBusyPresBusy) calFree&presNotBusy=\(calFreePresFree)")
    }

    /// Parity probe (CONTACTCARD2_LIVE3=1): which contact-card fields a
    /// colleague's record returns and the status of each wider read the
    /// Teams card uses. 5 calls: manager projection, profile-tab fields,
    /// people-worked-with, LinkedIn lookup (Loki), one presence batch.
    /// Prints status codes, error codes and key names only.
    @MainActor
    func testLiveParityProbe() async throws {
        guard ProcessInfo.processInfo.environment["CONTACTCARD2_LIVE3"] == "1" else {
            throw XCTSkip("set CONTACTCARD2_LIVE3=1 to run the parity probe")
        }
        let ctx = try CoreReads.production()
        let profile = CoreLocal.activeProfileID()
        let graph = try CoreReads.graphToken(profile: profile, code: "probe", ctx: ctx)
        func keys(_ d: Data) -> String {
            guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return "-" }
            return o.filter { !($0.value is NSNull) && !$0.key.hasPrefix("@") }
                .filter { ($0.value as? [Any])?.isEmpty != true && ($0.value as? String)?.isEmpty != true }
                .keys.sorted().joined(separator: ",")
        }
        func errorCode(_ d: Data) -> String {
            let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            return ((o?["error"] as? [String: Any])?["code"] as? String) ?? (o?["error"] as? String) ?? "-"
        }
        func get(_ url: String, _ token: String, _ extra: [String: String] = [:]) throws -> ReadHTTPResponse {
            var h = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
            for (k, v) in extra { h[k] = v }
            return try ctx.http.get(url: URL(string: url)!, headers: h)
        }
        let wide = ContactReads.profileSelect + ",imAddresses,streetAddress,postalCode,employeeId,preferredLanguage,faxNumber"
        // 1. A colleague (own manager) with the card projection + extras.
        let m = try get(CoreReads.graphBase + "/me/manager?$select=" + wide, graph)
        print("PARITY manager status=\(m.status) fields=\(keys(m.data)) err=\(errorCode(m.data))")
        guard let id = ((try? JSONSerialization.jsonObject(with: m.data)) as? [String: Any])?["id"] as? String else { return }
        let mail = ((try? JSONSerialization.jsonObject(with: m.data)) as? [String: Any])?["mail"] as? String
        // 2. Profile-tab fields (SharePoint user profile via Graph).
        let p = try get(CoreReads.graphBase + "/users/\(id)?$select=aboutMe,skills,interests,schools,pastProjects,responsibilities,birthday,hireDate", graph)
        print("PARITY profileTab status=\(p.status) fields=\(keys(p.data)) err=\(errorCode(p.data))")
        // 3. Works with (people ranked around that person).
        let w = try get(CoreReads.graphBase + "/users/\(id)/people?$top=5&$select=id", graph)
        print("PARITY worksWith status=\(w.status) err=\(errorCode(w.data))")
        // 4. LinkedIn tab: the persona card service (Loki).
        switch await TeamsAppService.token(profile: profile, scopes: "https://loki.delve.office.com") {
        case .failure(let e):
            let text = String(describing: e)
            let code = text.range(of: #"AADSTS\d+"#, options: .regularExpression).map { String(text[$0]) } ?? "no AADSTS code"
            print("PARITY loki token failed code=\(code)")
        case .success(let t):
            var q = URLComponents(string: "https://nam.loki.delve.office.com/api/v1/linkedin/profiles/full")!
            q.queryItems = [URLQueryItem(name: "AadObjectId", value: id), URLQueryItem(name: "Smtp", value: mail ?? ""),
                            URLQueryItem(name: "PersonaType", value: "User"), URLQueryItem(name: "UserLocale", value: "en-US"),
                            URLQueryItem(name: "ExternalPageInstance", value: UUID().uuidString)]
            let l = try get(q.url!.absoluteString, t.token, ["X-ClientType": "Teams", "X-ClientFeature": "LivePersonaCard"])
            print("PARITY loki linkedin status=\(l.status) keys=\(keys(l.data)) err=\(errorCode(l.data))")
        }
        // 5. Work location shape in unified presence (colleague + self).
        let auth = CountingAuthFetcher()
        _ = try await UnifiedPresence.fetch(ids: [id] + [UnifiedPresence.ownUserID()].compactMap { $0 }, fetcher: auth)
        let rows = (try? JSONSerialization.jsonObject(with: auth.last)) as? [[String: Any]] ?? []
        for r in rows {
            let wl = (r["presence"] as? [String: Any])?["workLocation"]
            if let d = wl as? [String: Any] {
                let shape = d.map { k, v -> String in
                    if let n = v as? NSNumber { return "\(k)=\(n)" }
                    if let s = v as? String, s.count <= 12, s.allSatisfy(\.isLetter) { return "\(k)=\(s)" }
                    return "\(k):\(type(of: v))"
                }.sorted()
                print("PARITY workLocation \(shape.joined(separator: ","))")
            } else {
                print("PARITY workLocation type=\(wl.map { "\(type(of: $0))" } ?? "absent")")
            }
        }
    }

    /// Works-with probe (CONTACTCARD2_LIVE4=1): one GET of the persona
    /// card service's person record (Loki v2) for the signed-in user, to
    /// see whether it carries the "works with" list Graph /people denies.
    /// Prints status and key names (two levels) only.
    @MainActor
    func testLiveWorksWithProbe() async throws {
        guard ProcessInfo.processInfo.environment["CONTACTCARD2_LIVE4"] == "1" else {
            throw XCTSkip("set CONTACTCARD2_LIVE4=1 to run the works-with probe")
        }
        let profile = CoreLocal.activeProfileID()
        let me = try RustCore.appIdentity(profile: profile)
        guard case .success(let t) = await TeamsAppService.token(profile: profile, scopes: "https://loki.delve.office.com")
        else { print("WORKSWITH loki token failed"); return }
        var q = URLComponents(string: "https://nam.loki.delve.office.com/api/v2/person")!
        q.queryItems = [URLQueryItem(name: "aadObjectId", value: me.userObjectId), URLQueryItem(name: "smtp", value: me.upn),
                        URLQueryItem(name: "personaType", value: "User"), URLQueryItem(name: "ConvertGetPost", value: "true"),
                        URLQueryItem(name: "ExternalPageInstance", value: UUID().uuidString)]
        let h = ["Authorization": "Bearer \(t.token)", "Accept": "application/json",
                 "X-ClientType": "Teams", "X-ClientFeature": "LivePersonaCard"]
        let r = try CoreReads.production().http.get(url: q.url!, headers: h)
        let o = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any] ?? [:]
        var shape: [String] = []
        for (k, v) in o.sorted(by: { $0.key < $1.key }) {
            if let d = v as? [String: Any] { shape.append(k + "{" + d.keys.sorted().joined(separator: ",") + "}") }
            else if let a = v as? [Any] { shape.append(k + "[\(a.count)]") }
            else { shape.append(k) }
        }
        print("WORKSWITH loki v2 person status=\(r.status) bytes=\(r.data.count) shape=\(shape.joined(separator: " "))")
    }
}
