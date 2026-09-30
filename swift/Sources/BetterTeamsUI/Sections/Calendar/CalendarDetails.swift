// CalendarDetails.swift — the meeting details popup (Teams "expanded"
// event, 10.25.03 parity): an in-app sheet, or its own window (pop-out),
// with Teams' toolbar — RSVP, Delete, Forward, Duplicate, Show as,
// Reminder, Categorize, Private, Apps, Print, Download (.ics), Join,
// Chat — the main card (type + title + sensitivity, attendees + Tracking
// toggle, time + series + Scheduler, location / Add a room, Teams
// meeting, personal fields, categories, Teams join + dial-in,
// attachments, invitation body; HTML flattened safely: no images,
// scripts or remote loads) and the collapsible Tracking pane.
import AppKit
import OstMacCore
import SwiftUI

struct EventDetailsSheet: View {
    @ObservedObject var week: CalendarWeekStore
    let eventID: String
    @Environment(\.windowModel) private var model

    var body: some View {
        EventDetailsView(week: week, eventID: eventID, host: .sheet)
            .frame(width: 940, height: 640)
    }
}

/// Where the details show: the sheet (commands above the card, "Open in
/// New Window" + Close in its bottom bar) or the pop-out window (its own
/// title bar and toolbar).
enum EventDetailsHost: Equatable { case sheet, window }

struct EventDetailsView: View {
    @ObservedObject var week: CalendarWeekStore
    let eventID: String
    let host: EventDetailsHost
    var closeWindow: () -> Void = {}
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale
    @State private var trackingShown = true
    @State private var roomShown = false

    private var detail: CalendarEventDetail? { week.details[eventID] }
    private var meeting: MeetingItem? { detail?.event ?? week.row(id: eventID) }

    var body: some View {
        VStack(spacing: 0) {
            if let meeting {
                if host == .window {
                    loaded(meeting)
                        .toolbar {
                            EventDetailsWindowToolbar(meeting: meeting, detail: detail, week: week,
                                                      trackingShown: $trackingShown, close: close)
                        }
                } else {
                    loaded(meeting)
                }
            } else if week.detailLoading.contains(eventID) {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyPane("Meeting Not Found", systemImage: "calendar")
                HStack {
                    Spacer()
                    Button("Close", action: close).keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
        }
        .font(AppFont.body(scale))
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { week.loadCategories() }
        // Opened before the week landed (route, fast click): read the
        // details once the row exists.
        .task(id: meeting != nil) { if meeting != nil, detail == nil { week.loadDetail(id: eventID) } }
    }

    private func close() {
        if host == .sheet { model?.dismissSheet() } else { closeWindow() }
    }

    /// The loaded event: commands (sheet), card, Tracking pane, bottom bar (sheet).
    private func loaded(_ meeting: MeetingItem) -> some View {
        VStack(spacing: 0) {
            if host == .sheet {
                EventDetailsToolbar(meeting: meeting, detail: detail, week: week,
                                    trackingShown: $trackingShown, close: close)
                Divider()
            }
            if let error = week.personalError ?? week.removeError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                    Text(error).foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { week.clearPersonalError() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .font(AppFont.caption(scale))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.vertical) {
                    main(meeting)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if trackingShown {
                    Divider()
                    ScrollView(.vertical) {
                        EventTracking(meeting: meeting)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 290)
                    .background(.quaternary.opacity(0.25))
                    .transition(.move(edge: .trailing))
                }
            }
            if host == .sheet {
                Divider()
                HStack {
                    Button("Open in New Window") {
                        if let model {
                            model.dismissSheet()
                            EventDetailsWindowController.show(eventID: meeting.id, model)
                        }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Close", action: close)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
        }
    }

    // MARK: main card

    private func main(_ m: MeetingItem) -> some View {
        let type = m.eventType(body: detail?.bodyHTML ?? detail?.bodyText)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: type.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.12)))
                    .help(type.title)
                    .accessibilityLabel(type.title)
                Text(m.subject)
                    .font(AppFont.title3(scale).weight(.semibold))
                    .textSelection(.enabled)
                if m.isSeries { SeriesBadge() }
                if type == .webinar || type == .townHall { EventTypeBadge(type: type) }
                Spacer(minLength: 8)
                let sensitivity = CalendarDetailsText.sensitivityLabel(m.info?.sensitivity)
                Label(sensitivity ?? "Normal", systemImage: "lock.shield")
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
                    .help("Sensitivity: \(sensitivity ?? "Normal")")
            }
            if !m.invitees.isEmpty || m.organizer != nil {
                CalendarFactRow(symbol: "person.2") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CalendarDetailsText.attendeeLine(m).map(CalendarDetailsText.unbrokenNames) ?? "No attendees")
                                .foregroundStyle(m.invitees.isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            if let roles = CalendarDetailsText.roleLine(m) {
                                Text(roles).font(AppFont.caption(scale)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            CalendarFactRow(symbol: "clock") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CalendarFormat.when(m)).monospacedDigit()
                    Spacer(minLength: 8)
                    if !m.invitees.isEmpty || m.isOrganizer, let model {
                        Button {
                            CalendarSection.openScheduler(m, model)
                        } label: {
                            Label("Scheduler", systemImage: "calendar.day.timeline.left")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Scheduling assistant: free/busy and suggested times")
                    }
                }
                if let other = CalendarFormat.organizerTime(m) {
                    Text("Organizer\u{2019}s time: \(other)").foregroundStyle(.secondary)
                }
                if let rec = detail?.recurrence ?? m.info?.recurrence {
                    Text(rec).foregroundStyle(.secondary)
                }
                if m.isSeries, let model {
                    SeriesLinks(meeting: m, model: model)
                }
            }
            CalendarFactRow(symbol: "mappin.and.ellipse") {
                if let place = m.info?.location {
                    Text(place).textSelection(.enabled)
                } else if m.isOrganizer {
                    Button("Add a room") { roomShown = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .popover(isPresented: $roomShown, arrowEdge: .bottom) {
                            AddRoomPopover(meeting: m, week: week) { roomShown = false }
                        }
                } else {
                    Text("No location added").foregroundStyle(.secondary)
                }
                let rooms = (m.info?.rooms ?? []).filter { !(m.info?.location ?? "").contains($0.name) }
                if !rooms.isEmpty {
                    Text("Rooms: " + rooms.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary)
                }
                if m.isOrganizer, m.info?.location != nil {
                    Button("Add a room") { roomShown = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .popover(isPresented: $roomShown, arrowEdge: .bottom) {
                            AddRoomPopover(meeting: m, week: week) { roomShown = false }
                        }
                }
            }
            if m.joinURL?.isEmpty == false || m.isOnline {
                CalendarFactRow(symbol: "video") {
                    Text(type == .webinar ? "Teams webinar" : type == .townHall ? "Teams town hall" : "Teams meeting")
                }
            }
            if let info = m.info, let line = CalendarDetailsText.statusLine(info) {
                CalendarFactRow(symbol: "bell") {
                    Text(line).foregroundStyle(.secondary)
                }
            }
            if !m.categories.isEmpty {
                CalendarFactRow(symbol: "tag") {
                    CategoryChips(names: m.categories, list: week.categoryList)
                }
            }
            if m.joinURL?.isEmpty == false {
                teamsBlock(m)
            }
            if let files = detail?.attachments, !files.isEmpty {
                CalendarFactRow(symbol: "paperclip") {
                    ForEach(files) { f in
                        EventAttachmentRow(eventID: m.id, file: f, week: week)
                    }
                }
            } else if m.info?.hasAttachments == true, week.detailLoading.contains(eventID) {
                CalendarFactRow(symbol: "paperclip") {
                    Text("Attachments\u{2026}").foregroundStyle(.secondary)
                }
            }
            Divider()
            bodyView(m)
        }
    }

    /// "Microsoft Teams meeting" + join link + dial-in.
    private func teamsBlock(_ m: MeetingItem) -> some View {
        CalendarFactRow(symbol: "video.badge.checkmark") {
            Text("Microsoft Teams \(m.eventType(body: detail?.bodyHTML ?? detail?.bodyText).title.lowercased())")
                .font(AppFont.bodyEmphasized(scale))
            HStack(spacing: 8) {
                if let model {
                    Button("Join the meeting now") {
                        close()
                        CalendarSection.join(m, model)
                    }
                    .buttonStyle(.link)
                }
                Button("Copy Link") { CalendarSection.copyJoinLink(m) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            // The link itself, as text (selectable, middle-truncated).
            if let url = JoinLinkRow.text(for: m) { JoinLinkRow(url: url) }
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
        if let raw = detail?.bodyHTML {
            // The Teams join block is drawn as its own row: hide the copy in the body.
            let stripped = m.joinURL?.isEmpty == false ? CalendarEventDraft.stripTeamsBlock(raw) : raw
            let html = stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? raw : stripped
            Text(EventBodyRender.attributed(html: html))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let text = detail?.bodyText {
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = week.detailErrors[eventID] {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                Text(error).foregroundStyle(.secondary)
                Button("Try Again") { week.loadDetail(id: eventID, force: true) }
            }
        } else if let preview = m.info?.bodyPreview {
            // Stale-while-revalidate: the preview shows until the body lands.
            Text(preview).textSelection(.enabled)
        } else if week.detailLoading.contains(eventID) {
            DelayedDetailLoading()
        } else {
            Text("No description").foregroundStyle(.secondary)
        }
    }
}

/// "Loading details…" only after 0.3 s (fast reads never flash it).
private struct DelayedDetailLoading: View {
    @State private var shown = false
    @State private var delay = Debounce(milliseconds: LoadingPane.delayMilliseconds)

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Loading details\u{2026}").foregroundStyle(.secondary)
        }
        .opacity(shown ? 1 : 0)
        .onAppear { delay.schedule { shown = true } }
        .onDisappear { delay.cancel() }
    }
}

struct EventTypeBadge: View {
    let type: CalendarEventType
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        Label(type.title, systemImage: type.symbol)
            .font(AppFont.caption(scale))
            .foregroundStyle(.tint)
    }
}

/// One attachment: name, size, Open (download then open) / Download /
/// Show in Finder, progress and failure inline.
private struct EventAttachmentRow: View {
    let eventID: String
    let file: EventAttachment
    @ObservedObject var week: CalendarWeekStore
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                .foregroundStyle(.secondary)
            if week.downloading.contains(file.id) { ProgressView().controlSize(.small) }
            Button("Open") {
                Task {
                    if let url = await week.downloadAttachment(eventID: eventID, file) {
                        TeamsLinkRouter.open(url)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let saved = week.savedAttachments[file.id] {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Download") { Task { await week.downloadAttachment(eventID: eventID, file) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if let error = week.attachmentErrors[file.id] {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.failed)
                    .help(error)
            }
        }
        .disabled(week.downloading.contains(file.id))
    }
}

/// "Join link  <url>": the link itself as selectable text, middle-truncated.
struct JoinLinkRow: View {
    let url: String

    /// The link text an event shows (nil for a meeting with no link).
    static func text(for m: MeetingItem) -> String? {
        guard let url = m.joinURL, !url.isEmpty else { return nil }
        return url
    }

    var body: some View {
        LabeledContent("Join link") {
            if let link = URL(string: url) {
                Link(url, destination: link).lineLimit(1).truncationMode(.middle).help(url)
            } else {
                Text(url).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
        }
    }
}
