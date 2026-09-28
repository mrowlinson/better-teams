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
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
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
/// joins in-app; an ID Graph can't see falls back to the web
/// `meet/<id>?p=<passcode>` link in the browser.
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
            Text("The meeting opens where you chose to show calls in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    /// the call opens on its pre-join; not found → the web link already
    /// went to the browser, so no call window.
    private func resolved() {
        guard let m = model else { return }
        m.dismissSheet()
        guard meetings.lastMeetingIDRoute == .inApp else { return }
        _ = m.beginCall(.meeting(id: meetings.joinText, subject: "Meeting"))
    }
}
