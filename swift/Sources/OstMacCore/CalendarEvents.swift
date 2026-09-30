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
    /// This entry is the signed-in user (matched by mail or UPN).
    public let isMe: Bool

    public init(name: String, email: String, type: String = "required", response: RSVPResponse = .none,
                isMe: Bool = false) {
        self.name = name
        self.email = email
        self.type = type
        self.response = response
        self.isMe = isMe
    }

    private enum CodingKeys: String, CodingKey { case name, email, type, response, isMe }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decode(String.self, forKey: .email)
        type = try c.decode(String.self, forKey: .type)
        response = try c.decode(RSVPResponse.self, forKey: .response)
        isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
    }

    public var isRoom: Bool { type == "resource" }
    public var typeLabel: String { type == "optional" ? "Optional" : "Required" }

    /// The one display format: "First Last" (never "Last, First", never
    /// a bare address when a name can be read from it).
    public var displayName: String { CalendarNames.display(name, email: email) }

    /// `displayName`, plus " (You)" on the signed-in user's own entry.
    public var label: String { isMe ? displayName + " (You)" : displayName }
}

/// One display-name format for every calendar surface.
public enum CalendarNames {
    /// "Last, First" → "First Last"; an address used as the name →
    /// the name read from its local part ("ann.lee@x" → "Ann Lee").
    public static func display(_ name: String?, email: String? = nil) -> String {
        let raw = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let address = raw.contains("@") ? raw : (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.contains("@") {
            guard let local = address.split(separator: "@").first.map(String.init), !address.isEmpty else { return raw }
            let words = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).map(String.init)
            guard words.count >= 2, words.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return address }
            return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].contains("(") {
            return parts[1] + " " + parts[0]
        }
        return raw
    }
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
    /// Graph `createdDateTime` as UTC wall clock (`yyyy-MM-dd'T'HH:mm:ss`):
    /// when the invitation landed in this calendar (Tracking "Sent on").
    public var sentAt: String?

    public init(
        location: String? = nil, myResponse: RSVPResponse = .none, showAs: String? = nil,
        kind: CalendarEventKind = .singleInstance, seriesMasterID: String? = nil,
        attendees: [EventAttendee] = [], originalStartTimeZone: String? = nil,
        isCancelled: Bool = false, hasAttachments: Bool = false, responseRequested: Bool = true,
        bodyPreview: String? = nil, webLink: String? = nil, sensitivity: String? = nil,
        reminderMinutes: Int? = nil, dialIn: EventDialIn? = nil, recurrence: String? = nil,
        sentAt: String? = nil
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
        self.sentAt = sentAt
    }

    /// People (rooms excluded).
    public var people: [EventAttendee] { attendees.filter { !$0.isRoom } }
    public var rooms: [EventAttendee] { attendees.filter(\.isRoom) }

    /// Response tally, Teams order.
    public struct Tally: Equatable, Sendable {
        public var accepted = 0, tentative = 0, declined = 0, pending = 0
        public var total: Int { accepted + tentative + declined + pending }
    }

    /// Tracking bucket (Teams order).
    public enum Bucket: String, CaseIterable, Sendable {
        case accepted, tentative, declined, pending

        public init(_ r: RSVPResponse) {
            switch r {
            case .accepted, .organizer: self = .accepted
            case .tentativelyAccepted: self = .tentative
            case .declined: self = .declined
            case .none, .notResponded: self = .pending
            }
        }

        public var title: String {
            switch self {
            case .accepted: "Accepted"
            case .tentative: "Tentative"
            case .declined: "Declined"
            case .pending: "Didn\u{2019}t respond"
            }
        }
    }

    public struct AttendeeGroup: Identifiable, Equatable, Sendable {
        public var id: String { bucket.rawValue }
        public let bucket: Bucket
        public let people: [EventAttendee]
        /// "Didn't respond: 3".
        public var header: String { "\(bucket.title): \(people.count)" }
    }

    /// Non-empty buckets of `people`, Teams order.
    public static func groups(_ people: [EventAttendee]) -> [AttendeeGroup] {
        Bucket.allCases.compactMap { b in
            let list = people.filter { Bucket($0.response) == b }
            return list.isEmpty ? nil : AttendeeGroup(bucket: b, people: list)
        }
    }

    /// Tally of `people` (callers pass `MeetingItem.invitees`: the
    /// organizer is never an attendee).
    public static func tally(_ people: [EventAttendee]) -> Tally {
        var t = Tally()
        for a in people {
            switch Bucket(a.response) {
            case .accepted: t.accepted += 1
            case .tentative: t.tentative += 1
            case .declined: t.declined += 1
            case .pending: t.pending += 1
            }
        }
        return t
    }

    /// Tally over people minus Graph's `organizer` entries (use
    /// `MeetingItem.tally`, which also drops the organizer by address).
    public var tally: Tally { Self.tally(people.filter { $0.response != .organizer }) }
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
    public var contentType: String?

    public init(id: String, name: String, size: Int, contentType: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.contentType = contentType
    }

    /// A safe file name for saving (no path separators, never empty).
    public var fileName: String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noDot = cleaned.drop { $0 == "." }
        return noDot.isEmpty ? "Attachment" : String(noDot)
    }
}

/// An edit to an existing event (Graph `PATCH /me/events/{id}`); nil
/// fields are left alone. `start`/`end` are local Graph datetimes in
/// `timeZone`. Subject/time/location/attendees are organizer edits;
/// show-as, reminder, categories and sensitivity are personal (any
/// copy of the event, organizer or attendee).
public struct CalendarEventPatch: Sendable, Equatable {
    public var subject: String?
    public var start: String?
    public var end: String?
    public var timeZone: String
    public var location: String?
    /// `free` | `tentative` | `busy` | `oof` | `workingElsewhere`.
    public var showAs: String?
    /// Minutes before start; a negative value turns the reminder off.
    public var reminderMinutes: Int?
    /// Outlook category names (replaces the event's list).
    public var categories: [String]?
    /// `normal` | `personal` | `private` | `confidential`.
    public var sensitivity: String?
    /// Full attendee list (Graph replaces it): room add / attendee
    /// removal by the organizer.
    public var attendees: [EventAttendee]?

    public init(subject: String? = nil, start: String? = nil, end: String? = nil,
                timeZone: String = TimeZone.current.identifier, location: String? = nil,
                showAs: String? = nil, reminderMinutes: Int? = nil, categories: [String]? = nil,
                sensitivity: String? = nil, attendees: [EventAttendee]? = nil) {
        self.subject = subject
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.location = location
        self.showAs = showAs
        self.reminderMinutes = reminderMinutes
        self.categories = categories
        self.sensitivity = sensitivity
        self.attendees = attendees
    }

    public var isEmpty: Bool { body.isEmpty }

    /// Only fields any attendee may change on their own copy.
    public var isPersonal: Bool {
        subject == nil && start == nil && end == nil && location == nil && attendees == nil
    }

    /// The PATCH body.
    public var body: [String: Any] {
        var b: [String: Any] = [:]
        if let subject { b["subject"] = subject }
        if let start { b["start"] = ["dateTime": start, "timeZone": timeZone] }
        if let end { b["end"] = ["dateTime": end, "timeZone": timeZone] }
        if let location { b["location"] = ["displayName": location] }
        if let showAs { b["showAs"] = showAs }
        if let reminderMinutes {
            b["isReminderOn"] = reminderMinutes >= 0
            if reminderMinutes >= 0 { b["reminderMinutesBeforeStart"] = reminderMinutes }
        }
        if let categories { b["categories"] = categories }
        if let sensitivity { b["sensitivity"] = sensitivity }
        if let attendees {
            b["attendees"] = attendees.map { a -> [String: Any] in
                ["type": a.type, "emailAddress": ["address": a.email, "name": a.name]]
            }
        }
        return b
    }

    /// `row` with this patch applied in memory (demo / optimistic).
    public func applied(to row: MeetingItem) -> MeetingItem {
        var m = row
        if let s = subject { m.subject = s }
        if let s = start { m.start = s }
        if let e = end { m.end = e }
        if let l = location { m.info?.location = l.isEmpty ? nil : l }
        if let s = showAs { m.info?.showAs = s }
        if let r = reminderMinutes { m.info?.reminderMinutes = r >= 0 ? r : nil }
        if let c = categories { m.categories = c }
        if let s = sensitivity { m.info?.sensitivity = s }
        if let a = attendees { m.info?.attendees = a }
        return m
    }
}

/// A new event with everything Duplicate carries over.
public struct CalendarEventDraft: Sendable, Equatable {
    public var subject: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var online: Bool
    public var location: String?
    /// People and rooms (organizer excluded).
    public var attendees: [EventAttendee]
    /// HTML body (Teams join block stripped: a new meeting gets its own).
    public var bodyHTML: String?
    public var categories: [String]
    public var showAs: String?
    public var reminderMinutes: Int?
    public var sensitivity: String?

    public init(subject: String, start: Date, end: Date, isAllDay: Bool = false, online: Bool = true,
                location: String? = nil, attendees: [EventAttendee] = [], bodyHTML: String? = nil,
                categories: [String] = [], showAs: String? = nil, reminderMinutes: Int? = nil,
                sensitivity: String? = nil) {
        self.subject = subject
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.online = online
        self.location = location
        self.attendees = attendees
        self.bodyHTML = bodyHTML
        self.categories = categories
        self.showAs = showAs
        self.reminderMinutes = reminderMinutes
        self.sensitivity = sensitivity
    }

    /// Duplicate of `m` (details `d` when read): same time, people,
    /// rooms, location, body and personal fields.
    /// `now` (when given) moves a past occurrence to the next day at the
    /// same time of day, so the copy is never born in the past.
    /// `myAddresses`: the signed-in user's mail/UPN, so the user's own
    /// entry never lands in the copy's attendees (entries also carry
    /// `isMe`).
    public static func duplicate(of m: MeetingItem, detail d: CalendarEventDetail?, calendar cal: Calendar = .current,
                                 now: Date? = nil, myAddresses: [String] = []) -> Self {
        let zone = cal.timeZone.identifier
        var start = CalendarTime.instant(m.start, zone: m.isAllDay ? "UTC" : zone) ?? Date()
        var end = CalendarTime.instant(m.end, zone: m.isAllDay ? "UTC" : zone) ?? start.addingTimeInterval(1800)
        if let now, !m.isAllDay, start < now {
            let parts = cal.dateComponents([.hour, .minute], from: start)
            if let next = cal.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) {
                end = next.addingTimeInterval(end.timeIntervalSince(start))
                start = next
            }
        }
        let mine = Set(myAddresses.map { $0.lowercased() })
        var people = m.invitees.filter { !$0.isMe && !mine.contains($0.email.lowercased()) } + (m.info?.rooms ?? [])
        // Copying someone else's invitation: the copy is yours, so the
        // original organizer becomes an attendee.
        if !m.isOrganizer, let org = m.organizerEmail, !org.isEmpty, !mine.contains(org.lowercased()),
           !people.contains(where: { $0.email.lowercased() == org.lowercased() }) {
            people.insert(EventAttendee(name: m.organizer ?? org, email: org), at: 0)
        }
        return CalendarEventDraft(
            subject: m.subject, start: start, end: end, isAllDay: m.isAllDay,
            online: m.joinURL?.isEmpty == false || m.isOnline,
            location: m.info?.location, attendees: people.map {
                EventAttendee(name: $0.name, email: $0.email, type: $0.type)
            },
            bodyHTML: d?.bodyHTML.map(stripTeamsBlock) ?? d?.bodyText, categories: m.categories,
            showAs: m.info?.showAs, reminderMinutes: m.info?.reminderMinutes, sensitivity: m.info?.sensitivity)
    }

    /// Body HTML up to the Teams join block (Outlook inserts it after a
    /// long underscore rule / "Microsoft Teams meeting" heading).
    public static func stripTeamsBlock(_ html: String) -> String {
        let lower = html.lowercased()
        var cuts = ["microsoft teams meeting", "microsoft teams need help", "________________"]
            .compactMap { lower.range(of: $0)?.lowerBound }
        // Webinar / town hall heading: only as a block (after a rule, or
        // followed by "Join"), so a body that opens with the words survives.
        for kind in ["webinar", "town hall"] {
            let head = "microsoft teams \(kind)"
            var from = lower.startIndex
            while let r = lower.range(of: head, range: from ..< lower.endIndex) {
                let before = lower[..<r.lowerBound]
                let after = lower[r.upperBound...].replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                let afterText = after.trimmingCharacters(in: .whitespacesAndNewlines)
                let rule = String(before).range(of: "<hr[^>]*>\\s*(<(h\\d|p|b|strong|div|span)[^>]*>\\s*)*$",
                                                options: [.regularExpression])
                let afterRule = before.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("_")
                if rule != nil || afterRule || afterText.hasPrefix("join") {
                    var c = r.lowerBound
                    if let rule { c = rule.lowerBound }
                    cuts.append(c)
                    break
                }
                from = r.upperBound
            }
        }
        guard let cut = cuts.min() else { return html }
        let offset = lower.distance(from: lower.startIndex, to: cut)
        return String(html.prefix(offset))
    }

    /// The Graph create body; timed events in `tz`, all-day floating.
    public func body(in tz: TimeZone) -> [String: Any] {
        let zone = isAllDay ? TimeZone(identifier: "UTC")! : tz
        var b: [String: Any] = [
            "subject": subject,
            "start": ["dateTime": CalendarTime.wallClock(start, in: zone), "timeZone": zone.identifier],
            "end": ["dateTime": CalendarTime.wallClock(end, in: zone), "timeZone": zone.identifier],
            "isAllDay": isAllDay,
            "attendees": attendees.map { ["type": $0.type, "emailAddress": ["address": $0.email, "name": $0.name]] },
            "categories": categories,
        ]
        if online {
            b["isOnlineMeeting"] = true
            b["onlineMeetingProvider"] = "teamsForBusiness"
        }
        if let location, !location.isEmpty { b["location"] = ["displayName": location] }
        if let bodyHTML, !bodyHTML.isEmpty { b["body"] = ["contentType": "html", "content": bodyHTML] }
        if let showAs { b["showAs"] = showAs }
        if let reminderMinutes {
            b["isReminderOn"] = true
            b["reminderMinutesBeforeStart"] = reminderMinutes
        }
        if let sensitivity { b["sensitivity"] = sensitivity }
        return b
    }
}

/// An Outlook color category (`/me/outlook/masterCategories`).
public struct CalendarCategory: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    /// `preset0`…`preset24` or `none`.
    public let color: String

    public init(name: String, color: String = "none") {
        self.name = name
        self.color = color
    }

    /// Outlook's default list (used when the master list can't be read).
    public static let defaults: [CalendarCategory] = [
        .init(name: "Blue category", color: "preset7"), .init(name: "Green category", color: "preset4"),
        .init(name: "Orange category", color: "preset1"), .init(name: "Purple category", color: "preset8"),
        .init(name: "Red category", color: "preset0"), .init(name: "Yellow category", color: "preset3"),
    ]

    /// `defaults` plus any name already used on `rows`, deduplicated.
    public static func merged(_ master: [CalendarCategory]?, seen rows: [MeetingItem]) -> [CalendarCategory] {
        var out = master?.isEmpty == false ? master! : defaults
        var names = Set(out.map { $0.name.lowercased() })
        for name in rows.flatMap(\.categories) where names.insert(name.lowercased()).inserted {
            out.append(CalendarCategory(name: name))
        }
        return out
    }
}

/// One person's free/busy over a window (Graph `getSchedule`).
public struct CalendarFreeBusy: Sendable, Equatable {
    public struct Block: Sendable, Equatable {
        /// `free` | `tentative` | `busy` | `oof` | `workingElsewhere`.
        public let status: String
        public let start: Date
        public let end: Date

        public init(status: String, start: Date, end: Date) {
            self.status = status
            self.start = start
            self.end = end
        }

        /// Counts against a suggested time.
        public var blocks: Bool { status == "busy" || status == "oof" || status == "tentative" }
    }

    public let email: String
    public let blocks: [Block]
    /// The calendar could not be read (Graph `error` on the schedule).
    public let unavailable: Bool

    public init(email: String, blocks: [Block], unavailable: Bool = false) {
        self.email = email
        self.blocks = blocks
        self.unavailable = unavailable
    }

    /// One candidate slot with the people blocked during it.
    public struct Suggestion: Equatable, Sendable {
        public let slot: DateInterval
        public let conflicts: [String]  // emails
    }

    /// Slots inside working hours (weekdays, ends by `hours.upperBound`),
    /// ranked by fewest conflicts then earliest; at most `limit`.
    public static func rankedSuggestions(_ people: [CalendarFreeBusy], from: Date, to: Date, length: TimeInterval,
                                         step: Int = 30, hours: Range<Int> = 8 ..< 17, limit: Int = 4,
                                         calendar cal: Calendar = .current) -> [Suggestion] {
        var all: [Suggestion] = []
        var t = cal.dateInterval(of: .hour, for: from)?.start ?? from
        while t < from { t = t.addingTimeInterval(TimeInterval(step * 60)) }
        while t.addingTimeInterval(length) <= to {
            let slot = DateInterval(start: t, duration: length)
            let comps = cal.dateComponents([.hour, .weekday], from: t)
            let endComps = cal.dateComponents([.hour, .minute], from: slot.end)
            let weekday = comps.weekday.map { $0 != 1 && $0 != 7 } ?? true
            let endMinutes = (endComps.hour ?? 0) * 60 + (endComps.minute ?? 0)
            let inHours = (comps.hour ?? 0) >= hours.lowerBound && endMinutes <= hours.upperBound * 60
                && cal.isDate(t, inSameDayAs: slot.end.addingTimeInterval(-1))
            if weekday, inHours {
                let busy = people.filter { p in
                    p.blocks.contains { $0.blocks && $0.start < slot.end && $0.end > slot.start }
                }.map(\.email)
                all.append(Suggestion(slot: slot, conflicts: busy))
            }
            t = t.addingTimeInterval(TimeInterval(step * 60))
        }
        let ranked = all.enumerated().sorted {
            ($0.element.conflicts.count, $0.offset) < ($1.element.conflicts.count, $1.offset)
        }.prefix(limit).map(\.element)
        return ranked
    }

    /// Free `[start, start+length)` slots inside working hours where
    /// nobody readable is blocked, stepping `step` minutes; at most
    /// `limit`. Working hours are `hours` in `calendar`'s zone, weekdays only.
    public static func suggestions(_ people: [CalendarFreeBusy], from: Date, to: Date, length: TimeInterval,
                                   step: Int = 30, hours: Range<Int> = 8 ..< 17, limit: Int = 5,
                                   calendar cal: Calendar = .current) -> [DateInterval] {
        var out: [DateInterval] = []
        var t = cal.dateInterval(of: .hour, for: from)?.start ?? from
        while t < from { t = t.addingTimeInterval(TimeInterval(step * 60)) }
        while t.addingTimeInterval(length) <= to, out.count < limit {
            let slot = DateInterval(start: t, duration: length)
            let comps = cal.dateComponents([.hour, .minute, .weekday], from: t)
            let endComps = cal.dateComponents([.hour, .minute], from: slot.end)
            let weekday = comps.weekday.map { $0 != 1 && $0 != 7 } ?? true
            let endMinutes = (endComps.hour ?? 0) * 60 + (endComps.minute ?? 0)
            let inHours = (comps.hour ?? 0) >= hours.lowerBound && endMinutes <= hours.upperBound * 60
                && cal.isDate(t, inSameDayAs: slot.end.addingTimeInterval(-1))
            if weekday, inHours {
                let clash = people.contains { p in
                    p.blocks.contains { b in b.blocks && b.start < slot.end && b.end > slot.start }
                }
                if !clash { out.append(slot) }
            }
            t = t.addingTimeInterval(TimeInterval(step * 60))
        }
        return out
    }
}

/// Event type as Teams shows it (read from the invitation's own words:
/// Graph has no type field for webinars / town halls).
public enum CalendarEventType: String, Sendable, Equatable {
    case meeting, webinar, townHall, appointment

    public var title: String {
        switch self {
        case .meeting: "Meeting"
        case .webinar: "Webinar"
        case .townHall: "Town hall"
        case .appointment: "Appointment"
        }
    }

    public var symbol: String {
        switch self {
        case .meeting: "person.2"
        case .webinar: "person.wave.2"
        case .townHall: "megaphone"
        case .appointment: "calendar"
        }
    }

    /// From subject/body text (preview or full body) and the attendees.
    public static func detect(isOnline: Bool, joinURL: String?, text: String?, hasAttendees: Bool) -> Self {
        let t = ((text ?? "") + "\n" + (joinURL ?? "")).lowercased()
        if t.contains("microsoft teams webinar") || t.contains("teams webinar") || t.contains("register for this webinar")
            || t.contains("events.teams.microsoft.com/event/") {
            return .webinar
        }
        if t.contains("microsoft teams town hall") || t.contains("teams town hall") || t.contains("microsoft teams live event") {
            return .townHall
        }
        if isOnline || joinURL?.isEmpty == false || hasAttendees { return .meeting }
        return .appointment
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
    let createdDateTime: String?
}

public enum CalendarEvents {
    /// `$select` for the calendarView read (list, grid, inspector).
    public static let listSelect = [
        "id", "subject", "start", "end", "isAllDay", "isOnlineMeeting", "onlineMeeting",
        "organizer", "isOrganizer", "webLink", "categories", "location", "locations",
        "attendees", "responseStatus", "showAs", "type", "seriesMasterId", "recurrence",
        "originalStartTimeZone", "isCancelled", "hasAttachments", "responseRequested",
        "isReminderOn", "reminderMinutesBeforeStart", "sensitivity", "bodyPreview", "createdDateTime",
    ].joined(separator: ",")

    /// `$select` for the details read (adds the body).
    public static let detailSelect = listSelect + ",body"

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// One wire event → a local row (`tz` = the display zone; `me` =
    /// the signed-in address: that attendee's entry shows the user's own
    /// response, which Graph keeps on `responseStatus`, not the list).
    static func item(_ e: GraphEventWire, tz: TimeZone = .current, me: String? = nil,
                     meAliases: [String] = []) -> MeetingItem {
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
        let mine = RSVPResponse(graph: e.responseStatus?.response)
        let self_ = me.flatMap(nonEmpty)?.lowercased()
        let mine_ = Set(([me] + meAliases).compactMap { $0.flatMap(nonEmpty)?.lowercased() })
        let attendees = (e.attendees ?? []).map { a in
            let address = a.emailAddress?.address ?? ""
            var response = RSVPResponse(graph: a.status?.response)
            if let self_, address.lowercased() == self_, !mine.isPending, mine != .organizer { response = mine }
            return EventAttendee(name: nonEmpty(a.emailAddress?.name) ?? a.emailAddress?.address ?? "",
                                 email: address, type: a.type ?? "required", response: response,
                                 isMe: mine_.contains(address.lowercased()))
        }
        let online = e.onlineMeeting
        let dialIn: EventDialIn? = online.flatMap {
            nonEmpty($0.tollNumber) == nil && nonEmpty($0.conferenceId) == nil ? nil
                : EventDialIn(tollNumber: nonEmpty($0.tollNumber), conferenceID: nonEmpty($0.conferenceId),
                              quickDial: nonEmpty($0.quickDial))
        }
        let info = CalendarEventInfo(
            location: location,
            myResponse: mine,
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
            recurrence: e.recurrence.map(recurrenceSummary),
            sentAt: CalendarTime.instant(e.createdDateTime, zone: "UTC")
                .map { CalendarTime.wallClock($0, in: TimeZone(identifier: "UTC")!) })
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
    static func page(_ data: Data, tz: TimeZone = .current, me: String? = nil,
                     meAliases: [String] = []) throws -> (rows: [MeetingItem], next: String?) {
        struct Page: Decodable {
            let value: [GraphEventWire]
            let next: String?
            enum CodingKeys: String, CodingKey {
                case value
                case next = "@odata.nextLink"
            }
        }
        let p = try JSONDecoder().decode(Page.self, from: data)
        return (p.value.map { item($0, tz: tz, me: me, meAliases: meAliases) }.filter { $0.info?.isCancelled != true }, p.next)
    }

    /// One event → row.
    static func single(_ data: Data, tz: TimeZone = .current, me: String? = nil,
                       meAliases: [String] = []) throws
        -> (row: MeetingItem, body: GraphEventWire.Body?) {
        let w = try JSONDecoder().decode(GraphEventWire.self, from: data)
        return (item(w, tz: tz, me: me, meAliases: meAliases), w.body)
    }

    /// `getSchedule` reply → per-person blocks (UTC wall clock in).
    static func schedule(_ data: Data) throws -> [CalendarFreeBusy] {
        struct R: Decodable {
            struct Item: Decodable {
                let status: String?
                let start: GraphEventWire.DTZ?
                let end: GraphEventWire.DTZ?
            }
            struct Err: Decodable { let message: String? }
            struct S: Decodable {
                let scheduleId: String?
                let scheduleItems: [Item]?
                let error: Err?
            }
            let value: [S]
        }
        return try JSONDecoder().decode(R.self, from: data).value.map { s in
            CalendarFreeBusy(
                email: s.scheduleId ?? "",
                blocks: (s.scheduleItems ?? []).compactMap { i in
                    guard let a = CalendarTime.instant(i.start?.dateTime, zone: i.start?.timeZone ?? "UTC"),
                          let b = CalendarTime.instant(i.end?.dateTime, zone: i.end?.timeZone ?? "UTC") else { return nil }
                    return .init(status: i.status ?? "busy", start: a, end: b)
                },
                unavailable: s.error != nil)
        }
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

    /// Invited people: rooms and the organizer excluded (Graph lists the
    /// organizer with response `organizer`, or by address). The header
    /// counts, the attendee row and the Tracking groups all read this.
    public var invitees: [EventAttendee] {
        let org = organizerEmail?.lowercased()
        return (info?.people ?? []).filter { a in
            a.response != .organizer && !(org != nil && !a.email.isEmpty && a.email.lowercased() == org)
        }
    }

    public var tally: CalendarEventInfo.Tally { CalendarEventInfo.tally(invitees) }

    /// The organizer in the one display format.
    public var organizerDisplay: String? {
        guard let o = organizer, !o.isEmpty else { return nil }
        return CalendarNames.display(o, email: organizerEmail)
    }

    /// Meeting / webinar / town hall / appointment.
    public func eventType(body: String? = nil) -> CalendarEventType {
        CalendarEventType.detect(isOnline: isOnline, joinURL: joinURL,
                                 text: [subject, info?.bodyPreview, body].compactMap { $0 }.joined(separator: "\n"),
                                 hasAttendees: !invitees.isEmpty)
    }

    public var eventType: CalendarEventType { eventType() }

    /// "Sent on" instant (Graph `createdDateTime`).
    public var sentDate: Date? { CalendarTime.instant(info?.sentAt, zone: "UTC") }
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
