// CalendarSchedulingAssistant.swift — CAL2-5 scheduling assistant
// (Teams "Scheduler"): free/busy for the meeting's people (Graph
// getSchedule) on a day, 8 AM–6 PM in half hours, and suggested times
// when everyone readable is free. The organizer moves the meeting to a
// suggestion; otherwise a suggestion starts a new meeting with those
// people. The previous grid stays up while a new day/person loads.
import OstMacCore
import SwiftUI

struct SchedulingAssistantSheet: View {
    @ObservedObject var week: CalendarWeekStore
    let meeting: MeetingItem?
    @State private var day: Date
    @State private var minutes: Int
    @State private var people: [String]
    @State private var adding = ""
    /// The band's start when moved (dragged or picked from a suggestion); nil = the meeting's own slot.
    @State private var proposed: Date?
    @State private var dragBase: Date?
    @State private var drafting: CalendarEventDraft?
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    static let firstHour = 8, lastHour = 18

    struct Length: Identifiable {
        var id: Int { minutes }
        let minutes: Int
    }

    static let lengths = [15, 30, 45, 60, 90, 120].map(Length.init)

    /// One half-hour column (identity = its start).
    struct Slot: Identifiable {
        var id: Date { start }
        let start: Date
        let labeled: Bool
    }

    init(week: CalendarWeekStore, meeting: MeetingItem?) {
        self.week = week
        self.meeting = meeting
        let start = CalendarFormat.date(meeting?.start) ?? RelativeClock.shared.now
        let end = CalendarFormat.date(meeting?.end) ?? start.addingTimeInterval(1800)
        _day = State(initialValue: Calendar.current.startOfDay(for: start))
        _minutes = State(initialValue: max(30, Int(end.timeIntervalSince(start) / 60)))
        var list = (meeting?.invitees ?? []).map(\.email).filter { !$0.isEmpty }
        if let org = meeting?.organizerEmail { list.insert(org, at: 0) }
        _people = State(initialValue: Array(NSOrderedSet(array: list.map { $0.lowercased() })) as? [String] ?? list)
    }

    /// Display name per address (attendees + organizer); unknown
    /// addresses (typed in) show as the address itself.
    private func displayName(_ email: String) -> String {
        let hit = meeting?.info?.people.first { $0.email.lowercased() == email }
        if let org = meeting?.organizerDisplay, email == meeting?.organizerEmail?.lowercased() {
            return hit?.isMe == true ? org + " (You)" : org
        }
        return hit.map(\.label).flatMap { $0.isEmpty ? nil : $0 } ?? CalendarNames.display(nil, email: email)
    }

    private var window: (from: Date, to: Date) {
        let cal = Calendar.current
        let from = cal.date(bySettingHour: Self.firstHour, minute: 0, second: 0, of: day) ?? day
        let to = cal.date(bySettingHour: Self.lastHour, minute: 0, second: 0, of: day) ?? day.addingTimeInterval(36_000)
        return (from, to)
    }

    /// Working hours for suggestions (the grid runs a little later).
    private static let workHours = 8 ..< 17

    private var ranked: [CalendarFreeBusy.Suggestion] {
        let rows = week.freeBusy.filter { people.contains($0.email.lowercased()) }
        let from = max(window.from, Calendar.current.isDateInToday(day) ? RelativeClock.shared.now : window.from)
        return CalendarFreeBusy.rankedSuggestions(rows, from: from, to: window.to, length: TimeInterval(minutes * 60),
                                                  hours: Self.workHours)
    }

    private var suggestions: [DateInterval] { ranked.map(\.slot) }

    private func conflictLabel(_ s: CalendarFreeBusy.Suggestion) -> String {
        switch s.conflicts.count {
        case 0: "Everyone is free"
        case 1: "1 conflict: \(displayName(s.conflicts[0].lowercased()))"
        default: "\(s.conflicts.count) conflicts"
        }
    }

    var body: some View {
        if let drafting {
            DuplicateEventSheet(week: week, draft: drafting, title: "New Meeting")
        } else {
            assistant
        }
    }

    private var assistant: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Scheduling Assistant").font(.headline)
                Spacer()
                DatePicker("Day", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .fixedSize()
                Picker("Length", selection: $minutes) {
                    ForEach(Self.lengths) { Text("\($0.minutes) min").tag($0.minutes) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: 6) {
                TextField("Add people", text: $adding, prompt: Text("Add an email address"))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(!CalendarWeekStore.recipients(adding).contains { $0.contains("@") })
            }
            grid
            suggestionList
            HStack {
                if let error = week.freeBusyError ?? week.updateError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                    Text(error).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Close") { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
            }
            .font(.caption)
        }
        .padding(20)
        .frame(width: 780, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .onChange(of: day) { _, _ in load() }
        .onChange(of: people) { _, _ in load() }
    }

    private func add() {
        let new = CalendarWeekStore.recipients(adding).map { $0.lowercased() }.filter { $0.contains("@") && !people.contains($0) }
        people += new
        adding = ""
    }

    private func load() {
        week.loadFreeBusy(people, from: window.from, to: window.to)
    }

    // MARK: grid

    private var slots: [Slot] {
        stride(from: 0, to: (Self.lastHour - Self.firstHour) * 2, by: 1).map {
            Slot(start: window.from.addingTimeInterval(TimeInterval($0 * 1800)), labeled: $0 % 2 == 0)
        }
    }

    private var grid: some View {
        let cellW: CGFloat = 26
        let rowsHeight = CGFloat(max(1, people.count)) * 20 + CGFloat(max(0, people.count - 1)) * 2
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("").frame(width: 190, alignment: .leading)
                ForEach(slots.filter(\.labeled)) { slot in
                    Text(slot.start.formatted(.dateTime.hour()))
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: cellW * 2, alignment: .leading)
                }
            }
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(people.map(NamedItem.init)) { item in
                        let email = item.id
                        let row = week.freeBusy.first { $0.email.lowercased() == email }
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                let shown = displayName(email)
                                Avatar(name: shown, diameter: 20, person: ContactRef(name: shown, email: email))
                                Text(shown).lineLimit(1).truncationMode(.middle).help(email)
                                if meeting == nil || email != meeting?.organizerEmail?.lowercased() {
                                    Button { people.removeAll { $0 == email } } label: { Image(systemName: "xmark.circle") }
                                        .buttonStyle(.borderless)
                                        .help("Remove from the assistant")
                                }
                            }
                            .frame(width: 190, alignment: .leading)
                            if row?.unavailable == true {
                                Text("No free/busy information").foregroundStyle(.secondary)
                                    .font(AppFont.caption(scale))
                            } else {
                                ForEach(slots) { slot in
                                    cell(status(row, at: slot.start))
                                        .frame(width: cellW - 2, height: 18)
                                        .padding(.trailing, 2)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: min(250, rowsHeight))
            }
            .overlay(alignment: .topLeading) { band(cellW: cellW) }
            HStack(spacing: 12) {
                legend("busy", "Busy")
                legend("tentative", "Tentative")
                if seen.contains("oof") { legend("oof", "Away") }
                if seen.contains("workingElsewhere") { legend("workingElsewhere", "Working elsewhere") }
                if week.freeBusyLoading { ProgressView().controlSize(.mini) }
            }
            .font(AppFont.caption(scale))
            .padding(.top, 6)
        }
    }

    /// Statuses present in the loaded free/busy data (legend shows only these plus Busy/Tentative).
    private var seen: Set<String> {
        Set(week.freeBusy.flatMap(\.blocks).map(\.status))
    }

    /// The scheduled slot: the meeting's own time, or where it was moved to.
    private var bandStart: Date? { proposed ?? CalendarFormat.date(meeting?.start) }

    private var bandInterval: DateInterval? {
        guard let s = bandStart else { return nil }
        return DateInterval(start: s, duration: TimeInterval(minutes * 60))
    }

    /// Teams' current-time band: an accent column over every row, from
    /// the slot's start to its end; drag it in half hours to try a time.
    @ViewBuilder private func band(cellW: CGFloat) -> some View {
        if let b = bandInterval, Calendar.current.isDate(b.start, inSameDayAs: window.from) {
            let first = b.start.timeIntervalSince(window.from) / 1800
            let count = b.duration / 1800
            let x = 190 + CGFloat(max(0, first)) * cellW
            let w = min(CGFloat(count) * cellW, 190 + CGFloat(slots.count) * cellW - x)
            if w > 0 {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 2) }
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.accentColor).frame(width: 2) }
                    .frame(width: w)
                    .padding(.leading, x)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            let base = dragBase ?? b.start
                            dragBase = base
                            let steps = (v.translation.width / cellW).rounded()
                            let moved = base.addingTimeInterval(TimeInterval(steps) * 1800)
                            let latest = window.to.addingTimeInterval(-b.duration)
                            proposed = min(max(moved, window.from), max(window.from, latest))
                        }
                        .onEnded { _ in dragBase = nil })
                    .help("Drag to try another time")
                    .accessibilityLabel("Scheduled time band")
            }
        }
    }

    private func status(_ row: CalendarFreeBusy?, at t: Date) -> String? {
        guard let row else { return nil }
        let end = t.addingTimeInterval(1800)
        let hits = row.blocks.filter { $0.start < end && $0.end > t }.map(\.status)
        for s in ["oof", "busy", "tentative", "workingElsewhere"] where hits.contains(s) { return s }
        return hits.isEmpty ? "free" : nil
    }

    @ViewBuilder private func cell(_ status: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        switch status {
        case "busy": shape.fill(Color.accentColor)
        case "oof": shape.fill(Color.purple)
        case "tentative": shape.fill(Color.accentColor.opacity(0.2)).overlay(shape.strokeBorder(Color.accentColor, lineWidth: 1))
        case "workingElsewhere": shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [2]))
        case "free": shape.fill(Color.primary.opacity(0.05))
        default: shape.fill(Color.primary.opacity(0.02))
        }
    }

    private func legend(_ s: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            cell(s).frame(width: 12, height: 10)
            Text(title).foregroundStyle(.secondary)
        }
    }

    // MARK: suggestions

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested times").font(AppFont.subheadline(scale).weight(.semibold))
            let list = ranked
            if people.isEmpty {
                Text("Add people to see their free/busy and times that suit everyone.").foregroundStyle(.secondary)
            } else if list.isEmpty {
                Text(week.freeBusy.isEmpty ? "Free/busy appears here once it loads."
                     : "No time inside working hours on this day.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list, id: \.slot.start) { item in
                    let slot = item.slot
                    HStack(spacing: 10) {
                        Text("\(CalendarFormat.time(slot.start)) \u{2013} \(CalendarFormat.time(slot.end))")
                            .monospacedDigit()
                        Text(conflictLabel(item)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if let meeting, meeting.isOrganizer, !meeting.isAllDay {
                            Button("Move Meeting Here") { move(meeting, to: slot) }
                                .disabled(week.updating)
                        } else {
                            Button("New Meeting at This Time") { newMeeting(slot) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(bandInterval?.start == slot.start ? Color.accentColor.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { proposed = slot.start }
                }
                selectedTime
            }
        }
    }

    /// A dragged band that is not one of the suggestions: its time, who
    /// is busy then, and the same actions.
    @ViewBuilder private var selectedTime: some View {
        if let p = proposed, let b = bandInterval, !suggestions.contains(where: { $0.start == p }) {
            let busy = week.freeBusy.filter { people.contains($0.email.lowercased()) }.filter { row in
                row.blocks.contains { $0.start < b.end && $0.end > b.start && $0.status != "free" }
            }
            HStack(spacing: 10) {
                Text("\(CalendarFormat.time(b.start)) \u{2013} \(CalendarFormat.time(b.end))").monospacedDigit()
                Text(busy.isEmpty ? "Everyone is free"
                     : "\(busy.count) busy: " + busy.map { displayName($0.email.lowercased()) }.joined(separator: ", "))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let meeting, meeting.isOrganizer, !meeting.isAllDay {
                    Button("Move Meeting Here") { move(meeting, to: b) }.disabled(week.updating)
                } else {
                    Button("New Meeting at This Time") { newMeeting(b) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.12)))
        }
    }

    private func move(_ m: MeetingItem, to slot: DateInterval) {
        let patch = CalendarEventPatch(start: CalWeek.graphDateTime(slot.start), end: CalWeek.graphDateTime(slot.end))
        Task { if await week.update(m, patch: patch) { model?.dismissSheet() } }
    }

    private func newMeeting(_ slot: DateInterval) {
        let people = self.people.filter { $0 != meeting?.organizerEmail?.lowercased() || meeting?.isOrganizer == false }
        drafting = CalendarEventDraft(
            subject: meeting.map { $0.subject } ?? "", start: slot.start, end: slot.end,
            attendees: people.map { EventAttendee(name: $0, email: $0) })
    }
}

/// Sheets opened by event id before the week landed (routes, fast
/// clicks) wait for the row, then show; nothing flashes meanwhile.
struct CalendarRowSheet<Content: View>: View {
    @ObservedObject var week: CalendarWeekStore
    let eventID: String?
    let content: (MeetingItem?) -> Content
    var needsRow = false
    @Environment(\.windowModel) private var model

    var body: some View {
        let row = eventID.flatMap(week.row(id:))
        if row != nil || !needsRow && (eventID == nil || week.state != .loading) {
            content(row)
        } else {
            VStack(spacing: 12) {
                LoadingPane("Loading event\u{2026}", rows: false)
                Button("Close") { model?.dismissSheet() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .frame(width: 440, height: 200)
        }
    }
}
