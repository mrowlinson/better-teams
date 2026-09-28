// TranscriptsParser.swift — om-transcripts-build lane: pure VTT parser.
//
// Pure Swift (FFI-shrink direction: pure logic lives in Swift). No
// OstMacCore dependencies: this file also compiles standalone (the
// lane's live-verify driver feeds it downloaded VTT bytes directly).

import Foundation

/// One speaker turn parsed from a VTT cue block.
public struct TranscriptCue: Sendable, Equatable, Identifiable {
    public let id: Int
    public let speaker: String?
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(id: Int, speaker: String?, startMs: Int, endMs: Int, text: String) {
        self.id = id
        self.speaker = speaker
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }

    /// 3723000 -> "1:02:03", 43000 -> "0:43".
    public var startLabel: String { Self.label(startMs) }

    public static func label(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Parse WebVTT bytes into speaker turns. Never throws: `NOTE`/`STYLE`/
/// `REGION` blocks, the `WEBVTT` header, and malformed cues are
/// skipped. Cue identifiers are ignored; cue settings after the end
/// timestamp are ignored; `<v Name>` yields the speaker and remaining
/// cue tags are stripped; multi-line payloads join with spaces.
public func parseVTT(_ vtt: String) -> [TranscriptCue] {
    // Normalize endings, then split into blank-line-separated blocks.
    let normalized = vtt
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let blocks = normalized.components(separatedBy: "\n\n")
    var cues: [TranscriptCue] = []
    for block in blocks {
        let lines = block.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard let cue = parseBlock(lines, id: cues.count) else { continue }
        cues.append(cue)
    }
    return cues
}

private func parseBlock(_ lines: [String], id: Int) -> TranscriptCue? {
    guard !lines.isEmpty else { return nil }
    let first = lines[0].trimmingCharacters(in: .whitespaces)
    // Header + metadata blocks never hold cues.
    if first == "WEBVTT" || first.hasPrefix("WEBVTT ") || first.hasPrefix("WEBVTT\t") {
        return nil
    }
    if first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
        return nil
    }
    // Timing line is first or second (identifier line optional).
    var timingIndex: Int?
    for (i, line) in lines.prefix(2).enumerated() {
        if line.contains("-->") {
            timingIndex = i
            break
        }
    }
    guard let t = timingIndex else { return nil }
    let parts = lines[t].components(separatedBy: "-->")
    guard parts.count == 2 else { return nil }
    guard let start = parseTimestamp(parts[0]),
        let end = parseTimestamp(settingsHead(parts[1]))
    else { return nil }
    let payload = Array(lines.dropFirst(t + 1))
    guard !payload.isEmpty else { return nil }
    let (speaker, text) = speakerAndText(payload)
    guard !text.isEmpty else { return nil }
    return TranscriptCue(
        id: id, speaker: speaker, startMs: start, endMs: end, text: text)
}

/// Head token of the timing line's right side (cue settings follow).
private func settingsHead(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespaces)
        .components(separatedBy: .whitespaces)
        .first ?? ""
}

/// `mm:ss.mmm` or `hh:mm:ss.mmm` (also `mm:ss,mmm`) -> ms. Nil unless
/// the full shape matches (minutes/seconds 2-digit, millis 3-digit).
private func parseTimestamp(_ raw: String) -> Int? {
    let s = raw.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: ",", with: ".")
    let groups = s.components(separatedBy: ":")
    guard groups.count == 2 || groups.count == 3 else { return nil }
    var h = 0
    var mIdx = 0
    if groups.count == 3 {
        guard let hh = Int(groups[0]) else { return nil }
        h = hh
        mIdx = 1
    }
    guard groups[mIdx].count == 2, let m = Int(groups[mIdx]), m < 60 else { return nil }
    let secParts = groups[mIdx + 1].components(separatedBy: ".")
    guard secParts.count == 2,
        secParts[0].count == 2, let sec = Int(secParts[0]), sec < 60,
        secParts[1].count == 3, let ms = Int(secParts[1])
    else { return nil }
    return ((h * 3600) + (m * 60) + sec) * 1000 + ms
}

/// Leading `<v Speaker>` yields the speaker; all cue tags strip; lines
/// join with spaces.
private func speakerAndText(_ lines: [String]) -> (String?, String) {
    var speaker: String?
    var first = lines[0].trimmingCharacters(in: .whitespaces)
    if first.hasPrefix("<v ") || first.hasPrefix("<v\t") {
        let rest = String(first.dropFirst(3))
        if let close = rest.firstIndex(of: ">") {
            let name = rest[..<close].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { speaker = name }
            first = String(rest[rest.index(after: close)...])
        }
    }
    var joined = ([first] + Array(lines.dropFirst())).joined(separator: " ")
    joined = stripTags(joined)
    // Collapse runs of whitespace the tag strip may leave behind.
    let text = joined.components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }.joined(separator: " ")
    return (speaker, text)
}

/// Remove `<...>` cue tags (`<v>`, `<b>`, `<i>`, `<c>`, timestamps).
private func stripTags(_ s: String) -> String {
    var out = ""
    var skipping = false
    for ch in s {
        if ch == "<" {
            skipping = true
            continue
        }
        if ch == ">" {
            skipping = false
            continue
        }
        if !skipping { out.append(ch) }
    }
    return out
}
