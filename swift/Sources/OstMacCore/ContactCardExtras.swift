// ContactCardExtras.swift — the card's calendar-backed fields (local
// time, availability, working hours) and files the person shared.
//
// Other people's mailbox settings aren't readable with the Teams client
// token (MailboxSettings.ReadWrite is own-mailbox only), but the
// calendar free/busy query is (Calendars.Read):
//
//   POST /me/calendar/getSchedule   {"schedules":[mail], startTime, endTime}
//   → value[0].workingHours.timeZone.name  (their zone)
//     value[0].scheduleItems[]             (busy/tentative/oof slots, UTC)
//
// The query is a read (no calendar change). Files come from Graph item
// insights (Sites.Read.All via Sites.ReadWrite.All):
//
//   GET /me/insights/shared?$filter=lastShared/sharedBy/address eq '<mail>'
import Foundation

/// Free/busy right now plus the person's zone and working hours.
public struct ContactSchedule: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case free, busy, tentative, outOfOffice, workingElsewhere
    }

    /// IANA zone id (Windows zone names are mapped); nil when unknown.
    public var timeZoneID: String?
    /// Working hours start/end in the person's zone ("09:00:00").
    public var workStart: String?
    public var workEnd: String?
    public var state: State
    /// When the current state ends (nil = not today / unknown).
    public var until: Date?

    public init(timeZoneID: String? = nil, workStart: String? = nil, workEnd: String? = nil,
                state: State = .free, until: Date? = nil) {
        self.timeZoneID = timeZoneID; self.workStart = workStart; self.workEnd = workEnd
        self.state = state; self.until = until
    }

    public var timeZone: TimeZone? { timeZoneID.flatMap(TimeZone.init(identifier:)) }
}

/// One file the person shared with the signed-in user.
public struct ContactSharedFile: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Office type from insights ("Word", "Excel", "PowerPoint", "Pdf", …).
    public let type: String?
    public let webURL: URL?
    public let sharedAt: Date?

    public init(id: String, title: String, type: String? = nil, webURL: URL? = nil, sharedAt: Date? = nil) {
        self.id = id; self.title = title; self.type = type; self.webURL = webURL; self.sharedAt = sharedAt
    }
}

public enum ContactExtrasReads {
    public static let schedulePath = "/me/calendar/getSchedule"
    static let fileLimit = 10

    /// Sync POST seam (tests inject; production uses URLSession).
    typealias Poster = @Sendable (_ url: URL, _ headers: [String: String], _ body: Data) throws
        -> ReadHTTPResponse

    static let livePoster: Poster = { url, headers, body in
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let request = req
        return try SyncBridge.run {
            let (data, resp) = try await URLSession.shared.data(for: request)
            return ReadHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        }
    }

    // MARK: schedule

    /// getSchedule body: now → +18 h, 30-min view.
    public static func scheduleBody(mail: String, now: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let obj: [String: Any] = [
            "schedules": [mail],
            "startTime": ["dateTime": f.string(from: now.addingTimeInterval(-60)), "timeZone": "UTC"],
            "endTime": ["dateTime": f.string(from: now.addingTimeInterval(18 * 3600)), "timeZone": "UTC"],
            "availabilityViewInterval": 30,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// Parse one getSchedule reply (first schedule). Nil when the
    /// schedule carries an error (other tenant, no mailbox, denied): that
    /// means "no schedule for this person", not a failed read (a failed
    /// request throws in `schedule` and shows on the card).
    public static func parseSchedule(_ data: Data, now: Date) -> ContactSchedule? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["value"] as? [[String: Any]])?.first,
              first["error"] == nil
        else { return nil }
        var out = ContactSchedule()
        if let wh = first["workingHours"] as? [String: Any] {
            let zoneName = (wh["timeZone"] as? [String: Any])?["name"] as? String
            out.timeZoneID = zoneName.flatMap(WindowsTimeZones.ianaID(for:))
            out.workStart = (wh["startTime"] as? String).map { String($0.prefix(8)) }
            out.workEnd = (wh["endTime"] as? String).map { String($0.prefix(8)) }
        }
        struct Slot { let start: Date; let end: Date; let state: ContactSchedule.State }
        let slots: [Slot] = ((first["scheduleItems"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let s = (item["start"] as? [String: Any])?["dateTime"] as? String,
                  let e = (item["end"] as? [String: Any])?["dateTime"] as? String,
                  let start = ContactReads.graphDate(s), let end = ContactReads.graphDate(e), end > start
            else { return nil }
            let state: ContactSchedule.State
            switch (item["status"] as? String ?? "").lowercased() {
            case "busy": state = .busy
            case "tentative": state = .tentative
            case "oof": state = .outOfOffice
            case "workingelsewhere": state = .workingElsewhere
            default: return nil
            }
            return Slot(start: start, end: end, state: state)
        }.sorted { $0.start < $1.start }
        let rank: [ContactSchedule.State: Int] = [.outOfOffice: 4, .busy: 3, .tentative: 2, .workingElsewhere: 1]
        let current = slots.filter { $0.start <= now && now < $0.end }
        if let top = current.max(by: { rank[$0.state, default: 0] < rank[$1.state, default: 0] }) {
            out.state = top.state
            // Extend through back-to-back slots of any busy kind.
            var end = current.map(\.end).max() ?? top.end
            for s in slots where s.start <= end && s.end > end { end = s.end }
            out.until = end
        } else {
            out.state = .free
            out.until = slots.first { $0.start > now }?.start
        }
        return out
    }

    // MARK: files

    public static func filesPath(sharedBy mail: String) -> String {
        let escaped = mail.replacingOccurrences(of: "'", with: "''")
        let filter = "lastShared/sharedBy/address eq '\(escaped)'"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+'/$")
        let enc = filter.addingPercentEncoding(withAllowedCharacters: allowed) ?? filter
        return "/me/insights/shared?$filter=\(enc)&$top=\(fileLimit)"
    }

    public static func parseFiles(_ data: Data) -> [ContactSharedFile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = root["value"] as? [[String: Any]]
        else { return [] }
        var seen = Set<String>()
        return value.compactMap { item in
            let vis = item["resourceVisualization"] as? [String: Any]
            let ref = item["resourceReference"] as? [String: Any]
            guard let title = (vis?["title"] as? String)?.nonBlank else { return nil }
            let id = (item["id"] as? String) ?? (ref?["id"] as? String) ?? title
            guard seen.insert(id).inserted else { return nil }
            let shared = (item["lastShared"] as? [String: Any])?["sharedDateTime"] as? String
            return ContactSharedFile(
                id: id, title: title, type: (vis?["type"] as? String)?.nonBlank,
                webURL: (ref?["webUrl"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                sharedAt: shared.flatMap(UnifiedPresence.isoDate))
        }
        .sorted { ($0.sharedAt ?? .distantPast) > ($1.sharedAt ?? .distantPast) }
    }

    // MARK: fetch (blocking, best-effort)

    /// Throws on a transport failure or non-2xx; nil only when the calendar
    /// answered with no usable schedule.
    static func schedule(mail: String, token: String, post: Poster, now: Date) throws -> ContactSchedule? {
        guard let url = URL(string: CoreReads.graphBase + schedulePath) else { return nil }
        let resp = try post(url, [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Prefer": "outlook.timezone=\"UTC\"",
        ], scheduleBody(mail: mail, now: now))
        guard (200..<300).contains(resp.status) else { throw CoreCallError.failed("schedule: HTTP \(resp.status)") }
        return parseSchedule(resp.data, now: now)
    }

    /// Throws when the read fails; `[]` only when Teams said none.
    static func files(mail: String, token: String, http: any ReadFetcher) throws -> [ContactSharedFile]? {
        let data = try CoreReads.graphGET(filesPath(sharedBy: mail), code: "contact", token: token, http: http)
        // An answer with no `value` list is unreadable, not "no files".
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["value"] is [Any]
        else { throw CoreCallError.failed("files: unreadable answer") }
        return parseFiles(data)
    }
}

/// Windows zone names (Exchange working hours) → IANA ids. The common
/// zones from the CLDR windowsZones table; IANA input passes through.
public enum WindowsTimeZones {
    static let table: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12", "UTC-11": "Etc/GMT+11",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Alaskan Standard Time": "America/Anchorage",
        "Pacific Standard Time": "America/Los_Angeles", "Pacific Standard Time (Mexico)": "America/Tijuana",
        "US Mountain Standard Time": "America/Phoenix", "Mountain Standard Time": "America/Denver",
        "Central America Standard Time": "America/Guatemala", "Central Standard Time": "America/Chicago",
        "Central Standard Time (Mexico)": "America/Mexico_City", "Canada Central Standard Time": "America/Regina",
        "SA Pacific Standard Time": "America/Bogota", "Eastern Standard Time": "America/New_York",
        "US Eastern Standard Time": "America/Indianapolis", "Eastern Standard Time (Mexico)": "America/Cancun",
        "Atlantic Standard Time": "America/Halifax", "Venezuela Standard Time": "America/Caracas",
        "SA Western Standard Time": "America/La_Paz", "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns", "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Buenos_Aires", "SA Eastern Standard Time": "America/Cayenne",
        "Greenland Standard Time": "America/Godthab", "UTC-02": "Etc/GMT+2",
        "Azores Standard Time": "Atlantic/Azores", "Cape Verde Standard Time": "Atlantic/Cape_Verde",
        "UTC": "Etc/UTC", "Coordinated Universal Time": "Etc/UTC", "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik", "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest", "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw", "W. Central Africa Standard Time": "Africa/Lagos",
        "GTB Standard Time": "Europe/Bucharest", "Middle East Standard Time": "Asia/Beirut",
        "Egypt Standard Time": "Africa/Cairo", "E. Europe Standard Time": "Europe/Chisinau",
        "South Africa Standard Time": "Africa/Johannesburg", "FLE Standard Time": "Europe/Kiev",
        "Israel Standard Time": "Asia/Jerusalem", "Turkey Standard Time": "Europe/Istanbul",
        "Arabic Standard Time": "Asia/Baghdad", "Arab Standard Time": "Asia/Riyadh",
        "Russian Standard Time": "Europe/Moscow", "E. Africa Standard Time": "Africa/Nairobi",
        "Iran Standard Time": "Asia/Tehran", "Arabian Standard Time": "Asia/Dubai",
        "Afghanistan Standard Time": "Asia/Kabul", "Pakistan Standard Time": "Asia/Karachi",
        "India Standard Time": "Asia/Calcutta", "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Katmandu", "Bangladesh Standard Time": "Asia/Dhaka",
        "Myanmar Standard Time": "Asia/Rangoon", "SE Asia Standard Time": "Asia/Bangkok",
        "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth", "Taipei Standard Time": "Asia/Taipei",
        "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "Cen. Australia Standard Time": "Australia/Adelaide", "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane", "AUS Eastern Standard Time": "Australia/Sydney",
        "Tasmania Standard Time": "Australia/Hobart", "West Pacific Standard Time": "Pacific/Port_Moresby",
        "New Zealand Standard Time": "Pacific/Auckland", "Fiji Standard Time": "Pacific/Fiji",
    ]

    public static func ianaID(for name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let hit = table[n] { return hit }
        return TimeZone(identifier: n) != nil ? n : nil
    }
}

// MARK: - Profile and LinkedIn tabs
//
// Profile tab: the SharePoint user-profile fields Graph exposes on a
// single-user GET (User.ReadBasic.All is enough for these):
//
//   GET /users/{id}?$select=aboutMe,birthday,hireDate,skills,interests,
//                           schools,pastProjects,responsibilities
//
// Unset dates come back as year 0001; unset lists as []. LinkedIn tab:
// the persona card service's lookup (the call Teams' card makes):
//
//   GET https://nam.loki.delve.office.com/api/v1/linkedin/profiles/full
//       ?AadObjectId=&Smtp=&PersonaType=User&UserLocale=&ExternalPageInstance=
//   → bound (viewer linked their LinkedIn account), bindUrl, joinNowUrl,
//     persons[] (matched public profiles when bound)

/// The Profile tab's fields; empty ones are nil or [].
public struct ContactAbout: Sendable, Equatable {
    public var aboutMe: String?
    public var birthday: Date?
    public var hireDate: Date?
    public var skills: [String]
    public var interests: [String]
    public var schools: [String]
    public var pastProjects: [String]
    public var responsibilities: [String]

    public init(aboutMe: String? = nil, birthday: Date? = nil, hireDate: Date? = nil, skills: [String] = [],
                interests: [String] = [], schools: [String] = [], pastProjects: [String] = [],
                responsibilities: [String] = []) {
        self.aboutMe = aboutMe; self.birthday = birthday; self.hireDate = hireDate; self.skills = skills
        self.interests = interests; self.schools = schools; self.pastProjects = pastProjects
        self.responsibilities = responsibilities
    }

    public var isEmpty: Bool {
        aboutMe == nil && birthday == nil && hireDate == nil && skills.isEmpty && interests.isEmpty
            && schools.isEmpty && pastProjects.isEmpty && responsibilities.isEmpty
    }
}

/// The LinkedIn tab: a matched public profile when the viewer has
/// linked their account, else the links Teams offers.
public struct ContactLinkedIn: Sendable, Equatable {
    public var bound: Bool
    public var profileURL: URL?
    public var bindURL: URL?
    public var joinURL: URL?

    public init(bound: Bool, profileURL: URL? = nil, bindURL: URL? = nil, joinURL: URL? = nil) {
        self.bound = bound; self.profileURL = profileURL; self.bindURL = bindURL; self.joinURL = joinURL
    }

    /// People search on LinkedIn (what the tab offers without a match).
    public static func searchURL(name: String, company: String?) -> URL? {
        var q = URLComponents(string: "https://www.linkedin.com/search/results/people/")!
        q.queryItems = [URLQueryItem(name: "keywords", value: [name, company ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " "))]
        return q.url
    }
}

extension ContactExtrasReads {
    public static let aboutSelect = "aboutMe,birthday,hireDate,skills,interests,schools,pastProjects,responsibilities"
    public static let lokiResource = "https://loki.delve.office.com"

    public static func parseAbout(_ data: Data) -> ContactAbout? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func list(_ k: String) -> [String] {
            ((o[k] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        func date(_ k: String) -> Date? {
            guard let s = o[k] as? String else { return nil }
            let iso = ISO8601DateFormatter()
            guard let d = iso.date(from: s) ?? ContactReads.graphDate(String(s.prefix(19))) else { return nil }
            // Unset profile dates are year 0001.
            return Calendar(identifier: .gregorian).component(.year, from: d) < 1900 ? nil : d
        }
        let about = (o["aboutMe"] as? String).map(ContactReads.plainText).flatMap { $0.isEmpty ? nil : $0 }
        return ContactAbout(aboutMe: about, birthday: date("birthday"), hireDate: date("hireDate"),
                            skills: list("skills"), interests: list("interests"), schools: list("schools"),
                            pastProjects: list("pastProjects"), responsibilities: list("responsibilities"))
    }

    /// Throws when the read fails; nil when the profile has no about data.
    static func about(id: String, token: String, http: any ReadFetcher) throws -> ContactAbout? {
        let data = try CoreReads.graphGET(ContactReads.userPath(id) + "?$select=" + aboutSelect,
                                          code: "contact", token: token, http: http)
        return parseAbout(data)
    }

    public static func linkedInURL(id: String, mail: String, instance: UUID = UUID()) -> URL? {
        var q = URLComponents(string: "https://nam.loki.delve.office.com/api/v1/linkedin/profiles/full")!
        q.queryItems = [URLQueryItem(name: "AadObjectId", value: id), URLQueryItem(name: "Smtp", value: mail),
                        URLQueryItem(name: "PersonaType", value: "User"), URLQueryItem(name: "UserLocale", value: "en-US"),
                        URLQueryItem(name: "ExternalPageInstance", value: instance.uuidString)]
        return q.url
    }

    /// The first linkedin.com/in/ link anywhere in a matched person.
    public static func parseLinkedIn(_ data: Data) -> ContactLinkedIn? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func url(_ k: String) -> URL? { (o[k] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } }
        func profile(_ v: Any) -> URL? {
            if let s = v as? String, s.hasPrefix("https://"), s.contains("linkedin.com/in/") { return URL(string: s) }
            if let d = v as? [String: Any] { for k in d.keys.sorted() { if let u = profile(d[k]!) { return u } } }
            if let a = v as? [Any] { for e in a { if let u = profile(e) { return u } } }
            return nil
        }
        let persons = (o["persons"] as? [Any]) ?? []
        return ContactLinkedIn(bound: (o["bound"] as? Bool) ?? false,
                               profileURL: persons.first.flatMap(profile),
                               bindURL: url("bindUrl"), joinURL: url("joinNowUrl"))
    }

    static func linkedIn(id: String, mail: String, token: String, http: any ReadFetcher) -> ContactLinkedIn? {
        guard let u = linkedInURL(id: id, mail: mail),
              let resp = try? http.get(url: u, headers: [
                  "Authorization": "Bearer " + token, "Accept": "application/json",
                  "X-ClientType": "Teams", "X-ClientFeature": "LivePersonaCard",
              ]),
              (200..<300).contains(resp.status)
        else { return nil }
        return parseLinkedIn(resp.data)
    }
}
