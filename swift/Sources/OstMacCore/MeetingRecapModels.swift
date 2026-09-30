// MeetingRecapModels.swift — RECAP2: one meeting's recap, read the way
// Teams reads it. Pure values + parsers (unit-tested with fakes).
//
// Sources (mined from the Teams web client, tmp/recap2/mine.md):
// - the meeting-artifacts service's resources for the meeting
//   (Recording, TranscriptV2, Notes), Teams' own recap index;
// - the meeting chat's recording and transcript messages
//   (`RichText/Media_CallRecording`: the ORGANIZER's file uri + driveId
//   + driveItemId; `RichText/Media_CallTranscript`), Teams' fallback;
// - the recording's transcript, read from the file's media transcripts
//   (Teams' own transcript JSON, speaker-attributed and timestamped);
// - the meeting notes (the Loop page the artifacts service names);
// - the intelligent recap (Substrate MeetingCatchUp), when licensed.
//
// FAIL≠ABSENCE: a part is `absent` only after a read SUCCEEDED and found
// nothing. Any failed read (401/403 included) is `failed`, with retry.
import Foundation

/// One recap part's state in the viewer.
public enum RecapPart<Value: Equatable & Sendable>: Equatable, Sendable {
    /// Read in flight (the viewer shows its indicator only after 0.3 s).
    case loading
    case loaded(Value)
    /// The read succeeded and the meeting has none (reason shown as is).
    case absent(String)
    /// The read failed (user-facing message); the viewer offers retry.
    case failed(String)

    public var value: Value? {
        if case .loaded(let v) = self { return v }
        return nil
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// A recording the meeting chat announced (organizer's OneDrive/SharePoint).
public struct MeetingRecordingRef: Codable, Sendable, Equatable, Identifiable {
    /// Chat message id (stable per recording).
    public let id: String
    public let title: String?
    /// The stored file's address (`…/Recordings/<name>.mp4`).
    public let file_url: String?
    public let duration_ms: UInt64?
    public let created: String?
    /// `Success`, `Failure`, `Started`, … as the chat message says.
    public let status: String?
    public let drive_id: String?
    public let item_id: String?

    public init(id: String, title: String?, file_url: String?, duration_ms: UInt64? = nil,
                created: String? = nil, status: String? = nil, drive_id: String? = nil, item_id: String? = nil) {
        self.id = id
        self.title = title
        self.file_url = file_url
        self.duration_ms = duration_ms
        self.created = created
        self.status = status
        self.drive_id = drive_id
        self.item_id = item_id
    }

    public var target: MeetingFileTarget {
        MeetingFileTarget(file_url: file_url, drive_id: drive_id, item_id: item_id)
    }

    /// A recording that finished and has a stored file.
    public var isPlayable: Bool {
        guard file_url?.isEmpty == false || (drive_id?.isEmpty == false && item_id?.isEmpty == false) else { return false }
        guard let s = status?.lowercased(), !s.isEmpty else { return true }
        return s == "success"
    }
}

/// A transcript the meeting chat announced.
public struct MeetingTranscriptRef: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Recording file the transcript belongs to (read via its media
    /// transcripts), when the chat links one.
    public let file_url: String?
    public let created: String?
    /// Full transcript content address (artifacts service TranscriptV2).
    public let location: String?
    public let drive_id: String?
    public let item_id: String?

    public init(id: String, file_url: String?, created: String? = nil, location: String? = nil,
                drive_id: String? = nil, item_id: String? = nil) {
        self.id = id
        self.file_url = file_url
        self.created = created
        self.location = location
        self.drive_id = drive_id
        self.item_id = item_id
    }
}

/// A file the core reads (address and/or drive + item ids, or a full
/// transcript content address).
public struct MeetingFileTarget: Codable, Sendable, Equatable {
    public let file_url: String?
    public let drive_id: String?
    public let item_id: String?
    public let location: String?

    public init(file_url: String? = nil, drive_id: String? = nil, item_id: String? = nil, location: String? = nil) {
        self.file_url = file_url
        self.drive_id = drive_id
        self.item_id = item_id
        self.location = location
    }

    public var json: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}"
    }
}

/// The meeting notes (a Loop page) named by the meeting-artifacts
/// service (with its drive + item ids) or linked from the meeting chat.
public struct MeetingNotesRef: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public let title: String?
    public let url: String
    public let drive_id: String?
    public let item_id: String?

    public init(title: String?, url: String, drive_id: String? = nil, item_id: String? = nil) {
        self.title = title
        self.url = url
        self.drive_id = drive_id
        self.item_id = item_id
    }

    /// The core's notes read argument (`{url,drive_id?,item_id?}`).
    public var json: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// What the meeting chat says about one meeting's recap.
public struct MeetingRecapSources: Codable, Sendable, Equatable {
    public let recordings: [MeetingRecordingRef]
    public let transcripts: [MeetingTranscriptRef]
    public let notes: [MeetingNotesRef]
    /// Chat pages read (a bounded history walk).
    public let pages: Int?
    /// True when the walk reached the start of the chat.
    public let complete: Bool?
    /// The meeting-artifacts read failed (message): what it would have
    /// named (notes above all) is unknown, never "none".
    public let artifactsError: String?

    public init(recordings: [MeetingRecordingRef], transcripts: [MeetingTranscriptRef],
                notes: [MeetingNotesRef], pages: Int? = nil, complete: Bool? = nil,
                artifactsError: String? = nil) {
        self.recordings = recordings
        self.transcripts = transcripts
        self.notes = notes
        self.pages = pages
        self.complete = complete
        self.artifactsError = artifactsError
    }

    public var isEmpty: Bool { recordings.isEmpty && transcripts.isEmpty && notes.isEmpty }

    public static let none = MeetingRecapSources(recordings: [], transcripts: [], notes: [])

    /// The newest finished recording (the one the viewer plays).
    public var playable: MeetingRecordingRef? { recordings.last { $0.isPlayable } }

    /// Where the transcript is read from: the artifacts service's
    /// transcript address, a transcript message's file, else the playable
    /// recording (Teams keeps the transcript with it).
    public var transcriptTarget: MeetingFileTarget? {
        if let t = transcripts.last(where: { $0.location?.isEmpty == false }) {
            return MeetingFileTarget(file_url: t.file_url, drive_id: t.drive_id, item_id: t.item_id, location: t.location)
        }
        if let t = transcripts.last(where: { $0.file_url?.isEmpty == false }) {
            return MeetingFileTarget(file_url: t.file_url, drive_id: t.drive_id, item_id: t.item_id)
        }
        return playable?.target
    }
}

/// Meeting notes content, read-only.
public struct MeetingNotesContent: Sendable, Equatable {
    public let title: String
    /// The notes' in-window address (Loop / Office for the web).
    public let webURL: URL
    /// Plain text preview, when the store could read one.
    public let text: String?

    public init(title: String, webURL: URL, text: String? = nil) {
        self.title = title
        self.webURL = webURL
        self.text = text
    }
}

/// Intelligent recap (AI notes / follow-ups), when licensed.
public struct MeetingAIRecap: Sendable, Equatable {
    public let notes: [String]
    public let followUps: [String]
    /// Why there is none (license, no transcript, …), as Teams reports it.
    public let unavailableReason: String?

    public init(notes: [String], followUps: [String], unavailableReason: String? = nil) {
        self.notes = notes
        self.followUps = followUps
        self.unavailableReason = unavailableReason
    }

    public var isEmpty: Bool { notes.isEmpty && followUps.isEmpty }
}

// MARK: - Chat message parsing (pure)

/// Reads recap references out of meeting-chat messages. Pure: the core
/// hands raw `{id, messagetype, content, composetime}` rows here.
public enum MeetingRecapParse {
    public struct RawMessage: Codable, Sendable, Equatable {
        public let id: String
        public let messagetype: String
        public let content: String
        public let composetime: String?

        public init(id: String, messagetype: String, content: String, composetime: String? = nil) {
            self.id = id
            self.messagetype = messagetype
            self.content = content
            self.composetime = composetime
        }
    }

    /// Recap sources from a chat's messages (any order); oldest first.
    public static func sources(from messages: [RawMessage], pages: Int? = nil,
                               complete: Bool? = nil) -> MeetingRecapSources {
        var recs: [String: MeetingRecordingRef] = [:]
        var trs: [MeetingTranscriptRef] = []
        var notes: [MeetingNotesRef] = []
        let ordered = messages.sorted { ($0.composetime ?? "") < ($1.composetime ?? "") }
        for m in ordered {
            let type = m.messagetype.lowercased()
            if type.contains("media_callrecording") {
                guard let r = recording(m) else { continue }
                // Teams re-posts the recording message as its status
                // moves (Started → Success): the file address keys it.
                let key = r.file_url.map(normalizedFileKey) ?? r.id
                recs[key] = r
            } else if type.contains("media_calltranscript") {
                if let t = transcript(m), !trs.contains(where: { $0.id == t.id }) { trs.append(t) }
            }
            for n in notesLinks(in: m.content) where !notes.contains(where: { $0.url == n.url }) {
                notes.append(n)
            }
        }
        let recordings = recs.values.sorted { ($0.created ?? "") < ($1.created ?? "") }
        return MeetingRecapSources(recordings: recordings, transcripts: trs, notes: notes,
                                   pages: pages, complete: complete)
    }

    /// One meeting-artifacts resource (core JSON, type lowercased).
    public struct ArtifactResource: Codable, Sendable, Equatable {
        public let type: String
        public let location: String?
        public let drive_id: String?
        public let drive_item_id: String?
        public let web_url: String?
        public let file_title: String?
        public let start_time: String?

        public init(type: String, location: String?, drive_id: String? = nil, drive_item_id: String? = nil,
                    web_url: String? = nil, file_title: String? = nil, start_time: String? = nil) {
            self.type = type
            self.location = location
            self.drive_id = drive_id
            self.drive_item_id = drive_item_id
            self.web_url = web_url
            self.file_title = file_title
            self.start_time = start_time
        }
    }

    /// The chat's sources plus the artifacts service's resources (Teams'
    /// primary index), deduplicated by file. `artifactsError` is the
    /// failed artifacts read, if any.
    public static func merge(_ chat: MeetingRecapSources, artifacts: [ArtifactResource],
                             artifactsError: String?) -> MeetingRecapSources {
        var recordings = chat.recordings
        var transcripts = chat.transcripts
        var notes = chat.notes
        for (i, r) in artifacts.enumerated() {
            switch r.type {
            case "recording":
                let file = r.web_url ?? r.location
                let key = file.map(normalizedFileKey)
                let dup = recordings.contains { ($0.item_id != nil && $0.item_id == r.drive_item_id)
                    || (key != nil && $0.file_url.map(normalizedFileKey) == key) }
                if !dup {
                    recordings.append(MeetingRecordingRef(id: "artifact-\(i)", title: r.file_title, file_url: file,
                                                          created: r.start_time, status: "Success",
                                                          drive_id: r.drive_id, item_id: r.drive_item_id))
                }
            case "transcriptv2", "transcript":
                transcripts.append(MeetingTranscriptRef(id: "artifact-\(i)", file_url: r.web_url, created: r.start_time,
                                                        location: r.location, drive_id: r.drive_id,
                                                        item_id: r.drive_item_id))
            case "notes":
                if let u = r.location ?? r.web_url {
                    // The artifacts service's reference (with ids) wins
                    // over the same file linked in the chat.
                    notes.removeAll { $0.url == u }
                    notes.append(MeetingNotesRef(title: r.file_title, url: u, drive_id: r.drive_id,
                                                 item_id: r.drive_item_id))
                }
            default: break
            }
        }
        return MeetingRecapSources(recordings: recordings, transcripts: transcripts, notes: notes,
                                   pages: chat.pages, complete: chat.complete, artifactsError: artifactsError)
    }

    /// `<URIObject type="Video.2/CallRecording.1" …>` → recording ref.
    static func recording(_ m: RawMessage) -> MeetingRecordingRef? {
        let c = m.content
        var file: String?
        var drive: String?
        var itemID: String?
        for item in elements(named: "item", in: c) {
            let type = attribute("type", in: item)?.lowercased() ?? ""
            if type.contains("onedriveforbusinessvideo") || type.contains("sharepointvideo")
                || (type.contains("video") && (attribute("uri", in: item)?.contains("sharepoint.com") ?? false)) {
                file = attribute("uri", in: item).map(unescape)
                drive = attribute("driveId", in: item).map(unescape)
                itemID = attribute("driveItemId", in: item).map(unescape)
                break
            }
        }
        if file == nil, let a = firstHref(in: c), a.contains("sharepoint.com") { file = a }
        let status = elements(named: "RecordingStatus", in: c).first.flatMap { attribute("status", in: $0) }
        let rc = elements(named: "RecordingContent", in: c).first
        let dur = rc.flatMap { attribute("duration", in: $0) }.flatMap(durationMillis)
        let created = rc.flatMap { attribute("timestamp", in: $0) } ?? m.composetime
        let title = innerText(of: "Title", in: c) ?? innerText(of: "OriginalName", in: c)
            ?? elements(named: "OriginalName", in: c).first.flatMap { attribute("v", in: $0) }
        guard file != nil || status != nil else { return nil }
        return MeetingRecordingRef(id: m.id, title: title.map(unescape), file_url: file,
                                   duration_ms: dur, created: created, status: status,
                                   drive_id: drive, item_id: itemID)
    }

    /// A RecordingContent `duration` in any shape Teams has been seen to
    /// write: plain seconds ("1834.5"), clock ("0:30:34.5"), or ISO 8601
    /// ("PT30M34.5S"). Nil when unparseable or not positive.
    static func durationMillis(_ raw: String) -> UInt64? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        var seconds: Double?
        if let d = Double(t) {
            seconds = d
        } else if t.uppercased().hasPrefix("P") {
            var total = 0.0, num = ""
            var inTime = false
            for ch in t.uppercased().dropFirst() {
                if ch == "T" { inTime = true; continue }
                if ch.isNumber || ch == "." { num.append(ch); continue }
                guard let n = Double(num) else { return nil }
                num = ""
                switch (ch, inTime) {
                case ("D", false): total += n * 86_400
                case ("H", true): total += n * 3_600
                case ("M", true): total += n * 60
                case ("S", true): total += n
                default: return nil
                }
            }
            seconds = num.isEmpty ? total : nil
        } else if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
            guard parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
            seconds = parts.reduce(0.0) { $0 * 60 + ($1 ?? 0) }
        }
        guard let s = seconds, s > 0, s.isFinite else { return nil }
        return UInt64(s * 1000)
    }

    /// `RichText/Media_CallTranscript` carries JSON; the stored file's
    /// address (when exported) rides in it.
    static func transcript(_ m: RawMessage) -> MeetingTranscriptRef? {
        let raw = unescape(m.content)
        var file: String?
        if let data = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) {
            file = firstSharePointURL(in: obj)
        }
        if file == nil { file = firstSharePointURL(inText: raw) }
        return MeetingTranscriptRef(id: m.id, file_url: file, created: m.composetime)
    }

    /// Loop meeting-notes links in a message (`.loop` / `.fluid` files or
    /// `loop.cloud.microsoft` pages).
    public static func notesLinks(in html: String) -> [MeetingNotesRef] {
        var out: [MeetingNotesRef] = []
        for href in hrefs(in: html) {
            let u = unescape(href)
            guard isNotesURL(u), !out.contains(where: { $0.url == u }) else { continue }
            out.append(MeetingNotesRef(title: nil, url: u))
        }
        return out
    }

    public static func isNotesURL(_ s: String) -> Bool {
        guard let url = URL(string: s), url.scheme?.lowercased() == "https", let host = url.host?.lowercased()
        else { return false }
        let path = url.path.lowercased()
        if path.hasSuffix(".loop") || path.hasSuffix(".fluid") { return host.hasSuffix("sharepoint.com") }
        return host == "loop.cloud.microsoft" || host.hasSuffix(".loop.microsoft.com")
    }

    /// Case-folded path without query (same file across re-posts).
    static func normalizedFileKey(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s.lowercased() }
        c.query = nil
        c.fragment = nil
        return (c.string ?? s).lowercased()
    }

    // MARK: tiny tolerant XML/HTML helpers (no DOM, bounded)

    static func elements(named name: String, in s: String) -> [String] {
        var out: [String] = []
        var rest = s[...]
        while out.count < 64, let r = rest.range(of: "<\(name)", options: .caseInsensitive) {
            let after = rest[r.upperBound...]
            guard let first = after.first, first == " " || first == ">" || first == "/" || first == "\n" else {
                rest = after
                continue
            }
            guard let end = after.firstIndex(of: ">") else { break }
            out.append(String(rest[r.lowerBound...end]))
            rest = rest[rest.index(after: end)...]
        }
        return out
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        for q in ["\"", "'"] {
            if let r = tag.range(of: " \(name)=\(q)", options: .caseInsensitive) {
                let tail = tag[r.upperBound...]
                if let end = tail.firstIndex(of: Character(q)) { return String(tail[..<end]) }
            }
        }
        return nil
    }

    static func innerText(of name: String, in s: String) -> String? {
        guard let open = s.range(of: "<\(name)>", options: .caseInsensitive),
              let close = s.range(of: "</\(name)>", options: .caseInsensitive, range: open.upperBound..<s.endIndex)
        else { return nil }
        let t = s[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func hrefs(in s: String) -> [String] {
        elements(named: "a", in: s).compactMap { attribute("href", in: $0) }
    }

    static func firstHref(in s: String) -> String? { hrefs(in: s).first.map(unescape) }

    static func firstSharePointURL(in obj: Any) -> String? {
        if let s = obj as? String { return firstSharePointURL(inText: s) }
        if let d = obj as? [String: Any] {
            for k in d.keys.sorted() { if let u = firstSharePointURL(in: d[k] as Any) { return u } }
        }
        if let a = obj as? [Any] {
            for v in a { if let u = firstSharePointURL(in: v) { return u } }
        }
        return nil
    }

    static func firstSharePointURL(inText s: String) -> String? {
        guard let r = s.range(of: #"https://[A-Za-z0-9.-]+\.sharepoint\.com/[^\s"'<>]+"#, options: .regularExpression)
        else { return nil }
        return String(s[r])
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Transcript JSON (Teams' own transcript format)

/// Teams' transcript JSON (`entries[]` with `speakerDisplayName`, `text`,
/// `startOffset`/`endOffset` as `HH:MM:SS.fffffff`) → speaker turns.
/// Consecutive entries by the same speaker stay separate lines (Teams
/// shows each), empty text is skipped.
public enum TeamsTranscriptJSON {
    public static func cues(from data: Data) -> [TranscriptCue]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]] else { return nil }
        var out: [TranscriptCue] = []
        for e in entries {
            let text = (e["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let start = (e["startOffset"] as? String).flatMap(offsetMs) else { continue }
            let end = (e["endOffset"] as? String).flatMap(offsetMs) ?? start
            let speaker = (e["speakerDisplayName"] as? String)?.trimmingCharacters(in: .whitespaces)
            out.append(TranscriptCue(id: out.count, speaker: speaker?.isEmpty == false ? speaker : nil,
                                     startMs: start, endMs: max(end, start), text: text))
        }
        // Entries none of which read (renamed fields): an unknown shape,
        // not an empty transcript.
        if out.isEmpty, entries.contains(where: { ($0["text"] as? String)?.isEmpty == false }) { return nil }
        return out
    }

    /// `HH:MM:SS.fffffff` (or `MM:SS.f`) → ms.
    public static func offsetMs(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var secs = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            secs = secs * 60 + v
        }
        return Int((secs * 1000).rounded())
    }

    /// Transcript bytes of either format → turns (JSON first, then VTT).
    public static func parse(_ data: Data) -> [TranscriptCue] {
        if let json = cues(from: data) { return json }
        return parseVTT(String(decoding: data, as: UTF8.self))
    }

    /// As `parse`, but bytes that are neither Teams transcript JSON nor
    /// WebVTT throw (a read that succeeded is never "no transcript"
    /// because its format was unknown).
    public static func parseStrict(_ data: Data) throws -> [TranscriptCue] {
        if let json = cues(from: data) { return json }
        let text = String(decoding: data, as: UTF8.self)
        let turns = parseVTT(text)
        let head = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
        if turns.isEmpty && !head.hasPrefix("WEBVTT") { throw TranscriptFormatError() }
        return turns
    }
}

/// Transcript bytes in no known format.
public struct TranscriptFormatError: Error, Equatable {
    public init() {}
}

// MARK: - Meeting notes HTML (pure)

/// The Loop page service's HTML snapshot → read-only text: blocks and
/// line breaks become lines, list items get a bullet, table cells a tab;
/// scripts, styles and tags go; entities decode; blank runs collapse.
public enum LoopNotesText {
    public static func plain(fromHTML html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>"#, with: "",
                                          options: .regularExpression)
        s = s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        let rules: [(String, String)] = [
            (#"<li\b[^>]*>"#, "\n\u{2022} "),
            (#"<br\s*/?>"#, "\n"),
            (#"</?(p|div|h[1-6]|ul|ol|tr|table|blockquote|pre|section|article|header|footer)\b[^>]*>"#, "\n"),
            (#"</t[dh]>"#, "\t"),
            (#"<[^>]+>"#, ""),
        ]
        for (pattern, with) in rules {
            s = s.replacingOccurrences(of: pattern, with: with, options: [.regularExpression, .caseInsensitive])
        }
        s = decodeEntities(s)
        let lines = s.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: "[ \u{00A0}]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line == "\u{2022}" ? "" : line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = s[...]
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[rest.index(after: amp)...]
            if let semi = tail.prefix(10).firstIndex(of: ";") {
                let name = String(tail[..<semi])
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[name.lowercased()]
                }
                if let decoded {
                    out += decoded
                    rest = tail[tail.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = tail
        }
        out += rest
        return out
    }
}

// MARK: - Transcript search (pure)

public enum TranscriptSearch {
    /// Turns whose text or speaker contains every word of the query.
    public static func matches(_ cues: [TranscriptCue], query: String) -> [Int] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return cues.filter { c in
            let hay = ((c.speaker ?? "") + " " + c.text).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }.map(\.id)
    }
}
