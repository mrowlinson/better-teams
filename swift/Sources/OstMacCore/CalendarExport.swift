// CalendarExport.swift — CALDETAIL: the details popup's Download (.ics,
// RFC 5545) and Print (plain-text sheet) renderings of one event.
import Foundation

public enum CalendarExport {
    // MARK: .ics

    /// One VEVENT in a VCALENDAR. Timed events in UTC (`Z`), all-day as
    /// floating DATE values; text escaped and folded at 75 octets.
    public static func ics(_ m: MeetingItem, detail d: CalendarEventDetail? = nil, now: Date = Date(),
                           calendar cal: Calendar = .current) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Better Teams//Calendar//EN", "METHOD:PUBLISH",
                     "BEGIN:VEVENT"]
        lines.append("UID:" + escape(m.meetingId))
        lines.append("DTSTAMP:" + utc(now))
        if m.isAllDay {
            if let s = m.start { lines.append("DTSTART;VALUE=DATE:" + dateOnly(s)) }
            if let e = m.end { lines.append("DTEND;VALUE=DATE:" + dateOnly(e)) }
        } else {
            let zone = cal.timeZone.identifier
            if let s = instant(m, m.utcStart, m.start, zone) { lines.append("DTSTART:" + utc(s)) }
            if let e = instant(m, m.utcEnd, m.end, zone) { lines.append("DTEND:" + utc(e)) }
        }
        lines.append("SUMMARY:" + escape(m.subject))
        if let place = m.info?.location { lines.append("LOCATION:" + escape(place)) }
        var description = d?.bodyHTML.map { String(EventBodyRender.attributed(html: $0).characters) }
            ?? d?.bodyText ?? m.info?.bodyPreview ?? ""
        if let join = m.joinURL, !join.isEmpty, !description.contains(join) {
            description += (description.isEmpty ? "" : "\n\n") + "Join the Teams meeting: " + join
        }
        if !description.isEmpty { lines.append("DESCRIPTION:" + escape(description)) }
        if let join = m.joinURL, !join.isEmpty { lines.append("URL:" + join) }
        if let org = m.organizerEmail {
            lines.append("ORGANIZER;CN=" + param(m.organizerDisplay ?? org) + ":mailto:" + org)
        }
        for a in m.invitees where !a.email.isEmpty {
            let role = a.type == "optional" ? "OPT-PARTICIPANT" : "REQ-PARTICIPANT"
            lines.append("ATTENDEE;CN=\(param(a.displayName));ROLE=\(role);PARTSTAT=\(partstat(a.response)):mailto:\(a.email)")
        }
        if !m.categories.isEmpty { lines.append("CATEGORIES:" + m.categories.map(escape).joined(separator: ",")) }
        switch m.info?.sensitivity {
        case "private", "personal": lines.append("CLASS:PRIVATE")
        case "confidential": lines.append("CLASS:CONFIDENTIAL")
        default: lines.append("CLASS:PUBLIC")
        }
        lines.append("TRANSP:" + (m.info?.showAs == "free" ? "TRANSPARENT" : "OPAQUE"))
        if let r = m.info?.reminderMinutes {
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:Reminder", "TRIGGER:-PT\(r)M", "END:VALARM"]
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// "Subject.ics" with path-hostile characters replaced.
    public static func icsFileName(_ m: MeetingItem) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|").union(.newlines)
        let stem = m.subject.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return (stem.isEmpty ? "Event" : String(stem.prefix(80))) + ".ics"
    }

    static func instant(_ m: MeetingItem, _ utcWall: String?, _ local: String?, _ zone: String) -> Date? {
        CalendarTime.instant(utcWall, zone: "UTC") ?? CalendarTime.instant(local, zone: zone)
    }

    static func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    static func dateOnly(_ wall: String) -> String {
        String(wall.prefix(10)).replacingOccurrences(of: "-", with: "")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Parameter value (CN): quoted when it holds `:;,`, quotes dropped.
    static func param(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
        return clean.rangeOfCharacter(from: CharacterSet(charactersIn: ":;,")) == nil ? clean : "\"\(clean)\""
    }

    static func partstat(_ r: RSVPResponse) -> String {
        switch r {
        case .accepted, .organizer: "ACCEPTED"
        case .tentativelyAccepted: "TENTATIVE"
        case .declined: "DECLINED"
        case .none, .notResponded: "NEEDS-ACTION"
        }
    }

    /// Lines longer than 75 octets continue on "\r\n " lines (never
    /// splitting a UTF-8 sequence).
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out: [String] = []
        var current = ""
        var size = 0
        for ch in line {
            let n = String(ch).utf8.count
            let limit = out.isEmpty ? 75 : 74
            if size + n > limit {
                out.append(current)
                current = ""
                size = 0
            }
            current.append(ch)
            size += n
        }
        out.append(current)
        return out.joined(separator: "\r\n ")
    }

    // MARK: print

    /// The printed page: title, when, where, organizer, attendees by
    /// response, Teams dial-in and the description.
    public static func printText(_ m: MeetingItem, detail d: CalendarEventDetail? = nil, when: String) -> String {
        var out: [String] = [m.subject, ""]
        out.append("When: " + when)
        if let rec = d?.recurrence ?? m.info?.recurrence { out.append("Repeats: " + rec) }
        out.append("Where: " + (m.info?.location ?? "No location added"))
        if let org = m.organizerDisplay { out.append("Organizer: " + org) }
        let groups = CalendarEventInfo.groups(m.invitees)
        if !groups.isEmpty {
            out.append("")
            for g in groups {
                out.append(g.header)
                for p in g.people { out.append("    " + p.displayName + (p.type == "optional" ? " (Optional)" : "")) }
            }
        }
        if !m.categories.isEmpty { out.append("Categories: " + m.categories.joined(separator: ", ")) }
        if let join = m.joinURL, !join.isEmpty {
            out += ["", "Microsoft Teams meeting", "Join: " + join]
            if let toll = m.info?.dialIn?.tollNumber { out.append("Dial in: " + toll) }
            if let conf = m.info?.dialIn?.conferenceID { out.append("Conference ID: " + conf) }
        }
        let body = d?.bodyHTML.map { String(EventBodyRender.attributed(html: $0).characters) } ?? d?.bodyText
            ?? m.info?.bodyPreview
        if let body, !body.isEmpty { out += ["", body] }
        return out.joined(separator: "\n")
    }
}
