// RecordingsDemo.swift — om-recordings lane: offline demo rows + clip.
//
// Demo people are the same
// four the rest of `--demo` uses. The demo clip is a programmatic
// mp4 (no binary blob, like DemoMedia): the sunset scene as H.264,
// rendered once into the temp dir and cached.
import Foundation

public enum RecordingsDemo {
    public static func response() -> RecordingsResponse {
        RecordingsResponse(ok: true, recordings: [
            RecordingItem(
                id: "demo-rec-1", name: "Weekly Sync with Ava Lindqvist.mp4",
                size: 48_211_300, mime: "video/mp4",
                web_url: "https://example.com/rec1", drive_id: "demo-drive",
                created: "2026-09-24T09:00:00Z",
                modified: "2026-09-24T10:00:00Z",
                duration_ms: 3_723_000, source: "OneDrive"),
            RecordingItem(
                id: "demo-rec-2", name: "Q3 Review with Tom Becker.mp4",
                size: 128_440_100, mime: "video/mp4",
                web_url: "https://example.com/rec2", drive_id: "demo-drive",
                created: "2026-09-22T14:00:00Z",
                modified: "2026-09-22T15:30:00Z",
                duration_ms: 5_400_000, source: "Engineering > #general"),
            RecordingItem(
                id: "demo-rec-3", name: "Design Crit with Megan Harper.mp4",
                size: 86_020_400, mime: "video/mp4",
                web_url: "https://example.com/rec3", drive_id: "demo-drive",
                created: "2026-09-18T11:00:00Z",
                modified: "2026-09-18T11:45:00Z",
                duration_ms: 2_700_000, source: "Design > #crit"),
            RecordingItem(
                id: "demo-rec-4", name: "Sprint Retro with Sam Ray.mp4",
                size: 62_118_900, mime: "video/mp4",
                web_url: "https://example.com/rec4", drive_id: "demo-drive",
                created: "2026-09-15T16:00:00Z",
                modified: "2026-09-15T16:30:00Z",
                duration_ms: 1_800_000, source: "OneDrive"),
            // The demo meeting chat's recap (chat Recap tab).
            RecordingItem(
                id: "demo-rec-5", name: "Platform Standup-20260912_093000-Meeting Recording.mp4",
                size: 31_402_600, mime: "video/mp4",
                web_url: "https://example.com/rec5", drive_id: "demo-drive",
                created: "2026-09-12T09:30:00Z",
                modified: "2026-09-12T09:50:00Z",
                duration_ms: 1_200_000, source: "OneDrive"),
        ])
    }

    /// Offline search: name + source substring match (case-insensitive).
    public static func searchResponse(for query: String) -> RecordingsSearchResponse {
        let q = query.lowercased()
        let hits = response().recordings.filter {
            $0.name.lowercased().contains(q)
                || ($0.source?.lowercased().contains(q) ?? false)
        }
        return RecordingsSearchResponse(ok: true, query: query, recordings: hits)
    }
}
