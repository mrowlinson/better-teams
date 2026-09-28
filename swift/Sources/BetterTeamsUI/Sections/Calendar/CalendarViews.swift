// CalendarViews.swift — Calendar panes (UI-SPEC §6.4): Agenda list by
// day, meeting detail, the Week grid, and the Week inspector. Every
// pane state is designed (R18): loading only with nothing on screen
// (R12), error with Try Again (worded "You're offline" when offline),
// empty = "No Meetings This Week" + New Meeting….
import OstMacCore
import SwiftUI

/// "No Meetings This Week" + New Meeting… (§6 pane states).
struct CalendarEmptyPane: View {
    @Environment(\.windowModel) private var model

    var body: some View {
        EmptyPane("No Meetings This Week", systemImage: "calendar") {
            Button("New Meeting…") {
                model?.presentSheet(SheetRequest(CalendarCommands.newMeetingSheet, in: .calendar))
            }
        }
    }
}

/// Loading / error / empty, shared by the Agenda list and the Week grid.
private struct CalendarStatePane: View {
    let state: CalendarPaneState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .loading: LoadingPane()
        case .error(let title, let message): ErrorPane(title: title, message: message, retry: retry)
        case .empty, .meetings: CalendarEmptyPane()
        }
    }
}

@MainActor
private func paneState(_ week: CalendarWeekStore, _ m: WindowModel) -> CalendarPaneState {
    CalendarPaneState.resolve(week.state, count: week.meetings.count, forced: m.forced(.calendar),
                              offline: m.connection == .offline)
}

// MARK: Agenda list

struct CalendarAgendaPane: View {
    @ObservedObject var week: CalendarWeekStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let state = paneState(week, model)
            if state == .meetings {
                list(model)
            } else {
                CalendarStatePane(state: state) { week.refresh() }
            }
        }
    }

    /// Days of the week that have meetings, in order, each sorted by start.
    private var days: [(key: String, meetings: [MeetingItem])] {
        zip(week.dayKeys, week.columns).filter { !$0.1.isEmpty }.map { (key: $0.0, meetings: $0.1) }
    }

    private func list(_ m: WindowModel) -> some View {
        let now = RelativeClock.shared.now
        let selection = Binding<String?>(
            get: { CalendarSection.current(m).meetingID },
            set: { CalendarSection.select($0, m) })
        return List(selection: selection) {
            ForEach(days, id: \.key) { day in
                Section(CalendarFormat.dayTitle(day.key, now: now)) {
                    ForEach(day.meetings) { meeting in
                        AgendaRow(meeting: meeting, joinable: CalendarFormat.joinableNow(meeting, now: now)) {
                            CalendarSection.join(meeting, m)
                        }
                        .tag(meeting.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let meeting = week.meetings.first(where: { $0.id == id }) {
                if meeting.joinURL?.isEmpty == false {
                    Button("Join") { CalendarSection.join(meeting, m) }
                    Button("Copy Join Link") { CalendarSection.copyJoinLink(meeting) }
                }
                if CalendarSection.isOrganizer(meeting, m) {
                    Divider()
                    Button("Cancel Meeting…") { CalendarSection.confirmCancel(meeting, m) }
                }
            }
        } primaryAction: { ids in
            CalendarSection.select(ids.first, m)
        }
    }
}

/// Agenda row (§6.4): time range (monospaced digits), subject,
/// organizer, `video` badge when online; a small Join when joinable now.
struct AgendaRow: View {
    let meeting: MeetingItem
    let joinable: Bool
    let join: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meeting.subject)
                        .font(AppFont.bodyEmphasized(scale))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if meeting.isOnline {
                        Image(systemName: "video")
                            .font(AppFont.caption(scale))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Online meeting")
                    }
                }
                Text(CalendarFormat.range(meeting))
                    .font(AppFont.subheadline(scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let org = meeting.organizer, !org.isEmpty {
                    Text(org)
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if joinable {
                Button("Join", action: join)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: detail

/// Agenda: the selected meeting (or "No Meeting Selected"). Week: the grid.
struct CalendarDetailPane: View {
    @ObservedObject var week: CalendarWeekStore
    @ObservedObject var conv: ConversationStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let sel = CalendarSection.current(model)
            if sel.view == .week {
                let state = paneState(week, model)
                if state == .meetings {
                    WeekGrid(week: week, selectedID: sel.meetingID) { CalendarSection.select($0, model) }
                } else {
                    CalendarStatePane(state: state) { week.refresh() }
                }
            } else if paneState(week, model) == .meetings,
                      let id = sel.meetingID, let meeting = week.meetings.first(where: { $0.id == id }) {
                MeetingDetail(meeting: meeting, isOrganizer: CalendarSection.isOrganizer(meeting, model))
            } else {
                NoSelectionPane("No Meeting Selected")
            }
        }
    }
}

/// Week inspector: the selected meeting (§5.3, §6.4).
struct CalendarInspectorPane: View {
    @ObservedObject var week: CalendarWeekStore
    @ObservedObject var conv: ConversationStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let id = CalendarSection.current(model).meetingID,
           let meeting = week.meetings.first(where: { $0.id == id }) {
            MeetingDetail(meeting: meeting, isOrganizer: CalendarSection.isOrganizer(meeting, model))
        } else if let model, paneState(week, model) != .meetings {
            // Nothing to select (empty week, loading, error): the empty
            // state, not a selection prompt; the grid carries the state.
            EmptyPane("No Meetings This Week", systemImage: "calendar")
        } else {
            NoSelectionPane("No Meeting Selected")
        }
    }
}

/// Meeting detail (§6.4): subject, time, organizer, join link; Join
/// (primary), Meeting Chat, Copy Join Link; Cancel Meeting… for
/// organizers (confirmed).
struct MeetingDetail: View {
    let meeting: MeetingItem
    let isOrganizer: Bool
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    private var online: Bool { meeting.joinURL?.isEmpty == false }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meeting.subject)
                        .font(AppFont.title3(scale))
                        .textSelection(.enabled)
                    // Day and time range on their own lines: the range
                    // never wraps mid-way in the 260 pt inspector.
                    if let day {
                        Text(day)
                            .font(AppFont.body(scale))
                            .foregroundStyle(.secondary)
                    }
                    let range = CalendarFormat.range(meeting)
                    if !range.isEmpty {
                        Text(range)
                            .font(AppFont.body(scale))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                if let org = meeting.organizer, !org.isEmpty {
                    LabeledContent("Organizer", value: org)
                }
                LabeledContent("Location", value: meeting.isOnline ? "Microsoft Teams meeting" : "In person")
                if let url = meeting.joinURL, !url.isEmpty {
                    LabeledContent("Join link") {
                        if let link = URL(string: url) {
                            Link(url, destination: link)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(url)
                        } else {
                            Text(url)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(url)
                        }
                    }
                }
            }
            Section {
                // One row where the pane is wide enough (Agenda detail);
                // stacked in the narrow Week inspector, never truncated
                // ("Meeting C…").
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        actions
                        Spacer(minLength: 0)
                        cancel
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        actions
                        cancel
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var actions: some View {
        if online {
            Button("Join") { if let model { CalendarSection.join(meeting, model) } }
                .buttonStyle(.borderedProminent)
            // Meeting Chat needs the meeting's chat thread,
            // which the calendar event does not carry (core gap).
            Button("Meeting Chat") {}
                .disabled(true)
                .help("Meeting chat isn\u{2019}t available for this meeting")
            Button("Copy Join Link") { CalendarSection.copyJoinLink(meeting) }
        }
    }

    @ViewBuilder private var cancel: some View {
        if isOrganizer {
            Button("Cancel Meeting…", role: .destructive) {
                if let model { CalendarSection.confirmCancel(meeting, model) }
            }
        }
    }

    /// "Monday, September 28".
    private var day: String? {
        CalWeek.dayKey(of: meeting).map { CalendarFormat.dayTitle($0, now: .distantPast) }
    }
}
