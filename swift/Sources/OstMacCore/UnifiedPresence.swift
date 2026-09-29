// UnifiedPresence.swift — presence from the Teams unified presence
// service (the source the Teams web client reads).
//
// Graph `/me/presence` and `/users/{id}/presence` need Presence.Read(.All),
// which the Teams client token does not carry in managed tenants (403).
// The unified presence service takes a token for its own audience,
// minted from the stored Teams refresh token by the app's token broker:
//
//   POST https://presence.teams.microsoft.com/v1/presence/getpresence/
//   [{"mri":"8:orgid:<oid>"}, …]
//   → [{"mri":…, "presence":{"availability","activity",
//        "note":{"message","expiry"},
//        "calendarData":{"isOutOfOffice","outOfOfficeNote":{"message"}}}}, …]
//
// The request is a read: it changes no presence, subscription or
// read state. One batch covers own + every watched person.
//
//   let map = try await UnifiedPresence.fetch(ids: [...])   // keyed by user id
//
// Threading: pure helpers + one async fetch; callers own the store.
import Foundation

public enum UnifiedPresence {
    /// Token audience (the broker appends `/.default`).
    public static let resource = "https://presence.teams.microsoft.com"
    public static let endpoint = "https://presence.teams.microsoft.com/v1/presence/getpresence/"
    /// Max MRIs per request.
    public static let batchSize = 50

    // MARK: ids

    /// `8:orgid:<oid>` for an Entra object id; nil for UPNs, emails and
    /// anything else the service can't key on without a directory hop.
    public static func mri(forUserID id: String) -> String? {
        let s = id.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("8:orgid:") { return Mri.oid(from: s).map { "8:orgid:" + $0.lowercased() } }
        guard isObjectID(s) else { return nil }
        return "8:orgid:" + s.lowercased()
    }

    /// Entra object id shape (36-char GUID).
    public static func isObjectID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        for (i, ch) in s.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if ch != "-" { return false }
            } else if !ch.isHexDigit {
                return false
            }
        }
        return true
    }

    /// The other person's object id in a 1:1 chat id
    /// (`19:<oidA>_<oidB>@unq.gbl.spaces`); nil for groups, bots, self
    /// chats and anything that isn't two object ids.
    public static func peerUserID(chatID: String, ownUserID: String?) -> String? {
        guard chatID.hasPrefix("19:"), chatID.hasSuffix("@unq.gbl.spaces"), let own = ownUserID?.lowercased(),
              !own.isEmpty
        else { return nil }
        let core = chatID.dropFirst(3).dropLast("@unq.gbl.spaces".count)
        let parts = core.split(separator: "_").map { String($0).lowercased() }
        guard parts.count == 2, parts.allSatisfy(isObjectID), parts.contains(own) else { return nil }
        let other = parts[0] == own ? parts[1] : parts[0]
        return other == own ? nil : other
    }

    // MARK: wire

    /// Request body for a batch of MRIs.
    public static func requestBody(mris: [String]) -> Data {
        let arr = mris.map { ["mri": $0] }
        return (try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])) ?? Data("[]".utf8)
    }

    /// Parse one getpresence reply → presence by lowercased object id.
    /// Entries without an availability are skipped (not "unknown").
    public static func parse(_ data: Data, now: Date = Date()) -> [String: ContactPresence] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var out: [String: ContactPresence] = [:]
        for entry in arr {
            guard let mri = entry["mri"] as? String, let oid = Mri.oid(from: mri)?.lowercased(),
                  let p = entry["presence"] as? [String: Any],
                  let availability = (p["availability"] as? String)?.nonBlank
            else { continue }
            let activity = (p["activity"] as? String)?.nonBlank ?? availability
            let cal = p["calendarData"] as? [String: Any]
            let ooo = (cal?["isOutOfOffice"] as? Bool) ?? false
            let oofNote = liveNote(cal?["outOfOfficeNote"], now: now)
            let note = liveNote(p["note"], now: now)
            out[oid] = ContactPresence(availability: availability, activity: activity, statusMessage: note,
                                       outOfOffice: ooo, outOfOfficeNote: ooo ? oofNote : nil)
        }
        return out
    }

    /// A note object's plain text, nil when blank or past its expiry.
    static func liveNote(_ raw: Any?, now: Date) -> String? {
        guard let obj = raw as? [String: Any],
              let text = (obj["message"] as? String).map(ContactReads.plainText)?.nonBlank
        else { return nil }
        if let exp = obj["expiry"] as? String, let d = isoDate(exp), d < now { return nil }
        return text
    }

    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        return ContactReads.graphDate(s.hasSuffix("Z") ? String(s.dropLast()) : s)
    }

    // MARK: fetch

    /// Token source (audience = `resource`). Production: the app's
    /// token broker on the stored Teams refresh token.
    public typealias TokenSource = @Sendable () async throws -> String

    public static let liveToken: TokenSource = {
        switch await TeamsAppService.token(profile: CoreLocal.activeProfileID(), scopes: resource) {
        case .success(let t): return t.token
        case .failure(let e): throw e
        }
    }

    /// Presence for `ids` (object ids or orgid MRIs), keyed by the id
    /// as given. Ids the service can't key on are omitted.
    public static func fetch(ids: [String], token: TokenSource = liveToken,
                             fetcher: any TeamsAuthFetcher = URLSessionAuthFetcher(),
                             now: Date = Date()) async throws -> [String: ContactPresence] {
        var byMri: [String: [String]] = [:]
        var order: [String] = []
        for id in ids {
            guard let m = mri(forUserID: id) else { continue }
            if byMri[m] == nil { order.append(m) }
            byMri[m, default: []].append(id)
        }
        guard !order.isEmpty, let url = URL(string: endpoint) else { return [:] }
        let bearer = try await token()
        var out: [String: ContactPresence] = [:]
        var start = 0
        while start < order.count {
            let chunk = Array(order[start..<min(order.count, start + batchSize)])
            start += batchSize
            let resp = try await fetcher.send(
                method: "POST", url: url,
                headers: ["Authorization": "Bearer \(bearer)", "Content-Type": "application/json"],
                body: requestBody(mris: chunk))
            guard (200..<300).contains(resp.status) else {
                throw CoreCallError.failed("presence: HTTP \(resp.status)")
            }
            for (oid, p) in parse(resp.data, now: now) {
                for id in byMri["8:orgid:" + oid] ?? [] { out[id] = p }
            }
        }
        return out
    }

    /// Own object id from the stored token claims (no network).
    public static func ownUserID() -> String? {
        TeamsAppService.identity(profile: CoreLocal.activeProfileID())?.userObjectId.nonBlank
    }
}

extension ContactPresence {
    /// Wire shape for the app's presence dots.
    func userResponse(id: String) -> UserPresenceResponse {
        UserPresenceResponse(ok: true, id: id, availability: availability, activity: activity,
                             statusMessage: statusMessage, outOfOffice: outOfOffice,
                             outOfOfficeNote: outOfOfficeNote)
    }
}

extension UnifiedPresence {
    /// Live batch for `PresenceStore.batchFetcher`.
    public static let liveBatch: PresenceStore.BatchFetcher = { ids in
        var out: [String: UserPresenceResponse] = [:]
        for (id, p) in try await fetch(ids: ids) { out[id] = p.userResponse(id: id) }
        return out
    }
}

// MARK: own status + single reads (GRAPHSWEEP)
//
// Graph `setUserPreferredPresence` needs Presence.ReadWrite and Graph
// `/me/presence` / `/users/{id}/presence` need Presence.Read(.All); the
// Teams web token carries none of them (live 403). The Teams web client
// sets a status on its presence service instead:
//
//   PUT https://presence.teams.microsoft.com/v1/me/forceavailability/
//   {"availability":"Busy"}
//
// Same token audience as `getpresence`. Single reads reuse `fetch`.
extension UnifiedPresence {
    public static let forceAvailabilityEndpoint = "https://presence.teams.microsoft.com/v1/me/forceavailability/"

    /// Picker status (`PresenceStatus.rawValue`, case-insensitive, plus
    /// the long spellings) → (service availability, echoed activity).
    /// Nil for anything else (rejected before any network).
    public static func forcedStatus(_ status: String) -> (availability: String, activity: String)? {
        switch status.trimmingCharacters(in: .whitespaces).lowercased() {
        case "available": ("Available", "Available")
        case "busy": ("Busy", "Busy")
        case "dnd", "donotdisturb": ("DoNotDisturb", "DoNotDisturb")
        case "brb", "berightback": ("BeRightBack", "BeRightBack")
        case "away": ("Away", "Away")
        case "offline": ("Offline", "OffWork")
        default: nil
        }
    }

    /// `forceavailability` request body.
    public static func forceBody(availability: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["availability": availability], options: [.sortedKeys])) ?? Data()
    }

    /// Set the signed-in user's status on the Teams presence service.
    /// Returns the applied status; unknown statuses and non-2xx answers
    /// throw (the picker keeps its previous value and shows the error).
    public static func setOwn(status: String, token: TokenSource = liveToken,
                              fetcher: any TeamsAuthFetcher = URLSessionAuthFetcher()) async throws -> PresenceResponse {
        guard let pair = forcedStatus(status) else {
            throw CoreCallError.failed(
                "presence_set: Unknown status: \(status). Use: available, busy, dnd, brb, away, offline")
        }
        let (availability, activity) = pair
        guard let url = URL(string: forceAvailabilityEndpoint) else {
            throw CoreCallError.failed("presence_set: bad endpoint")
        }
        let bearer = try await token()
        let resp = try await fetcher.send(
            method: "PUT", url: url,
            headers: ["Authorization": "Bearer \(bearer)", "Content-Type": "application/json"],
            body: forceBody(availability: availability))
        guard (200..<300).contains(resp.status) else {
            throw CoreCallError.failed("presence_set: HTTP \(resp.status)")
        }
        return PresenceResponse(ok: true, availability: availability, activity: activity)
    }

    /// One user's presence (object id or orgid MRI). Ids the service
    /// can't key on (UPNs, emails) and missing answers throw — a failed
    /// read is never reported as a status.
    public static func one(id: String, token: TokenSource = liveToken,
                           fetcher: any TeamsAuthFetcher = URLSessionAuthFetcher(),
                           now: Date = Date()) async throws -> UserPresenceResponse {
        guard mri(forUserID: id) != nil else {
            throw CoreCallError.failed("presence: \(id.isEmpty ? "empty id" : "not an object id")")
        }
        guard let p = try await fetch(ids: [id], token: token, fetcher: fetcher, now: now)[id] else {
            throw CoreCallError.failed("presence: no presence returned")
        }
        return p.userResponse(id: id)
    }

    /// The signed-in user's own presence (object id from token claims).
    public static func own(ownID: String? = ownUserID(), token: TokenSource = liveToken,
                           fetcher: any TeamsAuthFetcher = URLSessionAuthFetcher()) async throws -> PresenceResponse {
        guard let ownID else { throw CoreCallError.failed("presence: not signed in") }
        let u = try await one(id: ownID, token: token, fetcher: fetcher)
        return PresenceResponse(ok: true, availability: u.availability, activity: u.activity,
                                statusMessage: u.statusMessage, outOfOffice: u.outOfOffice,
                                outOfOfficeNote: u.outOfOfficeNote)
    }
}
