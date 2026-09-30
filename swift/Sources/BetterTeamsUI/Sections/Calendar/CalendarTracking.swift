// CalendarTracking.swift — the details popup's Tracking pane (Teams
// parity): header + more (…) (hide/show is the toolbar's inspector toggle); Organizer section with avatar
// and "Sent on <day>, <date> at <time>"; Attendees section with "You
// responded …" and collapsible response groups ("Didn't respond: N"),
// each row avatar + name + Required/Optional. Counts come from
// `MeetingItem.invitees` (organizer never counted) — the same list the
// sidebar and the header read, so they always agree.
import AppKit
import OstMacCore
import SwiftUI

struct EventTracking: View {
    let meeting: MeetingItem
    @Environment(\.contentTextScale) private var scale
    @State private var collapsed: Set<String> = []

    private var groups: [CalendarEventInfo.AttendeeGroup] { CalendarEventInfo.groups(meeting.invitees) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Tracking").font(AppFont.headline(scale))
                Spacer()
                Menu {
                    Button("Copy Attendee Emails") { copyEmails() }
                        .disabled(meeting.invitees.allSatisfy(\.email.isEmpty))
                    Button("Expand All Groups") { collapsed = [] }
                    Button("Collapse All Groups") { collapsed = Set(groups.map(\.id)) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More options")
                .accessibilityLabel("More options")
            }
            if let org = meeting.organizerDisplay {
                sectionHeader("Organizer")
                HStack(alignment: .top, spacing: 8) {
                    Avatar(name: org, diameter: 28, person: ContactRef(name: org, email: meeting.organizerEmail))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CalendarDetailsText.organizerLabel(meeting) ?? org).font(AppFont.bodyEmphasized(scale))
                            .lineLimit(1)
                            .contactHover(name: org, email: meeting.organizerEmail)
                        if let sent = CalendarDetailsText.sentOn(meeting) {
                            Text(sent).font(AppFont.caption(scale)).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
            }
            sectionHeader("Attendees")
            if meeting.isOrganizer {
                Text("You organized this meeting.").foregroundStyle(.secondary)
            } else if let r = meeting.info?.myResponse {
                Text(CalendarDetailsText.youResponded(r)).foregroundStyle(.secondary)
            }
            ForEach(groups) { g in
                DisclosureGroup(isExpanded: Binding(
                    get: { !collapsed.contains(g.id) },
                    set: { open in if open { collapsed.remove(g.id) } else { collapsed.insert(g.id) } })) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(g.people) { p in attendeeRow(p) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Text(g.header).font(AppFont.subheadline(scale).weight(.semibold))
                }
            }
            if groups.isEmpty {
                Text("No attendees").foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s).font(AppFont.caption(scale).weight(.semibold)).foregroundStyle(.secondary)
    }

    private func attendeeRow(_ p: EventAttendee) -> some View {
        HStack(spacing: 8) {
            Avatar(name: p.displayName, diameter: 24,
                   person: ContactRef(name: p.displayName, email: p.email.isEmpty ? nil : p.email))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.label).lineLimit(1).truncationMode(.tail)
                    .contactHover(name: p.displayName, email: p.email.isEmpty ? nil : p.email)
                Text(p.typeLabel).font(AppFont.caption(scale)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyEmails() {
        let list = meeting.invitees.map(\.email).filter { !$0.isEmpty }.joined(separator: "; ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list, forType: .string)
    }
}

// MARK: - Wording shared by the sidebar, popup and print

extension CalendarDetailsText {
    /// The organizer's name, plus " (You)" when the user organized it
    /// (attendee rows: `EventAttendee.label`).
    static func organizerLabel(_ m: MeetingItem) -> String? {
        guard let org = m.organizerDisplay else { return nil }
        return m.isOrganizer ? org + " (You)" : org
    }

    /// "Accepted: 2 · Tentative: 0 · Declined: 1 · Didn't respond: 3"
    /// (every bucket, organizer excluded); nil with no invitees.
    static func bucketLine(_ m: MeetingItem) -> String? {
        guard !m.invitees.isEmpty else { return nil }
        let t = m.tally
        return [("Accepted", t.accepted), ("Tentative", t.tentative), ("Declined", t.declined),
                ("Didn\u{2019}t respond", t.pending)]
            .map { "\($0.0): \($0.1)" }.joined(separator: " \u{00B7} ")
    }

    /// Keeps a counts line from wrapping inside one bucket: spaces within
    /// a "Label: N" piece are non-breaking, so it breaks only at the dots.
    static func unbroken(_ line: String) -> String {
        line.components(separatedBy: " \u{00B7} ")
            .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            .joined(separator: " \u{00B7} ")
    }

    /// The attendee line with each name held together: it wraps between
    /// names or before "+N others", never inside a name.
    static func unbrokenNames(_ line: String) -> String {
        let nb = "\u{00A0}"
        let parts = line.components(separatedBy: " +")
        let names = parts[0].components(separatedBy: "; ").map { $0.replacingOccurrences(of: " ", with: nb) }
        return ([names.joined(separator: "; ")] + parts.dropFirst()).joined(separator: " +")
    }

    /// "Ann Lee; Bob Ray; Tom Becker +2 others" (Teams' attendee row).
    static func attendeeLine(_ m: MeetingItem, shown: Int = 3) -> String? {
        let people = m.invitees
        guard !people.isEmpty else { return nil }
        let names = people.prefix(shown).map(\.label).joined(separator: "; ")
        let more = people.count - min(shown, people.count)
        return more > 0 ? "\(names) +\(more) other\(more == 1 ? "" : "s")" : names
    }

    /// "4 required, 1 optional".
    static func roleLine(_ m: MeetingItem) -> String? {
        let people = m.invitees
        guard !people.isEmpty else { return nil }
        let optional = people.filter { $0.type == "optional" }.count
        let required = people.count - optional
        return optional == 0 ? "\(required) required" : "\(required) required, \(optional) optional"
    }

    /// "Sent on Thursday, 9/24/2026 at 4:12 PM".
    static func sentOn(_ m: MeetingItem, tz: TimeZone = .current) -> String? {
        guard let d = m.sentDate else { return nil }
        var day = Date.FormatStyle.dateTime.weekday(.wide).month(.defaultDigits).day().year()
        day.timeZone = tz
        var time = Date.FormatStyle.dateTime.hour().minute()
        time.timeZone = tz
        return "Sent on \(d.formatted(day)) at \(d.formatted(time))"
    }

    /// Teams wording: You responded "Accept".
    static func youResponded(_ r: RSVPResponse) -> String {
        switch r {
        case .accepted: "You responded \u{201C}Accept\u{201D}"
        case .tentativelyAccepted: "You responded \u{201C}Tentative\u{201D}"
        case .declined: "You responded \u{201C}Decline\u{201D}"
        case .organizer: "You organized this meeting."
        case .none, .notResponded: "You haven\u{2019}t responded"
        }
    }

    /// "Show as Busy · Reminder 15 minutes before · Private".
    static func statusLine(_ info: CalendarEventInfo) -> String? {
        var parts: [String] = []
        if let s = info.showAs, let label = showAsLabel(s) { parts.append("Show as \(label)") }
        if let r = info.reminderMinutes { parts.append(reminderLabel(r)) }
        if let s = sensitivityLabel(info.sensitivity) { parts.append(s) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func showAsLabel(_ s: String) -> String? {
        switch s {
        case "free": "Free"
        case "tentative": "Tentative"
        case "busy": "Busy"
        case "oof": "Out of office"
        case "workingElsewhere": "Working elsewhere"
        default: nil
        }
    }

    static func showAsSymbol(_ s: String?) -> String {
        switch s {
        case "free": "circle"
        case "tentative": "circle.lefthalf.striped.horizontal"
        case "oof": "airplane"
        case "workingElsewhere": "building.2"
        default: "circle.fill"
        }
    }

    static func reminderLabel(_ minutes: Int?) -> String {
        guard let r = minutes, r >= 0 else { return "No reminder" }
        switch r {
        case 0: return "Reminder at start"
        case 1440: return "Reminder 1 day before"
        case 10080: return "Reminder 1 week before"
        case let m where m % 60 == 0: return "Reminder \(m / 60) hour\(m == 60 ? "" : "s") before"
        default: return "Reminder \(r) minutes before"
        }
    }

    /// Non-normal sensitivity as shown ("Private"); nil for normal.
    static func sensitivityLabel(_ s: String?) -> String? {
        switch s {
        case "private": "Private"
        case "personal": "Personal"
        case "confidential": "Confidential"
        default: nil
        }
    }

    /// Outlook preset color for a category (master list), else by name.
    static func categoryColor(_ name: String, list: [CalendarCategory]) -> Color {
        let preset = list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color
        let presets: [String: Color] = [
            "preset0": .red, "preset1": .orange, "preset2": .brown, "preset3": .yellow, "preset4": .green,
            "preset5": .teal, "preset6": .mint, "preset7": .blue, "preset8": .purple, "preset9": .pink,
            "preset10": .gray, "preset11": .gray, "preset12": .gray, "preset13": .gray, "preset14": .primary,
        ]
        return preset.flatMap { presets[$0] } ?? WeekEventColor.color(forCategory: name) ?? .accentColor
    }

    /// Add-a-room edit: the room joins the location; with an address it
    /// also joins the attendees as a resource.
    static func roomPatch(_ m: MeetingItem, name: String, address: String) -> CalendarEventPatch {
        let room = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mail = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let place = [m.info?.location, room].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
        var patch = CalendarEventPatch(location: place)
        if !mail.isEmpty {
            patch.attendees = (m.info?.attendees ?? []).filter { $0.response != .organizer }
                + [EventAttendee(name: room, email: mail, type: "resource")]
        }
        return patch
    }
}
