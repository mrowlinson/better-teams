// CalendarMeetingOptions.swift — CAL-SCOPE R0/R1: Teams meeting options
// (lobby bypass + who can present) over the Teams middle tier.
//
// Graph cannot do this: lobby/presenter live on the `onlineMeeting`
// resource (`PATCH /me/onlineMeetings/{id}` needs OnlineMeetings.ReadWrite,
// absent from the Teams token's 35 scopes — allowlist `blocked`). The Teams
// web client itself never uses Graph here: its meeting-options surface
// (meetingOptionsModel) reads/writes the middle tier with the organizer's
// own tokens (Bearer AAD + X-Skypetoken, region `middleTier` base):
//   GET/POST {mt}/beta/meetings/v1/options/{tenant}/{organizer}/{thread}/{message}
// mined from the current web client (worker `updateMeetingOptions` /
// `getMeetingOptions`, config `middleTierEndpoint
// "beta/meetings/v1/options"`). Same auth shape as `mt_request` (Rust) and
// `MessagingPolicyReader` (Swift).
import Foundation

/// Middle-tier coordinates of one scheduled Teams meeting.
public struct MeetingCoordinates: Sendable, Equatable {
    public var tenantID: String
    public var organizerID: String
    public var threadID: String
    public var messageID: String

    public init(tenantID: String, organizerID: String, threadID: String, messageID: String = "0") {
        self.tenantID = tenantID
        self.organizerID = organizerID
        self.threadID = threadID
        self.messageID = messageID
    }

    /// Coordinates from a Teams join URL (`…/meetup-join/<thread>/<msg>…`
    /// + `context={"Tid":…,"Oid":…}`); nil when the URL carries no thread.
    public static func fromJoinURL(_ raw: String) -> MeetingCoordinates? {
        var s = raw
        for _ in 0 ..< 3 {
            let d = (s.removingPercentEncoding ?? s)
            if d == s { break }
            s = d
        }
        guard let r = s.range(of: "meetup-join/", options: .caseInsensitive) else { return nil }
        let parts = s[r.upperBound...].split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 1, !parts[0].isEmpty else { return nil }
        let thread = String(parts[0])
        guard thread.contains("@thread.") || thread.hasPrefix("19_meeting_") || thread.hasPrefix("19:meeting_") else { return nil }
        var message = "0"
        if parts.count >= 2 {
            let m = parts[1].prefix { $0.isASCII && $0.isNumber }
            if !m.isEmpty { message = String(m) }
        }
        func field(_ key: String) -> String? {
            let pattern = "\"\(key)\"\\s*:\\s*\"([0-9A-Fa-f-]{8,64})\""
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
        guard let tid = field("Tid"), let oid = field("Oid") else { return nil }
        return MeetingCoordinates(tenantID: tid, organizerID: oid, threadID: thread, messageID: message)
    }
}

/// Human labels for the lobby bypass picker (native menu order).
public enum MeetingLobbyLabel {
    public static func label(_ v: MeetingLobbyBypass) -> String {
        switch v {
        case .organizerOnly: return "Only me"
        case .invited: return "Invited users"
        case .everyone: return "Everyone"
        case .company: return "People in my organization"
        case .companyFederated: return "My organization and trusted organizations"
        case .companyNoGuests: return "My organization except guests"
        }
    }

    public static func label(_ v: MeetingPresenters) -> String {
        switch v {
        case .everyone: return "Everyone"
        case .company: return "People in my organization"
        case .organizerOnly: return "Only me"
        case .specific: return "Specific people"
        }
    }
}

/// Who can bypass the lobby (`AutoAdmittedUsersOption` values, worker enum).
public enum MeetingLobbyBypass: String, Sendable, CaseIterable {
    case organizerOnly = "OrganizerOnly"
    case invited = "InvitedUsers"
    case everyone = "Everyone"
    case company = "EveryoneInCompany"
    case companyFederated = "EveryoneInSameAndFederatedCompany"
    case companyNoGuests = "EveryoneInCompanyExcludingGuests"
}

/// Who can present (`WhoCanPresentOption` values, worker enum).
public enum MeetingPresenters: String, Sendable, CaseIterable {
    case everyone = "Everyone"
    case company = "EveryoneInCompany"
    case organizerOnly = "OrganizerOnly"
    case specific = "SpecifiedPeople"
}

/// One meeting option row (GET reply / POST body item).
public struct MeetingOptionRow: Sendable, Equatable {
    public var name: String
    public var type: String
    public var currentValue: String
    /// Grouping bucket (`ROLES`, `PARTICIPATION`, …); the web client sends
    /// it back on save, so the POST keeps it.
    public var category: String?

    public init(name: String, type: String, currentValue: String, category: String? = nil) {
        self.name = name
        self.type = type
        self.currentValue = currentValue
        self.category = category
    }
}

public enum MeetingOptionsReader {
    public static let lobbyName = "AutoAdmittedUsersOption"
    public static let presenterName = "WhoCanPresentOption"
    /// Runtime name candidates (exact MT names vary by build; the live
    /// reply decides). First entry = mined primary.
    public static let lobbyCandidates = [
        "AutoAdmittedUsersOption", "autoAdmittedUsers", "AutoAdmittedUsers",
        "UsersAllowedToByPassTheLobby",
    ]
    public static let presenterCandidates = [
        "WhoCanPresentOption", "presenterOption", "PresenterOption", "WhoCanPresent",
    ]

    /// The lobby row: first candidate present (exact, then case-insensitive).
    public static func lobbyRow(in rows: [MeetingOptionRow]) -> MeetingOptionRow? {
        match(lobbyCandidates, in: rows)
    }

    /// The presenter row: first candidate present (exact, then case-insensitive).
    public static func presenterRow(in rows: [MeetingOptionRow]) -> MeetingOptionRow? {
        match(presenterCandidates, in: rows)
    }

    static func match(_ names: [String], in rows: [MeetingOptionRow]) -> MeetingOptionRow? {
        for n in names {
            if let r = rows.first(where: { $0.name == n }) { return r }
        }
        for n in names {
            if let r = rows.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return r }
        }
        return nil
    }
    public static let defaultMiddleTier = "https://teams.microsoft.com/api/mt/amer"
    static let optionsPath = "beta/meetings/v1/options"

    public static func url(middleTier: String?, coords: MeetingCoordinates) -> URL? {
        var base = (middleTier?.isEmpty == false ? middleTier! : defaultMiddleTier)
        while base.hasSuffix("/") { base.removeLast() }
        let path = "\(optionsPath)/\(coords.tenantID)/\(coords.organizerID)/\(coords.threadID)/\(coords.messageID)"
        return URL(string: "\(base)/\(path)")
    }

    /// Normalize a `currentValue` (string, bool, number) to text.
    static func text(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return (CFGetTypeID(n) == CFBooleanGetTypeID()) ? (n.boolValue ? "true" : "false") : n.stringValue
        default: return nil
        }
    }

    /// Parse the GET reply into option rows. Unknown shapes → empty
    /// (the caller treats empty as unreadable, never as all-default).
    public static func parse(status: Int, data: Data) -> [MeetingOptionRow] {
        guard (200 ..< 300).contains(status),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let list: [[String: Any]]
        if let arr = obj["options"] as? [[String: Any]] {
            list = arr
        } else if let model = obj["meetingOptionsModel"] as? [String: Any],
                  let arr = model["options"] as? [[String: Any]] {
            list = arr
        } else {
            return []
        }
        return list.compactMap { o in
            guard let name = o["name"] as? String, !name.isEmpty,
                  let type = o["type"] as? String, !type.isEmpty,
                  let value = text(o["currentValue"]) else { return nil }
            return MeetingOptionRow(name: name, type: type, currentValue: value,
                                    category: o["category"] as? String)
        }
    }

    public static func lobby(of rows: [MeetingOptionRow]) -> MeetingLobbyBypass? {
        lobbyRow(in: rows).flatMap { MeetingLobbyBypass(rawValue: $0.currentValue) }
    }

    public static func presenters(of rows: [MeetingOptionRow]) -> MeetingPresenters? {
        presenterRow(in: rows).flatMap { MeetingPresenters(rawValue: $0.currentValue) }
    }

    /// POST body setting lobby + presenters (types mirror the GET rows).
    public static func body(lobby: MeetingLobbyBypass, presenters: MeetingPresenters) -> Data? {
        body(rows: [
            MeetingOptionRow(name: lobbyName, type: "List", currentValue: ""),
            MeetingOptionRow(name: presenterName, type: "List", currentValue: ""),
        ], lobby: lobby, presenters: presenters)
    }

    /// POST body replacing lobby + presenter values in `rows` (types kept
    /// from the GET reply, as the web client does; matched by candidate).
    public static func body(rows: [MeetingOptionRow], lobby: MeetingLobbyBypass,
                           presenters: MeetingPresenters) -> Data? {
        let lobbyName = lobbyRow(in: rows)?.name
        let presenterName = presenterRow(in: rows)?.name
        let items: [[String: Any]] = rows.map { r in
            var v = r.currentValue
            if r.name == lobbyName { v = lobby.rawValue }
            if r.name == presenterName { v = presenters.rawValue }
            var item: [String: Any] = ["name": r.name, "type": r.type, "currentValue": v]
            if let c = r.category { item["category"] = c }
            return item
        }
        return try? JSONSerialization.data(withJSONObject: ["options": items], options: [.sortedKeys])
    }

    /// POST body with only the lobby + presenter rows. A full echo of the
    /// GET set answers 417 (the server applies some rows anyway — live
    /// evidence); the two-row subset answers a clean 200 with the read-back
    /// matching, so the shipped save uses the subset.
    public static func bodySubset(rows: [MeetingOptionRow], lobby: MeetingLobbyBypass,
                                 presenters: MeetingPresenters) -> Data? {
        let keep = [lobbyRow(in: rows), presenterRow(in: rows)].compactMap { $0 }
        guard keep.count == 2 else { return nil }
        return body(rows: keep, lobby: lobby, presenters: presenters)
    }

    /// One GET with the caller's tokens (blocking; never refreshes).
    /// Returns `(status, rows)`; non-2xx → empty rows (caller records status).
    static func fetchRaw(slots: TokenSlots, now: UInt64, coords: MeetingCoordinates,
                          http: any CalendarHTTP) -> (status: Int, rows: [MeetingOptionRow]) {
        guard let aad = slots.accessToken, !aad.isExpired(now: now),
              let sk = slots.skypeToken, !sk.isExpired(now: now),
              let url = url(middleTier: CoreReads.regionGTMS(slots)["middleTier"], coords: coords) else {
            return (0, [])
        }
        guard let resp = try? http.send("GET", url: url, headers: [
            "Authorization": "Bearer \(aad.token)",
            "X-Skypetoken": sk.token,
            "x-ms-client-type": "desktop",
            "Accept": "application/json",
        ], body: nil) else { return (0, []) }
        return (resp.status, parse(status: resp.status, data: resp.data))
    }

    /// One POST with the caller's tokens (blocking; never refreshes).
    /// Returns the HTTP status (0 = no tokens/transport).
    static func setRaw(slots: TokenSlots, now: UInt64, coords: MeetingCoordinates,
                        lobby: MeetingLobbyBypass, presenters: MeetingPresenters,
                        http: any CalendarHTTP) -> Int {
        guard let data = body(lobby: lobby, presenters: presenters) else { return 0 }
        return postRaw(slots: slots, now: now, coords: coords, data: data, http: http)
    }

    /// One POST of a prebuilt options body (types kept from the GET reply).
    static func setRaw(slots: TokenSlots, now: UInt64, coords: MeetingCoordinates,
                       rows: [MeetingOptionRow], lobby: MeetingLobbyBypass,
                       presenters: MeetingPresenters, http: any CalendarHTTP) -> Int {
        guard let data = body(rows: rows, lobby: lobby, presenters: presenters) else { return 0 }
        return postRaw(slots: slots, now: now, coords: coords, data: data, http: http)
    }

    /// The lobby + presenter choice read back after a load or save.
    public struct Selection: Sendable, Equatable {
        public var lobby: MeetingLobbyBypass?
        public var presenters: MeetingPresenters?
        public var lobbyRowName: String?
        public var presenterRowName: String?

        public init(lobby: MeetingLobbyBypass? = nil, presenters: MeetingPresenters? = nil,
                    lobbyRowName: String? = nil, presenterRowName: String? = nil) {
            self.lobby = lobby
            self.presenters = presenters
            self.lobbyRowName = lobbyRowName
            self.presenterRowName = presenterRowName
        }
    }

    /// Load the lobby + presenter choice for an online meeting (blocking).
    /// Throws when the meeting has no Teams coordinates, tokens are
    /// missing, the reply is unreadable, or the server refuses.
    public static func load(meeting: MeetingItem) throws -> Selection {
        let (slots, now, coords, _) = try context(meeting: meeting)
        let (status, rows) = fetchRaw(slots: slots, now: now, coords: coords,
                                      http: URLSessionCalendarHTTP())
        return try selection(status: status, rows: rows)
    }

    /// Save the lobby + presenter choice, then read it back (blocking).
    /// Throws like `load`, plus when the reply carries no matching rows.
    @discardableResult
    public static func save(meeting: MeetingItem, lobby: MeetingLobbyBypass,
                            presenters: MeetingPresenters) throws -> Selection {
        let (slots, now, coords, http) = try context(meeting: meeting)
        let (getStatus, rows) = fetchRaw(slots: slots, now: now, coords: coords, http: http)
        let current = try selection(status: getStatus, rows: rows)
        guard let data = bodySubset(rows: rows, lobby: lobby, presenters: presenters) else {
            throw CoreCallError.failed("calendar: this meeting has no lobby or presenter options to set")
        }
        let setStatus = postRaw(slots: slots, now: now, coords: coords, data: data, http: http)
        guard (200 ..< 300).contains(setStatus) else {
            throw CoreCallError.failed("calendar: meeting options save failed (HTTP \(setStatus))")
        }
        let back = fetchRaw(slots: slots, now: now, coords: coords, http: http)
        let readBack = try selection(status: back.0, rows: back.1)
        _ = current
        return readBack
    }

    static func context(meeting: MeetingItem) throws
        -> (slots: TokenSlots, now: UInt64, coords: MeetingCoordinates, http: URLSessionCalendarHTTP) {
        guard let join = meeting.joinURL, let coords = MeetingCoordinates.fromJoinURL(join) else {
            throw CoreCallError.failed("calendar: meeting options need a Teams meeting link")
        }
        guard let ctx = try? CoreReads.production() else {
            throw CoreCallError.failed("calendar: not signed in")
        }
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard slots.accessToken != nil, slots.skypeToken != nil else {
            throw CoreCallError.failed("calendar: not signed in")
        }
        return (slots, ctx.now(), coords, URLSessionCalendarHTTP())
    }

    static func selection(status: Int, rows: [MeetingOptionRow]) throws -> Selection {
        guard (200 ..< 300).contains(status) else {
            if status == 403 {
                throw CoreCallError.failed("calendar: meeting options are only visible to the organizer")
            }
            throw CoreCallError.failed("calendar: meeting options read failed (HTTP \(status))")
        }
        guard !rows.isEmpty else {
            throw CoreCallError.failed("calendar: the server sent no meeting options")
        }
        return Selection(lobby: lobby(of: rows), presenters: presenters(of: rows),
                         lobbyRowName: lobbyRow(in: rows)?.name,
                         presenterRowName: presenterRow(in: rows)?.name)
    }

    static func postRaw(slots: TokenSlots, now: UInt64, coords: MeetingCoordinates,
                        data: Data, http: any CalendarHTTP) -> Int {
        guard let aad = slots.accessToken, !aad.isExpired(now: now),
              let sk = slots.skypeToken, !sk.isExpired(now: now),
              let url = url(middleTier: CoreReads.regionGTMS(slots)["middleTier"], coords: coords) else { return 0 }
        guard let resp = try? http.send("POST", url: url, headers: [
            "Authorization": "Bearer \(aad.token)",
            "X-Skypetoken": sk.token,
            "x-ms-client-type": "desktop",
            "Content-Type": "application/json",
            "Accept": "application/json",
        ], body: data) else { return 0 }
        return resp.status
    }
}
