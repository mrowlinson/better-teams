// CalendarDetails.swift — the meeting details popup (Teams "expanded"
// meeting): an in-app sheet with RSVP / Join / Chat / Edit actions,
// the full time (organizer's zone when different), series pattern,
// location and rooms, Teams join + dial-in, attachments, the
// invitation body (HTML flattened safely: no images, scripts or remote
// loads), and attendee tracking grouped by response.
import OstMacCore
import SwiftUI

struct EventDetailsSheet: View {
    @ObservedObject var week: CalendarWeekStore
    let eventID: String
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    private var detail: CalendarEventDetail? { week.details[eventID] }
    private var meeting: MeetingItem? { detail?.event ?? week.row(id: eventID) }

    var body: some View {
        VStack(spacing: 0) {
            if let meeting {
                actionBar(meeting)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    ScrollView(.vertical) {
                        main(meeting)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    ScrollView(.vertical) {
                        EventTracking(meeting: meeting)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 270)
                    .background(.quaternary.opacity(0.25))
                }
            } else {
                EmptyPane("Meeting Not Found", systemImage: "calendar")
                HStack {
                    Spacer()
                    Button("Close") { model?.dismissSheet() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
        }
        .font(AppFont.body(scale))
        .frame(width: 840, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: action bar

    private func actionBar(_ m: MeetingItem) -> some View {
        HStack(spacing: 8) {
            if !m.isOrganizer, let info = m.info {
                RSVPButtons(meeting: m, response: info.myResponse, week: week)
            }
            if m.isOrganizer, let model {
                Button { CalendarSection.edit(m, model) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { CalendarSection.confirmCancel(m, model) } label: {
                    Label("Cancel meeting", systemImage: "xmark.circle")
                }
            }
            Spacer(minLength: 8)
            if m.chatThreadID != nil, let model {
                Button { CalendarSection.openChat(m, model) } label: {
                    Label("Chat with participants", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if m.joinURL?.isEmpty == false, let model {
                Button("Join") {
                    model.dismissSheet()
                    CalendarSection.join(m, model)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Close") { model?.dismissSheet() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: main column

    private func main(_ m: MeetingItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.subject)
                    .font(AppFont.title3(scale).weight(.semibold))
                    .textSelection(.enabled)
                if m.isSeries { SeriesBadge() }
            }
            CalendarFactRow(symbol: "clock") {
                Text(CalendarFormat.when(m)).monospacedDigit()
                if let other = CalendarFormat.organizerTime(m) {
                    Text("Organizer\u{2019}s time: \(other)").foregroundStyle(.secondary)
                }
                if let rec = detail?.recurrence ?? m.info?.recurrence {
                    Text(rec).foregroundStyle(.secondary)
                }
            }
            CalendarFactRow(symbol: "mappin.and.ellipse") {
                if let place = m.info?.location {
                    Text(place).textSelection(.enabled)
                } else {
                    Text("No location added").foregroundStyle(.secondary)
                }
                let rooms = m.info?.rooms ?? []
                if !rooms.isEmpty {
                    Text("Rooms: " + rooms.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
            if let info = m.info, let line = Self.statusLine(info) {
                CalendarFactRow(symbol: "bell") {
                    Text(line).foregroundStyle(.secondary)
                }
            }
            if m.joinURL?.isEmpty == false {
                teamsBlock(m)
            }
            if let files = detail?.attachments, !files.isEmpty {
                CalendarFactRow(symbol: "paperclip") {
                    ForEach(files) { f in
                        HStack(spacing: 6) {
                            Text(f.name)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            bodyView(m)
        }
    }

    /// "Microsoft Teams meeting" + join link + dial-in.
    private func teamsBlock(_ m: MeetingItem) -> some View {
        CalendarFactRow(symbol: "video") {
            Text("Microsoft Teams meeting").font(AppFont.bodyEmphasized(scale))
            HStack(spacing: 8) {
                if let model {
                    Button("Join the meeting now") {
                        model.dismissSheet()
                        CalendarSection.join(m, model)
                    }
                    .buttonStyle(.link)
                }
                Button("Copy link") { CalendarSection.copyJoinLink(m) }
                    .buttonStyle(.link)
            }
            if let dial = m.info?.dialIn {
                if let toll = dial.tollNumber {
                    Text("Dial in by phone: \(toll)").textSelection(.enabled)
                }
                if let conf = dial.conferenceID {
                    Text("Phone conference ID: \(conf)").textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func bodyView(_ m: MeetingItem) -> some View {
        if let html = detail?.bodyHTML {
            Text(EventBodyRender.attributed(html: html))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let text = detail?.bodyText {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if week.detailLoading.contains(eventID) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading details\u{2026}").foregroundStyle(.secondary)
            }
        } else if let error = week.detailErrors[eventID] {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                Text(error).foregroundStyle(.secondary)
                Button("Try Again") { week.loadDetail(id: eventID, force: true) }
            }
        } else if let preview = m.info?.bodyPreview {
            Text(preview).textSelection(.enabled)
        } else {
            Text("No description").foregroundStyle(.secondary)
        }
    }

    /// "Show as Busy · Reminder 15 minutes before · Private".
    static func statusLine(_ info: CalendarEventInfo) -> String? {
        var parts: [String] = []
        if let s = info.showAs, let label = showAsLabel(s) { parts.append("Show as \(label)") }
        if let r = info.reminderMinutes {
            parts.append(r == 0 ? "Reminder at start" : "Reminder \(r) minutes before")
        }
        if info.sensitivity == "private" { parts.append("Private") }
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
}

/// Accept / Tentative / Decline buttons (series: menus for this event
/// or the series); the current response is checked.
private struct RSVPButtons: View {
    let meeting: MeetingItem
    let response: RSVPResponse
    @ObservedObject var week: CalendarWeekStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RSVPAction.allCases, id: \.rawValue) { action in
                let on = response == action.response
                if meeting.isSeries {
                    Menu {
                        Button("This Event") { week.respond(to: meeting, action) }
                        Button("All Events in the Series") { week.respond(to: meeting, action, series: true) }
                    } label: {
                        Label(action.title, systemImage: on ? "checkmark" : symbol(action))
                    }
                    .fixedSize()
                } else {
                    Button { week.respond(to: meeting, action) } label: {
                        Label(action.title, systemImage: on ? "checkmark" : symbol(action))
                    }
                }
            }
            if week.respondingID != nil { ProgressView().controlSize(.small) }
            if let error = week.rsvpError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.failed)
                    .help(error)
            }
        }
        .disabled(week.respondingID != nil)
    }

    private func symbol(_ a: RSVPAction) -> String {
        switch a {
        case .accept: "checkmark.circle"
        case .tentativelyAccept: "questionmark.circle"
        case .decline: "xmark.circle"
        }
    }
}

/// Right column: organizer, your response, attendees by response.
private struct EventTracking: View {
    let meeting: MeetingItem
    @Environment(\.contentTextScale) private var scale

    struct Group: Identifiable {
        let id: String
        let people: [EventAttendee]
    }

    private var groups: [Group] {
        let people = (meeting.info?.people ?? []).filter { $0.response != .organizer }
        let order: [(String, (RSVPResponse) -> Bool)] = [
            ("Accepted", { $0 == .accepted }),
            ("Tentative", { $0 == .tentativelyAccepted }),
            ("Declined", { $0 == .declined }),
            ("Didn\u{2019}t respond", { $0.isPending }),
        ]
        return order.compactMap { name, match in
            let list = people.filter { match($0.response) }
            return list.isEmpty ? nil : Group(id: "\(name) (\(list.count))", people: list)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tracking").font(AppFont.headline(scale))
            if let org = meeting.organizer {
                VStack(alignment: .leading, spacing: 2) {
                    Text(org).font(AppFont.bodyEmphasized(scale))
                        .contactHover(name: org, email: meeting.organizerEmail)
                    Text("Organizer").font(AppFont.caption(scale)).foregroundStyle(.secondary)
                }
            }
            if meeting.isOrganizer {
                Text("You organized this meeting.").foregroundStyle(.secondary)
            } else if let r = meeting.info?.myResponse {
                Text(r.isPending ? "You haven\u{2019}t responded." : "You responded \u{201C}\(r.label)\u{201D}.")
                    .foregroundStyle(.secondary)
            }
            if let counts = CalendarDetailsText.counts(meeting) {
                Text(counts).font(AppFont.caption(scale)).foregroundStyle(.secondary)
            }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.id).font(AppFont.subheadline(scale).weight(.semibold))
                    ForEach(g.people) { p in
                        HStack(spacing: 6) {
                            Text(p.name).lineLimit(1).truncationMode(.tail)
                                .contactHover(name: p.name, email: p.email.isEmpty ? nil : p.email)
                            if p.type == "optional" {
                                Text("Optional").font(AppFont.caption(scale)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if groups.isEmpty, meeting.info?.people.isEmpty ?? true {
                Text("No attendees").foregroundStyle(.secondary)
            }
        }
    }
}
