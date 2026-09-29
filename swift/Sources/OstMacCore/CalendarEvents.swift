// CalendarEvents.swift — CALENDAR lane: the Graph event fields past the
// join basics (location, RSVP, attendees, series, organizer time zone),
// time-zone normalization, recurrence wording and a safe body renderer.
//
// Time zones: calendarView is read with `Prefer: outlook.timezone="UTC"`
// so every timed instant arrives in one known zone; `CalendarTime`
// converts it to the local wall clock (`TimeZone.current`) the week grid,
// list and inspector read. All-day events are floating dates: their
// `start`/`end` are kept verbatim (no shift, so no off-by-one day).
import Foundation

// MARK: - Event fields

/// The signed-in user's (or an attendee's) response (Graph `responseType`).
public enum RSVPResponse: String, Codable, Sendable, Equatable, CaseIterable {
    case none, organizer, tentativelyAccepted, accepted, declined, notResponded

    public init(graph: String?) {
        self = graph.flatMap(RSVPResponse.init(rawValue:)) ?? .none
    }

    /// Teams wording for the inspector's status line.
    public var label: String {
        switch self {
        case .accepted: "Accepted"
        case .tentativelyAccepted: "Tentative"
        case .declined: "Declined"
        case .organizer: "Organizer"
        case .none, .notResponded: "Not responded"
        }
    }

    /// No answer yet (the "Didn't respond" group).
    public var isPending: Bool { self == .none || self == .notResponded }
}

/// RSVP actions (Graph `POST /me/events/{id}/accept|tentativelyAccept|decline`).
public enum RSVPAction: String, Sendable, Equatable, CaseIterable {
    case accept, tentativelyAccept, decline

    public var response: RSVPResponse {
        switch self {
        case .accept: .accepted
        case .tentativelyAccept: .tentativelyAccepted
        case .decline: .declined
        }
    }

    public var title: String {
        switch self {
        case .accept: "Accept"
        case .tentativelyAccept: "Tentative"
        case .decline: "Decline"
        }
    }
}

/// Graph event `type`.
public enum CalendarEventKind: String, Codable, Sendable, Equatable {
    case singleInstance, occurrence, exception, seriesMaster

    /// Part of a recurring series (the "Series" badge).
    public var isSeries: Bool { self != .singleInstance }
}

public struct EventAttendee: Codable, Sendable, Equatable, Identifiable {
    public var id: String { email.isEmpty ? name : email.lowercased() }
    public let name: String
    public let email: String
    /// `required` | `optional` | `resource` (a room).
    public let type: String
    public let response: RSVPResponse

    public init(name: String, email: String, type: String = "required", response: RSVPResponse = .none) {
        self.name = name
        self.email = email
        self.type = type
        self.response = response
    }

    public var isRoom: Bool { type == "resource" }
    public var typeLabel: String { type == "optional" ? "Optional" : "Required" }
}

/// Dial-in details of an online meeting (Graph `onlineMeeting`).
public struct EventDialIn: Codable, Sendable, Equatable {
    public let tollNumber: String?
    public let conferenceID: String?
    public let quickDial: String?

    public init(tollNumber: String?, conferenceID: String?, quickDial: String? = nil) {
        self.tollNumber = tollNumber
        self.conferenceID = conferenceID
        self.quickDial = quickDial
    }
}

/// Graph fields past the join basics, carried on `MeetingItem.info`.
public struct CalendarEventInfo: Codable, Sendable, Equatable {
    /// `locations[].displayName` joined (else `location.displayName`);
    /// nil when the event has no location.
    public var location: String?
    public var myResponse: RSVPResponse
    /// `free` | `tentative` | `busy` | `oof` | `workingElsewhere` | `unknown`.
    public var showAs: String?
    public var kind: CalendarEventKind
    public var seriesMasterID: String?
    public var attendees: [EventAttendee]
    /// Windows or IANA name (Graph `originalStartTimeZone`).
    public var originalStartTimeZone: String?
    public var isCancelled: Bool
    public var hasAttachments: Bool
    public var responseRequested: Bool
    public var bodyPreview: String?
    public var webLink: String?
    public var sensitivity: String?
    public var reminderMinutes: Int?
    public var dialIn: EventDialIn?
    /// Human summary of the series pattern, when the row carries it
    /// (series masters; occurrences get it with the details read).
    public var recurrence: String?

    public init(
        location: String? = nil, myResponse: RSVPResponse = .none, showAs: String? = nil,
        kind: CalendarEventKind = .singleInstance, seriesMasterID: String? = nil,
        attendees: [EventAttendee] = [], originalStartTimeZone: String? = nil,
        isCancelled: Bool = false, hasAttachments: Bool = false, responseRequested: Bool = true,
        bodyPreview: String? = nil, webLink: String? = nil, sensitivity: String? = nil,
        reminderMinutes: Int? = nil, dialIn: EventDialIn? = nil, recurrence: String? = nil
    ) {
        self.location = location
        self.myResponse = myResponse
        self.showAs = showAs
        self.kind = kind
        self.seriesMasterID = seriesMasterID
        self.attendees = attendees
        self.originalStartTimeZone = originalStartTimeZone
        self.isCancelled = isCancelled
        self.hasAttachments = hasAttachments
        self.responseRequested = responseRequested
        self.bodyPreview = bodyPreview
        self.webLink = webLink
        self.sensitivity = sensitivity
        self.reminderMinutes = reminderMinutes
        self.dialIn = dialIn
        self.recurrence = recurrence
    }

    /// People (rooms excluded).
    public var people: [EventAttendee] { attendees.filter { !$0.isRoom } }
    public var rooms: [EventAttendee] { attendees.filter(\.isRoom) }

    /// Response tally over people, Teams order.
    public struct Tally: Equatable, Sendable {
        public var accepted = 0, tentative = 0, declined = 0, pending = 0
    }

    public var tally: Tally {
        var t = Tally()
        for a in people {
            switch a.response {
            case .accepted, .organizer: t.accepted += 1
            case .tentativelyAccepted: t.tentative += 1
            case .declined: t.declined += 1
            case .none, .notResponded: t.pending += 1
            }
        }
        return t
    }
}

/// Details read on demand (inspector expand / details popup).
public struct CalendarEventDetail: Codable, Sendable, Equatable {
    /// The event re-read with every field (fresh attendee responses).
    public var event: MeetingItem
    /// `body.content` when HTML, nil otherwise.
    public var bodyHTML: String?
    /// `body.content` when plain text.
    public var bodyText: String?
    public var attachments: [EventAttachment]
    /// Series pattern (from the master for an occurrence).
    public var recurrence: String?

    public init(event: MeetingItem, bodyHTML: String? = nil, bodyText: String? = nil,
                attachments: [EventAttachment] = [], recurrence: String? = nil) {
        self.event = event
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.attachments = attachments
        self.recurrence = recurrence
    }
}

public struct EventAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let size: Int

    public init(id: String, name: String, size: Int) {
        self.id = id
        self.name = name
        self.size = size
    }
}

/// An edit to an existing event (Graph `PATCH /me/events/{id}`); nil
/// fields are left alone. `start`/`end` are local Graph datetimes in
/// `timeZone`.
public struct CalendarEventPatch: Sendable, Equatable {
    public var subject: String?
    public var start: String?
    public var end: String?
    public var timeZone: String
    public var location: String?

    public init(subject: String? = nil, start: String? = nil, end: String? = nil,
                timeZone: String = TimeZone.current.identifier, location: String? = nil) {
        self.subject = subject
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.location = location
    }

    public var isEmpty: Bool { subject == nil && start == nil && end == nil && location == nil }

    /// The PATCH body.
    public var body: [String: Any] {
        var b: [String: Any] = [:]
        if let subject { b["subject"] = subject }
        if let start { b["start"] = ["dateTime": start, "timeZone": timeZone] }
        if let end { b["end"] = ["dateTime": end, "timeZone": timeZone] }
        if let location { b["location"] = ["displayName": location] }
        return b
    }
}

// MARK: - Time zones

public enum CalendarTime {
    static let wall = "yyyy-MM-dd'T'HH:mm:ss"

    private static func formatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = wall
        return f
    }

    /// Graph `dateTime` (first 19 characters) in `zone` → instant.
    public static func instant(_ dateTime: String?, zone: String? = "UTC") -> Date? {
        guard let dateTime, dateTime.count >= 19 else { return nil }
        let tz = zone.flatMap(timeZone(graphName:)) ?? TimeZone(identifier: "UTC")!
        return formatter(tz).date(from: String(dateTime.prefix(19)))
    }

    /// Instant → local wall clock `yyyy-MM-dd'T'HH:mm:ss` in `tz`.
    public static func wallClock(_ date: Date, in tz: TimeZone = .current) -> String {
        formatter(tz).string(from: date)
    }

    /// `row` with `start`/`end` re-derived from its UTC instants in
    /// `tz`. All-day rows keep their floating dates; rows without UTC
    /// instants (demo, local) are returned unchanged.
    public static func localize(_ row: MeetingItem, to tz: TimeZone = .current) -> MeetingItem {
        guard !row.isAllDay, row.utcStart != nil || row.utcEnd != nil else { return row }
        var out = row
        if let s = instant(row.utcStart) { out.start = wallClock(s, in: tz) }
        if let e = instant(row.utcEnd) { out.end = wallClock(e, in: tz) }
        return out
    }

    /// Windows zone names Graph uses → IANA (the common ones; IANA
    /// names and `UTC` resolve directly).
    static let windowsZones: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12", "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage", "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix", "Mountain Standard Time": "America/Denver",
        "Central Standard Time": "America/Chicago", "Eastern Standard Time": "America/New_York",
        "US Eastern Standard Time": "America/Indianapolis", "Atlantic Standard Time": "America/Halifax",
        "Newfoundland Standard Time": "America/St_Johns", "Canada Central Standard Time": "America/Regina",
        "E. South America Standard Time": "America/Sao_Paulo", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "GMT Standard Time": "Europe/London", "W. Europe Standard Time": "Europe/Berlin",
        "Romance Standard Time": "Europe/Paris", "Central Europe Standard Time": "Europe/Budapest",
        "Central European Standard Time": "Europe/Warsaw", "E. Europe Standard Time": "Europe/Chisinau",
        "FLE Standard Time": "Europe/Kiev", "GTB Standard Time": "Europe/Bucharest",
        "Israel Standard Time": "Asia/Jerusalem", "Russian Standard Time": "Europe/Moscow",
        "Arabian Standard Time": "Asia/Dubai", "India Standard Time": "Asia/Calcutta",
        "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
        "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "AUS Eastern Standard Time": "Australia/Sydney", "E. Australia Standard Time": "Australia/Brisbane",
        "New Zealand Standard Time": "Pacific/Auckland", "South Africa Standard Time": "Africa/Johannesburg",
        "UTC": "UTC", "tzone://Microsoft/Utc": "UTC", "Coordinated Universal Time": "UTC",
    ]

    public static func timeZone(graphName name: String) -> TimeZone? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return nil }
        if let id = windowsZones[n] { return TimeZone(identifier: id) }
        return TimeZone(identifier: n)
    }

    /// The organizer's zone when it differs from `local` at `date`
    /// (different UTC offset); nil when the same, unknown or all-day.
    public static func organizerZone(_ row: MeetingItem, local: TimeZone = .current) -> TimeZone? {
        guard !row.isAllDay, let name = row.info?.originalStartTimeZone,
              let tz = timeZone(graphName: name) else { return nil }
        let at = instant(row.utcStart) ?? Date()
        return tz.secondsFromGMT(for: at) == local.secondsFromGMT(for: at) ? nil : tz
    }

    /// The Graph zone name as shown ("Pacific Standard Time").
    public static func zoneLabel(_ tz: TimeZone, at date: Date = Date()) -> String {
        tz.localizedName(for: tz.isDaylightSavingTime(for: date) ? .daylightSaving : .standard,
                         locale: Locale(identifier: "en_US")) ?? tz.identifier
    }
}

// MARK: - Graph event wire → MeetingItem

struct GraphEventWire: Decodable {
    struct DTZ: Decodable {
        let dateTime: String?
        let timeZone: String?
    }
    struct Email: Decodable {
        let name: String?
        let address: String?
    }
    struct Person: Decodable { let emailAddress: Email? }
    struct Status: Decodable {
        let response: String?
    }
    struct Attendee: Decodable {
        let type: String?
        let status: Status?
        let emailAddress: Email?
    }
    struct Location: Decodable { let displayName: String? }
    struct Online: Decodable {
        let joinUrl: String?
        let conferenceId: String?
        let tollNumber: String?
        let quickDial: String?
    }
    struct Body: Decodable {
        let contentType: String?
        let content: String?
    }
    struct Pattern: Decodable {
        let type: String?
        let interval: Int?
        let daysOfWeek: [String]?
        let dayOfMonth: Int?
        let index: String?
        let month: Int?
    }
    struct Range: Decodable {
        let type: String?
        let startDate: String?
        let endDate: String?
        let numberOfOccurrences: Int?
    }
    struct Recurrence: Decodable {
        let pattern: Pattern?
        let range: Range?
    }

    let id: String
    let subject: String?
    let start: DTZ?
    let end: DTZ?
    let isAllDay: Bool?
    let isOnlineMeeting: Bool?
    let onlineMeeting: Online?
    let organizer: Person?
    let isOrganizer: Bool?
    let webLink: String?
    let categories: [String]?
    let location: Location?
    let locations: [Location]?
    let attendees: [Attendee]?
    let responseStatus: Status?
    let showAs: String?
    let type: String?
    let seriesMasterId: String?
    let recurrence: Recurrence?
    let originalStartTimeZone: String?
    let isCancelled: Bool?
    let hasAttachments: Bool?
    let responseRequested: Bool?
    let isReminderOn: Bool?
    let reminderMinutesBeforeStart: Int?
    let sensitivity: String?
    let bodyPreview: String?
    let body: Body?
}

public enum CalendarEvents {
    /// `$select` for the calendarView read (list, grid, inspector).
    public static let listSelect = [
        "id", "subject", "start", "end", "isAllDay", "isOnlineMeeting", "onlineMeeting",
        "organizer", "isOrganizer", "webLink", "categories", "location", "locations",
        "attendees", "responseStatus", "showAs", "type", "seriesMasterId", "recurrence",
        "originalStartTimeZone", "isCancelled", "hasAttachments", "responseRequested",
        "isReminderOn", "reminderMinutesBeforeStart", "sensitivity", "bodyPreview",
    ].joined(separator: ",")

    /// `$select` for the details read (adds the body).
    public static let detailSelect = listSelect + ",body"

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// One wire event → a local row (`tz` = the display zone).
    static func item(_ e: GraphEventWire, tz: TimeZone = .current) -> MeetingItem {
        let allDay = e.isAllDay ?? false
        let startZone = e.start?.timeZone ?? "UTC"
        let endZone = e.end?.timeZone ?? "UTC"
        // UTC instants (the relocalization source) for timed events.
        let utcStart = allDay ? nil : CalendarTime.instant(e.start?.dateTime, zone: startZone)
            .map { CalendarTime.wallClock($0, in: TimeZone(identifier: "UTC")!) }
        let utcEnd = allDay ? nil : CalendarTime.instant(e.end?.dateTime, zone: endZone)
            .map { CalendarTime.wallClock($0, in: TimeZone(identifier: "UTC")!) }
        let names = (e.locations ?? []).compactMap { nonEmpty($0.displayName) }
        let location = names.isEmpty ? nonEmpty(e.location?.displayName) : names.joined(separator: "; ")
        let attendees = (e.attendees ?? []).map { a in
            EventAttendee(name: nonEmpty(a.emailAddress?.name) ?? a.emailAddress?.address ?? "",
                          email: a.emailAddress?.address ?? "",
                          type: a.type ?? "required",
                          response: RSVPResponse(graph: a.status?.response))
        }
        let online = e.onlineMeeting
        let dialIn: EventDialIn? = online.flatMap {
            nonEmpty($0.tollNumber) == nil && nonEmpty($0.conferenceId) == nil ? nil
                : EventDialIn(tollNumber: nonEmpty($0.tollNumber), conferenceID: nonEmpty($0.conferenceId),
                              quickDial: nonEmpty($0.quickDial))
        }
        let info = CalendarEventInfo(
            location: location,
            myResponse: RSVPResponse(graph: e.responseStatus?.response),
            showAs: e.showAs,
            kind: e.type.flatMap(CalendarEventKind.init(rawValue:)) ?? .singleInstance,
            seriesMasterID: nonEmpty(e.seriesMasterId),
            attendees: attendees,
            originalStartTimeZone: nonEmpty(e.originalStartTimeZone),
            isCancelled: e.isCancelled ?? false,
            hasAttachments: e.hasAttachments ?? false,
            responseRequested: e.responseRequested ?? true,
            bodyPreview: nonEmpty(e.bodyPreview),
            webLink: nonEmpty(e.webLink),
            sensitivity: e.sensitivity,
            reminderMinutes: (e.isReminderOn ?? false) ? e.reminderMinutesBeforeStart : nil,
            dialIn: dialIn,
            recurrence: e.recurrence.map(recurrenceSummary))
        let row = MeetingItem(
            meetingId: e.id,
            subject: nonEmpty(e.subject) ?? "(no subject)",
            start: allDay ? e.start?.dateTime.map { String($0.prefix(19)) } : utcStart,
            end: allDay ? e.end?.dateTime.map { String($0.prefix(19)) } : utcEnd,
            joinURL: nonEmpty(online?.joinUrl),
            organizer: nonEmpty(e.organizer?.emailAddress?.name),
            organizerEmail: nonEmpty(e.organizer?.emailAddress?.address),
            isOrganizer: e.isOrganizer ?? false,
            isOnline: e.isOnlineMeeting ?? false,
            categories: e.categories ?? [],
            isAllDay: allDay, utcStart: utcStart, utcEnd: utcEnd, info: info)
        return CalendarTime.localize(row, to: tz)
    }

    /// A `calendarView` page → rows (cancelled occurrences dropped).
    static func page(_ data: Data, tz: TimeZone = .current) throws -> (rows: [MeetingItem], next: String?) {
        struct Page: Decodable {
            let value: [GraphEventWire]
            let next: String?
            enum CodingKeys: String, CodingKey {
                case value
                case next = "@odata.nextLink"
            }
        }
        let p = try JSONDecoder().decode(Page.self, from: data)
        return (p.value.map { item($0, tz: tz) }.filter { $0.info?.isCancelled != true }, p.next)
    }

    /// One event → row.
    static func single(_ data: Data, tz: TimeZone = .current) throws -> (row: MeetingItem, body: GraphEventWire.Body?) {
        let w = try JSONDecoder().decode(GraphEventWire.self, from: data)
        return (item(w, tz: tz), w.body)
    }

    // MARK: recurrence wording

    static let weekdayOrder = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static func dayName(_ d: String) -> String { d.prefix(1).uppercased() + d.dropFirst().lowercased() }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11 ... 13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func shortDate(_ ymd: String?) -> String? {
        guard let ymd, let d = CalendarTime.instant(ymd + "T00:00:00", zone: "UTC") else { return nil }
        var f = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        f.timeZone = TimeZone(identifier: "UTC")!
        return d.formatted(f)
    }

    /// "Occurs every weekday starting Sep 1, 2026 until Dec 18, 2026".
    static func recurrenceSummary(_ r: GraphEventWire.Recurrence) -> String {
        let p = r.pattern
        let n = max(1, p?.interval ?? 1)
        let days = (p?.daysOfWeek ?? []).map { $0.lowercased() }
            .sorted { (weekdayOrder.firstIndex(of: $0) ?? 0) < (weekdayOrder.firstIndex(of: $1) ?? 0) }
        let dayList = days.map(dayName).joined(separator: ", ")
        let months = Calendar(identifier: .gregorian).monthSymbols
        let monthName = p?.month.flatMap { (1 ... 12).contains($0) ? months[$0 - 1] : nil } ?? ""
        let index = p?.index.map { $0 == "last" ? "last" : $0 } ?? "first"
        var s: String
        switch p?.type ?? "" {
        case "daily":
            s = n == 1 ? "Occurs every day" : "Occurs every \(n) days"
        case "weekly":
            let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday"]
            if n == 1, days == weekdays {
                s = "Occurs every weekday"
            } else {
                s = n == 1 ? "Occurs every \(dayList)" : "Occurs every \(n) weeks on \(dayList)"
            }
        case "absoluteMonthly":
            let d = ordinal(p?.dayOfMonth ?? 1)
            s = n == 1 ? "Occurs on the \(d) of every month" : "Occurs on the \(d) of every \(n) months"
        case "relativeMonthly":
            s = n == 1 ? "Occurs the \(index) \(dayList) of every month"
                : "Occurs the \(index) \(dayList) of every \(n) months"
        case "absoluteYearly":
            s = "Occurs every \(monthName) \(p?.dayOfMonth ?? 1)"
        case "relativeYearly":
            s = "Occurs the \(index) \(dayList) of \(monthName)"
        default:
            s = "Recurring"
        }
        if let from = shortDate(r.range?.startDate) { s += " starting \(from)" }
        switch r.range?.type {
        case "endDate":
            if let to = shortDate(r.range?.endDate) { s += " until \(to)" }
        case "numbered":
            if let c = r.range?.numberOfOccurrences { s += " for \(c) occurrences" }
        default: break
        }
        return s
    }
}

// MARK: - Meeting chat

extension MeetingItem {
    /// The meeting's chat thread (`19:meeting_…@thread.v2`), read from
    /// the join link; nil when there is none.
    public var chatThreadID: String? {
        guard let url = joinURL, !url.isEmpty else { return nil }
        return JoinParse.parse(raw: url).threadID
    }

    /// Part of a recurring series.
    public var isSeries: Bool { info?.kind.isSeries ?? false }
}

// MARK: - Safe body rendering

/// Event body HTML → plain attributed text: no images, scripts, styles
/// or remote loads (nothing is fetched); links kept for http(s),
/// mailto and tel only.
public enum EventBodyRender {
    public static func attributed(html: String) -> AttributedString {
        var out = AttributedString()
        var text = ""
        var link: URL?
        var bold = 0
        var i = html.startIndex
        let lower = html.lowercased()

        func flush() {
            guard !text.isEmpty else { return }
            var run = AttributedString(MessageRender.decodeEntities(text))
            if let link { run.link = link }
            if bold > 0 { run.inlinePresentationIntent = .stronglyEmphasized }
            out += run
            text = ""
        }
        func newline() {
            flush()
            let chars = out.characters
            let tail = String(chars.suffix(2))
            if chars.isEmpty || tail == "\n\n" { return }
            out += AttributedString("\n")
        }

        while i < html.endIndex {
            let c = html[i]
            if c == "<", let close = html[i...].firstIndex(of: ">") {
                let tag = lower[lower.index(after: i) ..< close]
                let name = tag.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\n" || $0 == "\t" })
                    .first.map(String.init) ?? ""
                let closing = tag.hasPrefix("/")
                let bare = closing ? String(tag.dropFirst()).split(separator: " ").first.map(String.init) ?? "" : name
                // Skip whole blocks whose content is never text.
                if !closing, ["script", "style", "head", "title", "xml"].contains(bare),
                   let end = lower.range(of: "</\(bare)", range: close ..< lower.endIndex) {
                    let after = lower[end.upperBound...].firstIndex(of: ">") ?? lower.endIndex
                    i = after < html.endIndex ? html.index(after: after) : html.endIndex
                    continue
                }
                switch bare {
                case "br", "p", "div", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "ul", "ol":
                    newline()
                    if ["h1", "h2", "h3", "h4"].contains(bare) { bold += closing ? -1 : 1; bold = max(0, bold) }
                case "li":
                    if !closing { newline(); text += "\u{2022} " }
                case "td", "th":
                    if !closing { text += " " }
                case "b", "strong":
                    flush()
                    bold = max(0, bold + (closing ? -1 : 1))
                case "a":
                    flush()
                    if closing {
                        link = nil
                    } else {
                        link = href(String(html[html.index(after: i) ..< close]))
                    }
                default:
                    break
                }
                i = html.index(after: close)
                continue
            }
            if c.isWhitespace {
                if let last = text.last, !last.isWhitespace { text.append(" ") }
                else if text.isEmpty, let prev = out.characters.last, !prev.isWhitespace { text.append(" ") }
            } else {
                text.append(c)
            }
            i = html.index(after: i)
        }
        flush()
        // Trim trailing whitespace/newlines.
        while let last = out.characters.last, last.isWhitespace {
            out.removeSubrange(out.characters.index(before: out.characters.endIndex) ..< out.characters.endIndex)
        }
        return out
    }

    /// `href="…"` of an anchor tag body, when the scheme is safe.
    static func href(_ tagBody: String) -> URL? {
        guard let r = tagBody.range(of: "href=", options: .caseInsensitive) else { return nil }
        var rest = tagBody[r.upperBound...]
        let quote = rest.first
        if quote == "\"" || quote == "'" { rest = rest.dropFirst() }
        let end = rest.firstIndex { $0 == quote || (quote != "\"" && quote != "'" && $0 == " ") } ?? rest.endIndex
        let raw = MessageRender.decodeEntities(String(rest[..<end]))
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else { return nil }
        return url
    }
}
