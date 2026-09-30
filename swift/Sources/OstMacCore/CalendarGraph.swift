// CalendarGraph.swift — CALENDAR lane: Swift-native Graph calendar
// client. Reads `calendarView` with `Prefer: outlook.timezone="UTC"`
// (one known zone; `CalendarEvents` localizes), plus the event writes
// the calendar needs: RSVP, edit, Meet now create, delete.
// Blocking: call off the main thread (same contract as `CoreReads`).
import Foundation
import os

/// One sync Graph request (tests inject stubs; zero live network).
protocol CalendarHTTP: Sendable {
    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ReadHTTPResponse
}

/// URLSession-backed sync request (semaphore bridge; production use).
struct URLSessionCalendarHTTP: CalendarHTTP {
    func send(_ method: String, url: URL, headers: [String: String], body: Data?) throws -> ReadHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let request = req
        return try SyncBridge.run {
            let (data, resp) = try await URLSession.shared.data(for: request)
            return ReadHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        }
    }
}

public struct CalendarGraph: Sendable {
    static let base = "https://graph.microsoft.com/v1.0"
    static let preferUTC = "outlook.timezone=\"UTC\""
    /// calendarView pages followed per range (100 rows each).
    static let maxPages = 6

    var http: any CalendarHTTP
    var token: @Sendable () throws -> String
    var timeZone: @Sendable () -> TimeZone = { .current }
    /// Read `/me` so the user's own attendee entry carries their own
    /// response (production; stub transports leave it off).
    var lookupSelf = false
    /// Cache key for the `/me` address (the profile signed in).
    var profileKey = ""

    init(http: any CalendarHTTP, token: @escaping @Sendable () throws -> String,
         timeZone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.http = http
        self.token = token
        self.timeZone = timeZone
    }

    /// Signed-in profile, URLSession transport.
    public static func production() -> CalendarGraph {
        var g = CalendarGraph(http: URLSessionCalendarHTTP()) {
            try CoreReads.graphToken(
                profile: CoreLocal.activeProfileID(), code: "calendar", ctx: CoreReads.production())
        }
        g.lookupSelf = true
        g.profileKey = CoreLocal.activeProfileID()
        return g
    }

    // MARK: transport

    static func encode(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    /// One request; non-2xx throws a user-facing error (no URL, no body
    /// echo of tokens).
    @discardableResult
    func request(_ method: String, _ pathOrURL: String, json: [String: Any]? = nil) throws -> Data {
        let full = pathOrURL.hasPrefix("https://") ? pathOrURL : Self.base + pathOrURL
        guard let url = URL(string: full), url.host == "graph.microsoft.com" else {
            throw CoreCallError.failed("calendar: bad Graph path")
        }
        var headers = [
            "Authorization": "Bearer \(try token())",
            "Prefer": Self.preferUTC,
        ]
        var body: Data?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            headers["Content-Type"] = "application/json"
        }
        let resp: ReadHTTPResponse
        do {
            resp = try http.send(method, url: url, headers: headers, body: body)
        } catch {
            throw CoreCallError.failed("calendar: \(method) failed: \(error.localizedDescription)")
        }
        if resp.status == 401 {
            throw CoreCallError.failed("calendar: 401 Unauthorized. Token may be invalid -- sign in again.")
        }
        guard (200 ... 299).contains(resp.status) else {
            throw CoreCallError.failed("calendar: HTTP \(resp.status) (\(Self.graphError(resp.data)))")
        }
        return resp.data
    }

    /// Graph `error.message` (or code) of a failed call.
    static func graphError(_ data: Data) -> String {
        struct E: Decodable {
            struct Inner: Decodable {
                let code: String?
                let message: String?
            }
            let error: Inner?
        }
        let e = try? JSONDecoder().decode(E.self, from: data)
        return e?.error?.message ?? e?.error?.code ?? "request failed"
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: reads

    /// Every event overlapping `[from, to)`.
    public func range(from: Date, to: Date) throws -> [MeetingItem] {
        let query = "startDateTime=\(Self.iso(from))&endDateTime=\(Self.iso(to))"
            + "&$select=\(CalendarEvents.listSelect)&$orderby=start/dateTime&$top=100"
        var next: String? = "/me/calendarView?" + query
        var rows: [MeetingItem] = []
        var pages = 0
        let tz = timeZone()
        let mine = lookupSelf ? (try? selfAddresses()) ?? [] : []
        while let path = next, pages < Self.maxPages {
            let page = try CalendarEvents.page(try request("GET", path), tz: tz, me: mine.first, meAliases: mine)
            rows += page.rows
            next = page.next
            pages += 1
        }
        return rows
    }

    /// The week starting at unix `weekStart` (a local midnight).
    public func week(start weekStart: Int64, calendar: Calendar = .current) throws -> CalWeekResponse {
        let from = Date(timeIntervalSince1970: TimeInterval(weekStart))
        let to = calendar.date(byAdding: .day, value: 7, to: from) ?? from.addingTimeInterval(7 * 86_400)
        return CalWeekResponse(ok: true, weekStart: weekStart, days: 7, meetings: try range(from: from, to: to))
    }

    /// Occurrences of a series in `[from, to)`
    /// (`/me/events/{seriesMasterId}/instances`), in start order.
    public func instances(seriesID: String, from: Date, to: Date) throws -> [MeetingItem] {
        let query = "startDateTime=\(Self.iso(from))&endDateTime=\(Self.iso(to))"
            + "&$select=\(CalendarEvents.listSelect)&$orderby=start/dateTime&$top=100"
        var next: String? = "/me/events/\(Self.encode(seriesID))/instances?" + query
        var rows: [MeetingItem] = []
        var pages = 0
        let tz = timeZone()
        let mine = lookupSelf ? (try? selfAddresses()) ?? [] : []
        while let path = next, pages < Self.maxPages {
            let page = try CalendarEvents.page(try request("GET", path), tz: tz, me: mine.first, meAliases: mine)
            rows += page.rows
            next = page.next
            pages += 1
        }
        return rows
    }

    /// Full event (body, fresh responses), attachments and series pattern.
    public func detail(id: String) throws -> CalendarEventDetail {
        let tz = timeZone()
        let one = try CalendarEvents.single(
            try request("GET", "/me/events/\(Self.encode(id))?$select=\(CalendarEvents.detailSelect)"), tz: tz,
            me: lookupSelf ? try? selfAddress() : nil,
            meAliases: lookupSelf ? (try? selfAddresses()) ?? [] : [])
        var recurrence = one.row.info?.recurrence
        if recurrence == nil, let master = one.row.info?.seriesMasterID {
            struct R: Decodable { let recurrence: GraphEventWire.Recurrence? }
            let data = try? request("GET", "/me/events/\(Self.encode(master))?$select=recurrence")
            if let r = data.flatMap({ try? JSONDecoder().decode(R.self, from: $0) })?.recurrence {
                recurrence = CalendarEvents.recurrenceSummary(r)
            }
        }
        var attachments: [EventAttachment] = []
        if one.row.info?.hasAttachments == true {
            struct A: Decodable {
                struct Item: Decodable {
                    let id: String
                    let name: String?
                    let size: Int?
                    let contentType: String?
                }
                let value: [Item]
            }
            if let data = try? request("GET", "/me/events/\(Self.encode(id))/attachments?$select=id,name,size,contentType"),
               let list = try? JSONDecoder().decode(A.self, from: data) {
                attachments = list.value.map {
                    EventAttachment(id: $0.id, name: $0.name ?? "Attachment", size: $0.size ?? 0, contentType: $0.contentType)
                }
            }
        }
        let isHTML = one.body?.contentType?.lowercased() == "html"
        let content = CalendarEvents.nonEmpty(one.body?.content)
        return CalendarEventDetail(
            event: one.row, bodyHTML: isHTML ? content : nil, bodyText: isHTML ? nil : content,
            attachments: attachments, recurrence: recurrence)
    }

    /// The signed-in user's SMTP address (`/me`), read once per process.
    public func selfAddress() throws -> String {
        guard let first = try selfAddresses().first else {
            throw CoreCallError.failed("calendar: no address for the signed-in user")
        }
        return first
    }

    /// The signed-in user's mail and UPN (attendees may carry either).
    public func selfAddresses() throws -> [String] {
        let key = profileKey
        if let cached = Self.selfCache.withLock({ $0[key] }) { return cached }
        struct Me: Decodable {
            let mail: String?
            let userPrincipalName: String?
        }
        let me = try JSONDecoder().decode(Me.self, from: try request("GET", "/me?$select=mail,userPrincipalName"))
        var addresses: [String] = []
        for a in [me.mail, me.userPrincipalName] {
            if let a = CalendarEvents.nonEmpty(a), !addresses.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
                addresses.append(a)
            }
        }
        guard !addresses.isEmpty else {
            throw CoreCallError.failed("calendar: no address for the signed-in user")
        }
        let found = addresses
        Self.selfCache.withLock { $0[key] = found }
        return found
    }

    static let selfCache = OSAllocatedUnfairLock<[String: [String]]>(initialState: [:])

    /// Outlook color categories (`/me/outlook/masterCategories`).
    public func masterCategories() throws -> [CalendarCategory] {
        struct L: Decodable {
            struct C: Decodable {
                let displayName: String?
                let color: String?
            }
            let value: [C]
        }
        let list = try JSONDecoder().decode(L.self, from: try request("GET", "/me/outlook/masterCategories"))
        return list.value.compactMap { c in
            CalendarEvents.nonEmpty(c.displayName).map { CalendarCategory(name: $0, color: c.color ?? "none") }
        }
    }

    /// Free/busy for `emails` over `[from, to)` (Graph `getSchedule`, a
    /// read-only query sent as POST). 30-minute availability view.
    public func schedule(for emails: [String], from: Date, to: Date) throws -> [CalendarFreeBusy] {
        let body: [String: Any] = [
            "schedules": emails,
            "startTime": ["dateTime": CalendarTime.wallClock(from, in: TimeZone(identifier: "UTC")!), "timeZone": "UTC"],
            "endTime": ["dateTime": CalendarTime.wallClock(to, in: TimeZone(identifier: "UTC")!), "timeZone": "UTC"],
            "availabilityViewInterval": 30,
        ]
        return try CalendarEvents.schedule(try request("POST", "/me/calendar/getSchedule", json: body))
    }

    /// Download one event attachment's bytes (file attachments).
    public func attachment(eventID: String, attachmentID: String) throws -> Data {
        struct F: Decodable { let contentBytes: String? }
        let data = try request("GET", "/me/events/\(Self.encode(eventID))/attachments/\(Self.encode(attachmentID))")
        guard let b64 = try JSONDecoder().decode(F.self, from: data).contentBytes,
              let bytes = Data(base64Encoded: b64) else {
            throw CoreCallError.failed("calendar: this attachment can\u{2019}t be downloaded (not a file)")
        }
        return bytes
    }

    // MARK: writes

    /// Forward the invitation (Graph `POST /me/events/{id}/forward`).
    public func forward(id: String, to recipients: [String], comment: String = "") throws {
        try request("POST", "/me/events/\(Self.encode(id))/forward", json: [
            "comment": comment,
            "toRecipients": recipients.map { ["emailAddress": ["address": $0]] },
        ])
    }

    /// Create a draft Teams webinar (Graph virtual events) and return
    /// its id. Publishing stays in Teams.
    public func createWebinar(title: String, start: Date, end: Date, audience: String = "organization") throws -> String {
        struct R: Decodable { let id: String }
        let utc = TimeZone(identifier: "UTC")!
        let data = try request("POST", "/solutions/virtualEvents/webinars", json: [
            "displayName": title,
            "audience": audience,
            "startDateTime": ["dateTime": CalendarTime.wallClock(start, in: utc), "timeZone": "UTC"],
            "endDateTime": ["dateTime": CalendarTime.wallClock(end, in: utc), "timeZone": "UTC"],
        ])
        return try JSONDecoder().decode(R.self, from: data).id
    }

    /// Graph RSVP (`accept` | `tentativelyAccept` | `decline`) on `id`
    /// (an occurrence, or the series master for the whole series).
    public func respond(id: String, action: RSVPAction, comment: String = "", sendResponse: Bool = true) throws {
        try request("POST", "/me/events/\(Self.encode(id))/\(action.rawValue)",
                    json: ["comment": comment, "sendResponse": sendResponse])
    }

    /// PATCH an event; returns the updated row (localized).
    public func update(id: String, patch: CalendarEventPatch) throws -> MeetingItem {
        let data = try request("PATCH", "/me/events/\(Self.encode(id))", json: patch.body)
        return try CalendarEvents.single(data, tz: timeZone()).row
    }

    /// Create an event in the signed-in user's calendar. `attendees`
    /// are SMTP addresses (Meet now passes none: a solo meeting).
    public func create(subject: String, start: Date, end: Date, online: Bool,
                       attendees: [String] = []) throws -> MeetingItem {
        let tz = timeZone()
        var body: [String: Any] = [
            "subject": subject,
            "start": ["dateTime": CalendarTime.wallClock(start, in: tz), "timeZone": tz.identifier],
            "end": ["dateTime": CalendarTime.wallClock(end, in: tz), "timeZone": tz.identifier],
            "attendees": attendees.map { ["emailAddress": ["address": $0], "type": "required"] },
        ]
        if online {
            body["isOnlineMeeting"] = true
            body["onlineMeetingProvider"] = "teamsForBusiness"
        }
        var row = try CalendarEvents.single(try request("POST", "/me/events", json: body), tz: tz).row
        // Graph can hand back the online meeting a beat after the create.
        if online, row.joinURL == nil {
            let again = try? request("GET", "/me/events/\(Self.encode(row.meetingId))?$select=\(CalendarEvents.listSelect)")
            if let again, let reread = try? CalendarEvents.single(again, tz: tz).row { row = reread }
        }
        return row
    }

    /// Create a full event (Duplicate): attendees, location and body.
    public func create(_ d: CalendarEventDraft) throws -> MeetingItem {
        let tz = timeZone()
        let data = try request("POST", "/me/events", json: d.body(in: tz))
        return try CalendarEvents.single(data, tz: tz).row
    }

    /// Delete an event (organizer: also cancels it for invitees).
    public func delete(id: String) throws {
        try request("DELETE", "/me/events/\(Self.encode(id))")
    }
}
