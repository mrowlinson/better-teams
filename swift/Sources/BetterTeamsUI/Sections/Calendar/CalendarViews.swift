// CalendarViews.swift — Calendar panes (UI-SPEC §6.4): the header bar
// over every view, the List view (the week by day), and the inspector
// (the selected meeting, Teams-popover fields, expandable to the
// details popup). Every pane state is designed (R18): loading only
// with nothing on screen (R12), error with Try Again (worded "You're
// offline" when offline), empty = "No Meetings This Week" + New Meeting….
import OstMacCore
import SwiftUI

/// "No Meetings This Week" + New Meeting… (§6 pane states).
struct CalendarEmptyPane: View {
    var title = "No Meetings This Week"
    @Environment(\.windowModel) private var model

    var body: some View {
        EmptyPane(title, systemImage: "calendar") {
            Button("New Meeting…") {
                model?.presentSheet(SheetRequest(CalendarCommands.newMeetingSheet, in: .calendar))
            }
        }
    }
}

/// Loading / error / empty, shared by every view.
private struct CalendarStatePane: View {
    let state: CalendarPaneState
    let emptyTitle: String
    let retry: () -> Void

    var body: some View {
        switch state {
        case .loading: LoadingPane("Loading Calendar\u{2026}")
        case .error(let title, let message): ErrorPane(title: title, message: message, retry: retry)
        case .empty, .meetings: CalendarEmptyPane(title: emptyTitle)
        }
    }
}

@MainActor
private func paneState(_ week: CalendarWeekStore, _ view: CalendarSelection.View, _ m: WindowModel) -> CalendarPaneState {
    if view == .month {
        let state: MeetingsState = week.monthLoaded ? (week.monthMeetings.isEmpty ? .empty : .loaded)
            : (week.state == .loading || week.isLoadingMonth ? .loading : week.state)
        return CalendarPaneState.resolve(state, count: week.monthLoaded ? max(1, week.monthMeetings.count) : 0,
                                         forced: m.forced(.calendar), offline: m.connection == .offline)
    }
    // Grids show an empty week as an empty grid (navigable), not a pane.
    let settled = week.state == .loaded || week.state == .empty
    let count = view == .list ? week.meetings.count : (!settled && week.meetings.isEmpty ? 0 : 1)
    return CalendarPaneState.resolve(week.state, count: count, forced: m.forced(.calendar),
                                     offline: m.connection == .offline)
}

// MARK: header bar

/// Always on screen: Today, ‹ ›, the range, a date picker, the view
/// switcher, Meet now and New meeting (Teams calendar header).
struct CalendarHeaderBar: View {
    @ObservedObject var week: CalendarWeekStore
    let view: CalendarSelection.View
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        if let model {
            HStack(spacing: 8) {
                Button("Today") { CalendarSection.jump(to: RelativeClock.shared.now, model) }
                    .help("Go to today")
                ControlGroup {
                    Button { CalendarSection.step(-1, model) } label: { Image(systemName: "chevron.left") }
                        .help("Previous")
                        .accessibilityLabel("Previous")
                    Button { CalendarSection.step(1, model) } label: { Image(systemName: "chevron.right") }
                        .help("Next")
                        .accessibilityLabel("Next")
                }
                .fixedSize()
                Text(CalendarSection.rangeTitle(view, week))
                    .font(AppFont.headline(scale))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                DatePicker("Go to date", selection: Binding(
                    get: { week.focusDay },
                    set: { CalendarSection.jump(to: $0, model) }), displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .fixedSize()
                    .help("Go to date")
                if week.isLoadingWeek || week.isLoadingMonth {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    switcher.pickerStyle(.segmented).fixedSize()
                    switcher.pickerStyle(.menu).fixedSize()
                }
                Button { model.presentSheet(SheetRequest(CalendarCommands.meetNowSheet, in: .calendar)) } label: {
                    Label("Meet now", systemImage: "video")
                }
                .help("Start an instant meeting")
                Button { model.presentSheet(SheetRequest(CalendarCommands.newMeetingSheet, in: .calendar)) } label: {
                    Label("New meeting", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var switcher: some View {
        Picker("View", selection: Binding(
            get: { view },
            set: { v in if let model { CalendarSection.setView(v, model) } })) {
            ForEach(CalendarSelection.View.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .help("Change the calendar view")
    }
}

// MARK: main pane

/// Header bar over the chosen view (Day, Work week, Week, Month, List).
struct CalendarDetailPane: View {
    @ObservedObject var week: CalendarWeekStore
    @ObservedObject var conv: ConversationStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let sel = CalendarSection.current(model)
            VStack(spacing: 0) {
                CalendarHeaderBar(week: week, view: sel.view)
                Divider()
                content(sel, model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder private func content(_ sel: CalendarSelection, _ m: WindowModel) -> some View {
        let state = paneState(week, sel.view, m)
        if state != .meetings {
            CalendarStatePane(state: state, emptyTitle: sel.view == .month ? "No Meetings This Month" : "No Meetings This Week") {
                if sel.view == .month { week.showMonth(containing: week.focusDay) } else { week.refresh() }
            }
        } else {
            let failure = CalendarPaneState.failure(week.state)
            switch sel.view {
            case .list:
                CalendarAgendaPane(week: week)
            case .month:
                MonthGrid(week: week, selectedID: sel.meetingID,
                          select: { CalendarSection.select($0, m) }, openDay: { CalendarSection.openDay($0, m) })
                    .refreshStatus(false, failure: failure, label: "Updating Calendar",
                                   retry: { week.showMonth(containing: week.focusDay) })
            case .day, .workWeek, .week:
                let keys = sel.view == .day ? [week.dayViewKey]
                    : sel.view == .workWeek ? CalendarSection.workWeekKeys(week) : week.dayKeys
                WeekGrid(week: week, keys: keys, selectedID: sel.meetingID,
                         select: { CalendarSection.select($0, m) },
                         openDay: sel.view == .day ? nil : { CalendarSection.openDay($0, m) })
                    .refreshStatus(week.state == .loading, failure: failure,
                                   label: "Updating Calendar", retry: { week.refresh() })
            }
        }
    }
}

// MARK: List view

struct CalendarAgendaPane: View {
    @ObservedObject var week: CalendarWeekStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let state = paneState(week, .list, model)
            if state == .meetings {
                // R12: a refresh or week change runs behind the rows.
                list(model)
                    .refreshStatus(week.state == .loading, failure: CalendarPaneState.failure(week.state),
                                   label: "Updating Calendar", retry: { week.refresh() })
            } else {
                CalendarStatePane(state: state, emptyTitle: "No Meetings This Week") { week.refresh() }
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
            if let id = ids.first, let meeting = week.row(id: id) {
                CalendarMeetingMenu(meeting: meeting, week: week)
            }
        } primaryAction: { ids in
            if let id = ids.first, let meeting = week.row(id: id) { CalendarSection.showDetails(meeting, m) }
        }
    }
}

/// Context menu shared by the List view, grids and month chips.
struct CalendarMeetingMenu: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let m = model {
            Button("Open Details") { CalendarSection.showDetails(meeting, m) }
            if meeting.joinURL?.isEmpty == false {
                Button("Join") { CalendarSection.join(meeting, m) }
                Button("Copy Join Link") { CalendarSection.copyJoinLink(meeting) }
            }
            if meeting.chatThreadID != nil {
                Button("Chat with Participants") { CalendarSection.openChat(meeting, m) }
            }
            if !meeting.isOrganizer, meeting.info != nil {
                Divider()
                RSVPMenuItems(meeting: meeting, week: week)
            }
            if meeting.isOrganizer {
                Divider()
                Button("Edit\u{2026}") { CalendarSection.edit(meeting, m) }
                Button("Cancel Meeting\u{2026}") { CalendarSection.confirmCancel(meeting, m) }
            }
        }
    }
}

/// Accept / Tentative / Decline (series: this event or the series).
struct RSVPMenuItems: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore

    var body: some View {
        ForEach(RSVPAction.allCases, id: \.rawValue) { action in
            if meeting.isSeries {
                Menu(action.title) {
                    Button("This Event") { week.respond(to: meeting, action) }
                    Button("All Events in the Series") { week.respond(to: meeting, action, series: true) }
                }
            } else {
                Button(action.title) { week.respond(to: meeting, action) }
            }
        }
    }
}

/// List row (§6.4): time range (monospaced digits), subject,
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
                    if meeting.isSeries {
                        Image(systemName: "arrow.2.squarepath")
                            .font(AppFont.caption(scale))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Series")
                    }
                }
                Text(CalendarFormat.range(meeting))
                    .font(AppFont.subheadline(scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let sub = [meeting.organizer, meeting.info?.location].compactMap { $0 }.filter { !$0.isEmpty }
                if !sub.isEmpty {
                    Text(sub.joined(separator: " \u{00B7} "))
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let r = meeting.info?.myResponse, !meeting.isOrganizer, r != .accepted {
                Text(r.isPending ? "Not responded" : r.label)
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
            }
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

// MARK: inspector

/// The selected meeting (§5.3, §6.4), Teams-popover fields.
struct CalendarInspectorPane: View {
    @ObservedObject var week: CalendarWeekStore
    @ObservedObject var conv: ConversationStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let id = CalendarSection.current(model).meetingID, let meeting = week.row(id: id) {
            MeetingInspector(meeting: meeting, week: week)
        } else {
            NoSelectionPane("No Meeting Selected")
        }
    }
}

/// Teams popover parity: title + expand, Join / Chat, when (+ Series),
/// location, organizer + response counts, your response + Change.
struct MeetingInspector: View {
    let meeting: MeetingItem
    @ObservedObject var week: CalendarWeekStore
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    private var online: Bool { meeting.joinURL?.isEmpty == false }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meeting.subject)
                        .font(AppFont.title3(scale))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { if let model { CalendarSection.showDetails(meeting, model) } } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Open meeting details")
                    .accessibilityLabel("Open meeting details")
                }
                if online || meeting.chatThreadID != nil {
                    HStack(spacing: 8) {
                        if online {
                            Button("Join") { if let model { CalendarSection.join(meeting, model) } }
                                .buttonStyle(.borderedProminent)
                        }
                        if meeting.chatThreadID != nil {
                            Button { if let model { CalendarSection.openChat(meeting, model) } } label: {
                                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                            }
                            .help("Chat with participants")
                        }
                    }
                }
                CalendarFactRow(symbol: "clock") {
                    Text(CalendarFormat.when(meeting)).monospacedDigit()
                    if meeting.isSeries {
                        SeriesBadge()
                    }
                    if let other = CalendarFormat.organizerTime(meeting) {
                        Text(other).foregroundStyle(.secondary).font(AppFont.caption(scale))
                    }
                }
                CalendarFactRow(symbol: "mappin.and.ellipse") {
                    if let place = meeting.info?.location {
                        Text(place).textSelection(.enabled)
                    } else {
                        Text("No location added").foregroundStyle(.secondary)
                    }
                }
                CalendarFactRow(symbol: "person.2") {
                    if !meeting.isOrganizer, let org = meeting.organizer, !org.isEmpty {
                        HStack(spacing: 4) {
                            Text(org).contactHover(name: org, email: meeting.organizerEmail, arrowEdge: .bottom)
                            Text("invited you.")
                        }
                    } else {
                        Text(inviteLine)
                    }
                    if let counts = CalendarDetailsText.counts(meeting) {
                        Text(counts).foregroundStyle(.secondary)
                    }
                }
                if !meeting.isOrganizer, let info = meeting.info {
                    CalendarFactRow(symbol: CalendarDetailsText.responseSymbol(info.myResponse)) {
                        HStack(spacing: 8) {
                            Text(info.myResponse.isPending ? "Not responded" : info.myResponse.label)
                            Menu(info.myResponse.isPending ? "Respond" : "Change") {
                                RSVPMenuItems(meeting: meeting, week: week)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(week.respondingID != nil)
                        }
                        if let error = week.rsvpError {
                            Text(error).foregroundStyle(Palette.failed).font(AppFont.caption(scale))
                        }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Button("Details\u{2026}") { if let model { CalendarSection.showDetails(meeting, model) } }
                    if online {
                        Button("Copy Link") { CalendarSection.copyJoinLink(meeting) }
                    }
                    if meeting.isOrganizer {
                        Button("Edit\u{2026}") { if let model { CalendarSection.edit(meeting, model) } }
                    }
                }
                if meeting.isOrganizer {
                    Button("Cancel Meeting\u{2026}", role: .destructive) {
                        if let model { CalendarSection.confirmCancel(meeting, model) }
                    }
                }
            }
            .font(AppFont.body(scale))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inviteLine: String {
        if meeting.isOrganizer { return "You organized this meeting." }
        guard let org = meeting.organizer, !org.isEmpty else { return "Invitation" }
        return "\(org) invited you."
    }
}

/// Icon + stacked lines (Teams popover rows).
struct CalendarFactRow<Content: View>: View {
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SeriesBadge: View {
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        Label("Series", systemImage: "arrow.2.squarepath")
            .font(AppFont.caption(scale))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.tint.opacity(0.15)))
            .foregroundStyle(.tint)
    }
}

/// Shared wording for the inspector and the details popup.
enum CalendarDetailsText {
    /// "Accepted 3, Tentative 1, Declined 1, Didn't respond 2" (zero
    /// groups omitted); nil with no attendees.
    static func counts(_ m: MeetingItem) -> String? {
        guard let info = m.info, !info.people.isEmpty else { return nil }
        let t = info.tally
        let parts = [("Accepted", t.accepted), ("Tentative", t.tentative), ("Declined", t.declined),
                     ("Didn\u{2019}t respond", t.pending)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func responseSymbol(_ r: RSVPResponse) -> String {
        switch r {
        case .accepted, .organizer: "checkmark.circle"
        case .tentativelyAccepted: "questionmark.circle"
        case .declined: "xmark.circle"
        case .none, .notResponded: "circle.dashed"
        }
    }
}
