// RecordingsModels.swift — om-recordings lane: meeting-recording rows.
//
// One searchable list of every meeting recording (OneDrive +
// SharePoint `Recordings` folders) with in-app playback. Rows reuse
// the Shared tab projection plus `duration_ms` (the driveItem `video`
// facet) and `source` (OneDrive vs `Team > #channel`).
import Foundation

/// One meeting recording from core `ostmac_recordings_list/search`.
/// `download_url` is a pre-authenticated short-lived URL: Swift
/// streams playback directly; when expired it falls back to the files
/// download (`drive_id` + `id`).
public struct RecordingItem: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let size: UInt64
    public let mime: String?
    public let web_url: String?
    public let download_url: String?
    public let drive_id: String?
    public let created: String?
    public let modified: String?
    public let duration_ms: UInt64?
    public let source: String?

    public init(
        id: String, name: String, size: UInt64 = 0,
        mime: String? = nil, web_url: String? = nil,
        download_url: String? = nil, drive_id: String? = nil,
        created: String? = nil, modified: String? = nil,
        duration_ms: UInt64? = nil, source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
        self.web_url = web_url
        self.modified = modified
        self.download_url = download_url
        self.drive_id = drive_id
        self.created = created
        self.duration_ms = duration_ms
        self.source = source
    }

    /// "48211" -> "48 KB" (Shared tab units).
    public var sizeLabel: String { SharedFile.sizeLabel(size) }

    /// Recordings are always video.
    public var iconName: String { "film" }

    /// 3723000 -> "1:02:03", 43000 -> "0:43". Nil without a facet.
    public var durationLabel: String? {
        guard let ms = duration_ms else { return nil }
        return Self.durationLabel(ms)
    }

    public static func durationLabel(_ ms: UInt64) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// "2026-09-24T10:00:00Z" -> "Sep 24, 2026". Raw string fallback.
    public var displayDate: String? {
        guard let raw = modified ?? created else { return nil }
        return Self.displayDate(raw)
    }

    public static func displayDate(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: date)
    }

    /// Row subtitle: date + length + size ("Sep 24, 2026 · 1:02:03").
    public var detailLine: String {
        [displayDate, durationLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

/// List window from core `ostmac_recordings_list`:
/// `{"ok","recordings":[...]}` (newest first).
public struct RecordingsResponse: Decodable, Sendable {
    public let ok: Bool
    public let recordings: [RecordingItem]

    public init(ok: Bool, recordings: [RecordingItem]) {
        self.ok = ok
        self.recordings = recordings
    }
}

/// Search window from core `ostmac_recordings_search`:
/// `{"ok","query","recordings":[...]}` (same row shape).
public struct RecordingsSearchResponse: Decodable, Sendable {
    public let ok: Bool
    public let query: String?
    public let recordings: [RecordingItem]

    public init(ok: Bool, query: String? = nil, recordings: [RecordingItem]) {
        self.ok = ok
        self.query = query
        self.recordings = recordings
    }
}
