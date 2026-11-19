// MeetingExtrasViews.swift — MEETINGS-PLUS: attendance report, server
// capture toggles, and in-meeting recording control for the meeting
// details card (native AppKit/SwiftUI controls: toggles, buttons, rows).
//
// - Attendance: the meeting's report (GAPHUNT row 5). Live reads Graph
//   (`OnlineMeetings.Read` — not granted, so live shows the disabled
//   reason); demo/evidence reads the fixture.
// - Capture toggles: the meeting's persisted server options
//   (`allowRecording` / `allowTranscription` / `recordAutomatically`).
//   Live writes PATCH Graph (`OnlineMeetings.ReadWrite` — likewise not
//   granted); demo/evidence echoes.
// - Recording control: the meetrecord legs through `CallStore`
//   (`setRecording` / `setTranscribing`) — NEW here is only the meeting
//   context row; the menu + toolbars already drive the same legs, so no
//   menu or toolbar item is added, renamed, or renumbered.
import OstMacCore
import SwiftUI

/// Attendance report block for one online meeting.
struct MeetingAttendanceBlock: View {
    @StateObject private var store: MeetingAttendanceStore
    @Environment(\.contentTextScale) private var scale

    init(meetingID: String, isDemo: Bool) {
        _store = StateObject(wrappedValue: MeetingAttendanceStore(
            meetingID: meetingID,
            transport: isDemo
                ? DemoMeetingAttendanceTransport()
                : CoreMeetingAttendanceTransport()))
    }

    var body: some View {
        CalendarFactRow(symbol: "person.2") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Attendance")
                    .font(AppFont.bodyEmphasized(scale))
                switch store.state {
                case .loading:
                    ProgressView().controlSize(.small)
                case let .loaded(rows):
                    Text("\(rows.count) \(rows.count == 1 ? "person" : "people") attended")
                        .foregroundStyle(.secondary)
                        .font(AppFont.caption(scale))
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.displayName)
                                Text(row.spanLabel)
                                    .font(AppFont.caption(scale))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(row.role.capitalized)
                                .font(AppFont.caption(scale))
                                .foregroundStyle(.secondary)
                            Text(row.durationLabel)
                                .font(AppFont.caption(scale))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.displayName), \(row.role), \(row.durationLabel)")
                    }
                case .empty:
                    Text("No attendance report filed for this meeting yet.")
                        .foregroundStyle(.secondary)
                case let .failed(reason):
                    Text(reason).foregroundStyle(.secondary)
                    Button("Try Again") { store.reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.load() }
    }
}

/// Server capture toggles for one online meeting.
struct MeetingCaptureBlock: View {
    @StateObject private var store: MeetingCaptureStore
    @Environment(\.contentTextScale) private var scale
    @State private var recording = false
    @State private var transcription = false
    @State private var automatic = false
    @State private var seeded = false

    init(meetingID: String, isDemo: Bool) {
        _store = StateObject(wrappedValue: MeetingCaptureStore(
            meetingID: meetingID,
            transport: isDemo
                ? DemoMeetingCaptureTransport()
                : CoreMeetingCaptureTransport()))
    }

    var body: some View {
        CalendarFactRow(symbol: "video.badge.checkmark") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recording & transcription")
                    .font(AppFont.bodyEmphasized(scale))
                if store.loading {
                    ProgressView().controlSize(.small)
                } else if let error = store.error, store.options == nil {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { store.reload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Toggle("Allow recording", isOn: $recording)
                    Toggle("Allow transcription", isOn: $transcription)
                    Toggle("Record automatically", isOn: $automatic)
                        .help("Start recording as soon as the meeting starts")
                    if let error = store.error {
                        Text(error)
                            .font(AppFont.caption(scale))
                            .foregroundStyle(Palette.failed)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button("Save") {
                            store.save(MeetingCaptureOptions(
                                allowRecording: recording,
                                allowTranscription: transcription,
                                recordAutomatically: automatic))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(store.saving)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { store.load() }
        .onChange(of: store.options) { seed($0) }
    }

    private func seed(_ options: MeetingCaptureOptions?) {
        guard !seeded, let o = options else { return }
        seeded = true
        recording = o.allowRecording ?? false
        transcription = o.allowTranscription ?? false
        automatic = o.recordAutomatically ?? false
    }
}

/// In-meeting recording control: the meetrecord legs (`CallStore`) in
/// the meeting context. Enabled only with a connected call — the core
/// refutes anything earlier, and the refusal reads back below.
struct MeetingRecordBlock: View {
    @ObservedObject var call: CallStore
    @Environment(\.contentTextScale) private var scale

    private var connected: Bool { call.call?.isActive == true }

    var body: some View {
        CalendarFactRow(symbol: "record.circle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Meeting recording")
                    .font(AppFont.bodyEmphasized(scale))
                if !connected {
                    Text("Join the meeting to control recording.")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button(call.recording ? "Stop Recording" : "Record") {
                        call.setRecording(!call.recording)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!connected)
                    Button(call.transcribing && !call.recording ? "Stop Transcription" : "Transcribe") {
                        call.setTranscribing(!(call.transcribing && !call.recording))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!connected)
                    if call.recording {
                        Text("Recording")
                            .font(AppFont.caption(scale))
                            .foregroundStyle(.red)
                    } else if call.transcribing {
                        Text("Transcribing")
                            .font(AppFont.caption(scale))
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = call.controlsError {
                    Text(error)
                        .font(AppFont.caption(scale))
                        .foregroundStyle(Palette.failed)
                }
                Text("Recording also starts transcription. Stopping recording ends both.")
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The extras section for an online meeting's details card: recording
/// control (meetrecord legs), server toggles, and the attendance report.
struct MeetingExtrasBlock: View {
    /// Online meetings only (join link or flag): plain events never show
    /// recording or attendance UI. Pure so guard tests pin it.
    static func shows(for m: MeetingItem) -> Bool {
        m.joinURL?.isEmpty == false || m.isOnline
    }

    let meeting: MeetingItem
    let isDemo: Bool
    @ObservedObject var call: CallStore

    var body: some View {
        Divider()
        MeetingRecordBlock(call: call)
        MeetingCaptureBlock(meetingID: meeting.id, isDemo: isDemo)
        MeetingAttendanceBlock(meetingID: meeting.id, isDemo: isDemo)
    }
}
