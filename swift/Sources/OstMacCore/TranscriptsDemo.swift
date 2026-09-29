// TranscriptsDemo.swift — om-transcripts-build lane: offline demo rows + VTT.
//
// Demo people are the same
// four the rest of `--demo` uses. The synthetic VTT doubles as the
// live-verify upload body (same bytes up, down, and through the unit
// parser matrix), so its turns are pinned by tests.
import Foundation

public enum TranscriptsDemo {
    public static func response() -> TranscriptsResponse {
        TranscriptsResponse(ok: true, transcripts: [
            TranscriptItem(
                id: "demo-tr-1", name: "Weekly Sync with Ava Lindqvist.vtt",
                size: 4_211, mime: "text/vtt",
                web_url: "https://example.com/tr1", drive_id: "demo-drive",
                created: "2026-09-24T09:00:00Z",
                modified: "2026-09-24T10:00:00Z",
                source: "OneDrive"),
            TranscriptItem(
                id: "demo-tr-2", name: "Q3 Review with Tom Becker.vtt",
                size: 12_844, mime: "text/vtt",
                web_url: "https://example.com/tr2", drive_id: "demo-drive",
                created: "2026-09-22T14:00:00Z",
                modified: "2026-09-22T15:30:00Z",
                source: "Engineering > #general"),
            TranscriptItem(
                id: "demo-tr-3", name: "Design Crit with Megan Harper.vtt",
                size: 8_602, mime: "text/vtt",
                web_url: "https://example.com/tr3", drive_id: "demo-drive",
                created: "2026-09-18T11:00:00Z",
                modified: "2026-09-18T11:45:00Z",
                source: "Design > #crit"),
            TranscriptItem(
                id: "demo-tr-4", name: "Sprint Retro with Sam Ray.vtt",
                size: 6_118, mime: "text/vtt",
                web_url: "https://example.com/tr4", drive_id: "demo-drive",
                created: "2026-09-15T16:00:00Z",
                modified: "2026-09-15T16:30:00Z",
                source: "OneDrive"),
            TranscriptItem(
                id: "demo-tr-5", name: "Platform Standup-20260912_093000-Meeting Recording.vtt",
                size: 4_210, mime: "text/vtt",
                web_url: "https://example.com/tr5", drive_id: "demo-drive",
                created: "2026-09-12T09:30:00Z",
                modified: "2026-09-12T09:50:00Z",
                source: "OneDrive"),
        ])
    }

    /// Offline search: name + source substring match (case-insensitive).
    public static func searchResponse(for query: String) -> TranscriptsSearchResponse {
        let q = query.lowercased()
        let hits = response().transcripts.filter {
            $0.name.lowercased().contains(q)
                || ($0.source?.lowercased().contains(q) ?? false)
        }
        return TranscriptsSearchResponse(ok: true, query: query, transcripts: hits)
    }

    /// Synthetic VTT: header + NOTE + STYLE + 4 cues (identifier line,
    /// `<v>` speakers, multi-line payload, hour+ timestamp, cue
    /// settings). The live-verify lane uploads these exact bytes.
    public static let sampleVTT = """
    WEBVTT

    NOTE recorded by Teams

    STYLE
    ::cue { color: white }

    1
    00:00.000 --> 00:43.000
    <v Ava Lindqvist>Welcome to the weekly sync, everyone.

    2
    00:43.500 --> 01:12.000 align:start position:0%
    <v Tom Becker>Thanks Ava. The Q3 numbers
    are up across the board.

    3
    01:02:03.000 --> 01:02:47.250
    <v Megan Harper>Design crit moved to Thursday.

    4
    01:03:00.000 --> 01:03:30.000
    <b>Sam Ray</b> agreed to take notes.
    """

    /// Turns the sample parses to (speaker, start ms, text), pinned by
    /// the parser matrix and the live-verify byte check.
    public static let sampleTurns: [(String?, Int, String)] = [
        ("Ava Lindqvist", 0, "Welcome to the weekly sync, everyone."),
        ("Tom Becker", 43_500, "Thanks Ava. The Q3 numbers are up across the board."),
        ("Megan Harper", 3_723_000, "Design crit moved to Thursday."),
        (nil, 3_780_000, "Sam Ray agreed to take notes."),
    ]
}
