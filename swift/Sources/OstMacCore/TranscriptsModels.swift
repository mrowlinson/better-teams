// TranscriptsModels.swift — om-transcripts-build lane: transcript rows.
//
// One searchable list of every meeting transcript (OneDrive +
// SharePoint `Recordings` folders) with speaker-turn display. Rows
// reuse the recordings projection minus the video facet; `stem` links
// a transcript to its sibling `.mp4` recording row when present.
import Foundation

/// One meeting transcript from core `ostmac_transcripts_list/search`.
/// VTT bytes download via the existing files download (`drive_id` +
/// `id`); cue parsing is `parseVTT` (`TranscriptsParser.swift`).
public struct TranscriptItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let size: UInt64
    public let mime: String?
    public let web_url: String?
    public let drive_id: String?
    public let created: String?
    public let modified: String?
    public let source: String?

    public init(
        id: String, name: String, size: UInt64 = 0,
        mime: String? = nil, web_url: String? = nil,
        drive_id: String? = nil,
        created: String? = nil, modified: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.mime = mime
        self.web_url = web_url
        self.drive_id = drive_id
        self.created = created
        self.modified = modified
        self.source = source
    }

    /// "4211" -> "4 KB" (Shared tab units).
    public var sizeLabel: String { SharedFile.sizeLabel(size) }

    /// Transcripts are always text.
    public var iconName: String { "doc.text" }

    /// Filename minus its extension: the meeting↔transcript link key.
    /// Teams writes `Title-timestamp.mp4` + `Title-timestamp.vtt`, so a
    /// transcript resolves its sibling recording row by stem. Renames
    /// break it (accepted limit, same as the recordings lane).
    public var stem: String { Self.stem(of: name) }

    /// Stem of any filename (also applied to recording names at the
    /// lookup site; Recordings* files are read-only for this lane).
    public static func stem(of name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let stripped = (base as NSString).deletingPathExtension
        return stripped.isEmpty ? base : stripped
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

    /// Row subtitle: date + size ("Sep 24, 2026 · 4 KB").
    public var detailLine: String {
        [displayDate, sizeLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

/// List window from core `ostmac_transcripts_list`:
/// `{"ok","transcripts":[...]}` (newest first).
public struct TranscriptsResponse: Decodable, Sendable {
    public let ok: Bool
    public let transcripts: [TranscriptItem]

    public init(ok: Bool, transcripts: [TranscriptItem]) {
        self.ok = ok
        self.transcripts = transcripts
    }
}

/// Search window from core `ostmac_transcripts_search`:
/// `{"ok","query","transcripts":[...]}` (same row shape).
public struct TranscriptsSearchResponse: Decodable, Sendable {
    public let ok: Bool
    public let query: String?
    public let transcripts: [TranscriptItem]

    public init(ok: Bool, query: String? = nil, transcripts: [TranscriptItem]) {
        self.ok = ok
        self.query = query
        self.transcripts = transcripts
    }
}
