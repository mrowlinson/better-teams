// MeetingRecapDemo.swift — RECAP2 demo recap (offline, same code path).
//
// The Platform Standup meeting chat (demo-3) has a recording, a Teams
// transcript (JSON, the live format), Loop meeting notes and an
// intelligent recap. Every other meeting reads as a meeting with none
// (honest empty parts), the way a live meeting without them does.
import Foundation

public struct MeetingRecapDemoTransport: MeetingRecapTransport {
    public static let fileURL =
        "https://contoso-my.sharepoint.com/personal/tom_becker_contoso_com/Documents/Recordings/Platform%20Standup-20260921_093000-Meeting%20Recording.mp4"
    public static let notesURL =
        "https://contoso-my.sharepoint.com/personal/tom_becker_contoso_com/Documents/Meetings/Platform%20Standup.loop"

    public init() {}

    static func isStandup(_ threadID: String) -> Bool { threadID == DemoData.standupID }

    public func sources(threadID: String) throws -> MeetingRecapSources {
        guard Self.isStandup(threadID) else { return .none }
        return MeetingRecapSources(
            recordings: [MeetingRecordingRef(id: "demo-rec-msg", title: "Platform Standup", file_url: Self.fileURL,
                                             duration_ms: 1_122_000, created: "2026-09-21T09:30:00Z",
                                             status: "Success")],
            transcripts: [MeetingTranscriptRef(id: "demo-tr-msg", file_url: Self.fileURL,
                                               created: "2026-09-21T09:49:00Z")],
            notes: [MeetingNotesRef(title: "Platform Standup notes", url: Self.notesURL)],
            pages: 1, complete: true)
    }

    public func recording(_ target: MeetingFileTarget) throws -> RecordingItem {
        let fileURL = target.file_url ?? Self.fileURL
        return RecordingItem(id: "demo-meeting-recording", name: "Platform Standup-20260921_093000-Meeting Recording.mp4",
                      size: 48_211_000, mime: "video/mp4", web_url: fileURL, drive_id: "demo-drive",
                      created: "2026-09-21T09:30:00Z", duration_ms: 1_122_000, source: "Tom Becker\u{2019}s OneDrive")
    }

    public func transcript(_ target: MeetingFileTarget) throws -> Data? {
        Data(Self.transcriptJSON.utf8)
    }

    public func notesText(_ notes: MeetingNotesRef) throws -> String? {
        """
        Agenda
        • Build status
        • Packaging plan
        • Release checklist

        Notes
        • Tom Becker: nightly build is green on all three targets.
        • Megan Harper: installer artwork lands Wednesday.
        • Sam Ray owns the release checklist review.

        Action items
        • Ava Lindqvist to book the release review for Friday.
        • Tom Becker to share the packaging script.
        """
    }

    public func intelligentRecap(threadID: String, fileURL: String?) throws -> MeetingAIRecap? {
        guard Self.isStandup(threadID) else {
            return MeetingAIRecap(notes: [], followUps: [],
                                  unavailableReason: "Intelligent recap needs the meeting to be recorded.")
        }
        return MeetingAIRecap(
            notes: [
                "The nightly build is green on all targets; packaging starts this week.",
                "Installer artwork is due Wednesday; the release review moves to Friday.",
            ],
            followUps: [
                "Ava Lindqvist will book the release review for Friday.",
                "Tom Becker will share the packaging script with the team.",
            ])
    }

    /// Teams transcript JSON (the live media-transcript format).
    static let turns: [(String, String, String, String)] = [
        ("Ava Lindqvist", "00:00:00.0000000", "00:00:06.5000000", "Morning everyone, let\u{2019}s start with the build."),
        ("Tom Becker", "00:00:06.5000000", "00:00:19.0000000", "Nightly is green on all three targets. The flaky network test is fixed."),
        ("Megan Harper", "00:00:19.0000000", "00:00:31.2000000", "Great. Installer artwork lands Wednesday, I\u{2019}ll drop it in the team files."),
        ("Sam Ray", "00:00:31.2000000", "00:00:44.0000000", "I can take the release checklist review this week."),
        ("Ava Lindqvist", "00:00:44.0000000", "00:01:02.8000000", "Thanks Sam. Let\u{2019}s move the release review to Friday so the artwork is in."),
        ("Tom Becker", "00:01:02.8000000", "00:01:20.0000000", "Works for me. I\u{2019}ll share the packaging script after this call."),
        ("Megan Harper", "00:01:20.0000000", "00:01:33.5000000", "Can we keep the old icon as a fallback until sign-off?"),
        ("Ava Lindqvist", "00:01:33.5000000", "00:01:45.0000000", "Yes, keep both until Friday. Anything else? Okay, thanks all."),
    ]

    public static var transcriptJSON: String {
        let entries = turns.enumerated().map { i, t in
            """
            {"id":"\(i)","speakerDisplayName":"\(t.0)","startOffset":"\(t.1)","endOffset":"\(t.2)","text":"\(t.3)","confidence":0.9}
            """
        }
        return "{\"$schema\":\"http://stream.office.com/schemas/transcript.json\",\"entries\":[\(entries.joined(separator: ","))],\"events\":[]}"
    }
}
