// CalendarSheets.swift — New Meeting… and Join with ID or Link…
// (UI-SPEC §6.4, §9.5). Presented by SheetPresenter; Cancel + a
// default action. New Meeting schedules through `CalendarWeekStore`
// (demo: in-memory); Join parses through `MeetingsViewModel`
// (`JoinParse`) and opens the call pre-join in the chosen presentation.
import OstMacCore
import SwiftUI

private struct CalendarSheetFrame<Content: View>: View {
    let title: String
    let action: String
    let enabled: Bool
    let busy: String?
    let error: String?
    let perform: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.windowModel) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let busy {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary)
                    } else if let error {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                        Text(error).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                // A real spacer: the status stack is empty when idle, and a
                // frame on empty content does not render, which pinned the
                // buttons leading. Buttons trail (HIG).
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) {
                    model?.app?.calWeek.clearUpdateError()
                    model?.dismissSheet()
                }
                .keyboardShortcut(.cancelAction)
                Button(action, action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled || busy != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

private func prompt(_ s: String) -> Text {
    Text(s).foregroundStyle(Color(nsColor: .placeholderTextColor))
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// New Meeting (§6.4): subject, start, end, Teams-meeting toggle.
struct NewMeetingSheet: View {
    @ObservedObject var week: CalendarWeekStore
    @State private var subject = ""
    @State private var start = NewMeetingSheet.nextHalfHour(RelativeClock.shared.now)
    @State private var end = NewMeetingSheet.nextHalfHour(RelativeClock.shared.now).addingTimeInterval(1800)
    @State private var online = true
    @State private var submitted = false
    @Environment(\.windowModel) private var model

    var body: some View {
        CalendarSheetFrame(title: "New Meeting", action: "Schedule",
                           enabled: !trimmed(subject).isEmpty && end > start,
                           busy: week.scheduling ? "Scheduling…" : nil,
                           error: submitted ? week.scheduleError : nil, perform: schedule) {
            Form {
                TextField("Subject", text: $subject, prompt: prompt("Add a title"))
                DatePicker("Starts", selection: $start)
                DatePicker("Ends", selection: $end)
                Toggle("Teams meeting", isOn: $online)
            }
            .formStyle(.columns)
        }
        .onChange(of: week.scheduling) { _, busy in
            // Async (live) path: close once the created event landed.
            if !busy, submitted, week.scheduleError == nil { model?.dismissSheet() }
        }
    }

    private func schedule() {
        submitted = true
        week.schedule(subject: subject, start: CalWeek.graphDateTime(start),
                      end: CalWeek.graphDateTime(end), online: online)
        // Local (demo) path completes synchronously.
        if !week.scheduling, week.scheduleError == nil { model?.dismissSheet() }
    }

    /// The next :00 or :30 after `d`, on the exact boundary. Truncates
    /// to the minute first: `date(bySetting: .second, value: 0, of:)`
    /// searches forward, so a non-zero second landed a minute late
    /// (10:01 / 10:31).
    static func nextHalfHour(_ d: Date, calendar cal: Calendar = .current) -> Date {
        let minute = cal.dateInterval(of: .minute, for: d)?.start ?? d
        let m = cal.component(.minute, from: minute)
        let add = m < 30 ? 30 - m : 60 - m
        return cal.date(byAdding: .minute, value: add, to: minute) ?? minute
    }
}

/// Join with ID or Link (§6.4): a meeting ID + passcode, or a pasted
/// Teams link / meeting thread. An ID resolves through Graph
/// (`MeetingsViewModel.joinByMeetingID`) to the meeting's join link and
/// joins in-app; an ID that can't be resolved shows an error (never a
/// browser hand-off).
struct JoinMeetingSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case meetingID = "Meeting ID"
        case link = "Link"
        var id: Self { self }
    }

    @ObservedObject var meetings: MeetingsViewModel
    @State private var mode = Mode.meetingID
    @State private var meetingID = ""
    @State private var passcode = ""
    @State private var text = ""
    @State private var submitted = false
    @Environment(\.windowModel) private var model

    private var joinText: String? {
        switch mode {
        case .meetingID: Self.meetURL(id: meetingID, passcode: passcode)
        case .link: trimmed(text).isEmpty ? nil : trimmed(text)
        }
    }

    var body: some View {
        CalendarSheetFrame(title: "Join with ID or Link", action: "Join", enabled: joinText != nil,
                           busy: meetings.resolvingMeetingID ? "Finding meeting\u{2026}" : nil,
                           error: submitted && mode == .meetingID ? meetings.meetingIDError : nil,
                           perform: join) {
            Picker("Join with", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                switch mode {
                case .meetingID:
                    TextField("Meeting ID", text: $meetingID, prompt: prompt("123 456 789 012"))
                    TextField("Passcode", text: $passcode, prompt: prompt("Required"))
                case .link:
                    TextField("Meeting link", text: $text, prompt: prompt("Paste a Teams meeting link"))
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                InfoButton(subject: "joining by link",
                           text: "The meeting opens where you chose to show calls in Settings.")
            }
        }
        .onChange(of: meetings.resolvingMeetingID) { _, busy in
            guard !busy, submitted, mode == .meetingID, meetings.meetingIDError == nil else { return }
            resolved()
        }
    }

    /// `https://teams.microsoft.com/meet/<digits>?p=<passcode>` for a
    /// meeting ID (spaces allowed, 9–15 digits) and a non-blank passcode;
    /// nil when either is missing or malformed.
    static func meetURL(id: String, passcode: String) -> String? {
        let digits = id.filter { !$0.isWhitespace }
        let pass = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (9 ... 15).contains(digits.count), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              !pass.isEmpty,
              let p = pass.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "=", "+", "#"]))
        else { return nil }
        return "https://teams.microsoft.com/meet/\(digits)?p=\(p)"
    }

    private func join() {
        guard let m = model, let raw = joinText else { return }
        if mode == .meetingID {
            // One call at a time: a running call comes forward instead.
            if let running = m.call, !running.ended {
                m.dismissSheet()
                running.show()
                return
            }
            submitted = true
            meetings.joinByMeetingID(meetingID, passcode: passcode)
            return
        }
        m.dismissSheet()
        guard m.beginCall(.meeting(id: raw, subject: "Meeting")) != nil else { return }
        meetings.joinText = raw
        meetings.submitJoin()
    }

    /// Meeting ID lookup finished without error: close the sheet. Found →
    /// the call opens on its pre-join. Not found / failed keep the sheet
    /// open with the error (never a browser hand-off).
    private func resolved() {
        guard let m = model else { return }
        m.dismissSheet()
        guard meetings.lastMeetingIDRoute == .inApp else { return }
        _ = m.beginCall(.meeting(id: meetings.joinText, subject: "Meeting"))
    }
}

/// Meet now (Teams calendar): name the meeting, then start it at once
/// or get a link to share. Creates an online meeting from now in the
/// signed-in user's calendar with no one else invited.
struct MeetNowSheet: View {
    @ObservedObject var week: CalendarWeekStore
    @State private var name = ""
    @State private var created: MeetingItem?
    @State private var copied = false
    @Environment(\.windowModel) private var model

    private var defaultName: String { "Meeting with \(model?.ownDisplayName ?? "You")" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a meeting now").font(.headline)
            Form {
                TextField("Meeting name", text: $name, prompt: prompt(defaultName))
                    .disabled(created != nil)
            }
            .formStyle(.columns)
            if let created, let link = created.joinURL {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark.circle.fill" : "link").foregroundStyle(.tint)
                    Text(copied ? "Meeting link copied" : "Meeting link").foregroundStyle(.secondary)
                    Text(link).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(link)
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if week.meetingNow {
                        ProgressView().controlSize(.small)
                        Text("Creating meeting\u{2026}").foregroundStyle(.secondary)
                    } else if let error = week.meetNowError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                        Text(error).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                if created == nil {
                    Button("Get a link to share") { Task { await create(start: false) } }
                        .disabled(week.meetingNow)
                }
                Button("Start meeting") {
                    if let created { start(created) } else { Task { await create(start: true) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(week.meetingNow)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func close() {
        week.clearMeetNowError()
        model?.dismissSheet()
    }

    private func create(start now: Bool) async {
        let subject = trimmed(name).isEmpty ? defaultName : trimmed(name)
        guard let row = await week.meetNow(subject: subject) else { return }
        created = row
        if now {
            start(row)
        } else {
            CalendarSection.copyJoinLink(row)
            copied = row.joinURL != nil
        }
    }

    private func start(_ row: MeetingItem) {
        guard let m = model else { return }
        m.dismissSheet()
        CalendarSection.join(row, m)
    }
}

/// Edit an event you organize: title, time, location. A series
/// occurrence edits this event or (title/location) the whole series.
struct EditEventSheet: View {
    @ObservedObject var week: CalendarWeekStore
    let meeting: MeetingItem
    @State private var subject: String
    @State private var start: Date
    @State private var end: Date
    @State private var location: String
    @State private var wholeSeries = false
    @Environment(\.windowModel) private var model

    init(week: CalendarWeekStore, meeting: MeetingItem) {
        self.week = week
        self.meeting = meeting
        let s = CalendarFormat.date(meeting.start) ?? RelativeClock.shared.now
        _subject = State(initialValue: meeting.subject)
        _start = State(initialValue: s)
        _end = State(initialValue: CalendarFormat.date(meeting.end) ?? s.addingTimeInterval(1800))
        _location = State(initialValue: meeting.info?.location ?? "")
    }

    private var patch: CalendarEventPatch {
        var p = CalendarEventPatch()
        if trimmed(subject) != meeting.subject { p.subject = trimmed(subject) }
        if trimmed(location) != (meeting.info?.location ?? "") { p.location = trimmed(location) }
        if !wholeSeries, !meeting.isAllDay {
            let s = CalWeek.graphDateTime(start), e = CalWeek.graphDateTime(end)
            if s != meeting.start.map({ String($0.prefix(19)) }) { p.start = s }
            if e != meeting.end.map({ String($0.prefix(19)) }) { p.end = e }
            // A moved meeting always sends both ends.
            if p.start != nil || p.end != nil { p.start = s; p.end = e }
        }
        return p
    }

    var body: some View {
        CalendarSheetFrame(title: "Edit Meeting", action: "Save",
                           enabled: !trimmed(subject).isEmpty && end > start && !patch.isEmpty,
                           busy: week.updating ? "Saving\u{2026}" : nil,
                           error: week.updateError, perform: save) {
            Form {
                if meeting.isSeries {
                    Picker("Apply to", selection: $wholeSeries) {
                        Text("This event").tag(false)
                        Text("All events in the series").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                TextField("Title", text: $subject, prompt: prompt("Add a title"))
                if !meeting.isAllDay {
                    DatePicker("Starts", selection: $start)
                        .disabled(wholeSeries)
                    DatePicker("Ends", selection: $end)
                        .disabled(wholeSeries)
                }
                TextField("Location", text: $location, prompt: prompt("Add a location"))
            }
            .formStyle(.columns)
            if wholeSeries {
                HStack {
                    Spacer()
                    InfoButton(subject: "editing a series",
                               text: "Series times stay as they are; title and location change for every event.")
                }
            }
        }
    }

    private func save() {
        let p = patch
        Task {
            if await week.update(meeting, patch: p, series: wholeSeries) {
                model?.dismissSheet()
            }
        }
    }
}

/// Duplicate event (CALDETAIL): the new-event form prefilled with a copy
/// of an event — title, time, Teams meeting, location, people and rooms;
/// the description, categories, show-as, reminder and sensitivity carry
/// over unseen. Also the scheduling assistant's "New meeting at this time".
struct DuplicateEventSheet: View {
    @ObservedObject var week: CalendarWeekStore
    let draft: CalendarEventDraft
    var title = "Duplicate Event"
    @State private var subject: String
    @State private var start: Date
    @State private var end: Date
    @State private var online: Bool
    @State private var location: String
    @State private var people: [EventAttendee]
    @State private var typed = ""
    @Environment(\.windowModel) private var model

    init(week: CalendarWeekStore, draft: CalendarEventDraft, title: String = "Duplicate Event") {
        self.week = week
        self.draft = draft
        self.title = title
        _subject = State(initialValue: draft.subject)
        _start = State(initialValue: draft.start)
        _end = State(initialValue: draft.end)
        _online = State(initialValue: draft.online)
        _location = State(initialValue: draft.location ?? "")
        _people = State(initialValue: draft.attendees.filter { !$0.isRoom })
    }

    /// The draft as edited: the chips plus any address still typed.
    var edited: CalendarEventDraft {
        var d = draft
        d.subject = trimmed(subject)
        d.start = start
        d.end = end
        d.online = online
        d.location = trimmed(location).isEmpty ? nil : trimmed(location)
        let pending = CalendarWeekStore.recipients(typed)
            .filter { a in !people.contains { $0.email.lowercased() == a.lowercased() } }
            .map { EventAttendee(name: $0, email: $0) }
        d.attendees = people + pending + draft.attendees.filter(\.isRoom)
        return d
    }

    var body: some View {
        CalendarSheetFrame(title: title, action: "Save",
                           enabled: !trimmed(subject).isEmpty && end > start,
                           busy: week.creating ? "Saving\u{2026}" : nil,
                           error: week.createError, perform: save) {
            Form {
                TextField("Title", text: $subject, prompt: prompt("Add a title"))
                if draft.isAllDay {
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                    DatePicker("Ends", selection: $end, displayedComponents: .date)
                } else {
                    DatePicker("Starts", selection: $start)
                    DatePicker("Ends", selection: $end)
                }
                AttendeeChipsEditor(people: $people, typed: $typed)
                TextField("Location", text: $location, prompt: prompt("Add a location"))
                Toggle("Teams meeting", isOn: $online)
            }
            .formStyle(.columns)
            if !draft.attendees.isEmpty || draft.bodyHTML != nil {
                Text("Saving sends the invitation to the attendees. The description and categories are copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { week.clearCreateError() }
    }

    private func save() {
        let d = edited
        Task {
            if await week.create(d) != nil { model?.dismissSheet() }
        }
    }
}

/// New webinar (CAL2-4): a draft Teams webinar (title, time). Graph
/// virtual events create it unpublished; registration and publishing
/// stay in Teams.
struct NewWebinarSheet: View {
    @ObservedObject var week: CalendarWeekStore
    @State private var title = ""
    @State private var start = NewMeetingSheet.nextHalfHour(RelativeClock.shared.now).addingTimeInterval(86_400)
    @State private var end = NewMeetingSheet.nextHalfHour(RelativeClock.shared.now).addingTimeInterval(86_400 + 3600)
    @State private var createdID: String?
    @Environment(\.windowModel) private var model

    var body: some View {
        CalendarSheetFrame(title: "New Webinar", action: createdID == nil ? "Create Draft" : "Done",
                           enabled: createdID != nil || (!trimmed(title).isEmpty && end > start),
                           busy: week.creating ? "Creating\u{2026}" : nil,
                           error: week.createError, perform: create) {
            if createdID != nil {
                Label("Draft webinar created. Finish registration and publish it in Teams.",
                      systemImage: "checkmark.circle")
            } else {
                Form {
                    TextField("Title", text: $title, prompt: prompt("Webinar title"))
                    DatePicker("Starts", selection: $start)
                    DatePicker("Ends", selection: $end)
                }
                .formStyle(.columns)
                Text("Webinars need a Teams webinar license. Attendees register on the event page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { week.clearCreateError() }
    }

    private func create() {
        if createdID != nil {
            model?.dismissSheet()
            return
        }
        Task { createdID = await week.createWebinar(title: title, start: start, end: end) }
    }
}
