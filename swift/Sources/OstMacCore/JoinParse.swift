// JoinParse.swift — R12 ffi-move-now B1: ostmac_meeting_join_parse moved
// from Rust FFI to Swift. Exact port of ost::api::parse_join_url
// (api/calendar.rs) + meeting_join_parse_json envelope.
import Foundation

/// Join-string classifier. Pure; never dials. Matches the Rust port
/// case-for-case, including case-sensitive scheme/marker checks on the
/// trimmed (not decoded) string.
enum JoinParse {
    struct Target {
        var kind: String
        var threadID: String?
        var meetingID: String?
        var url: String
    }

    static let trimSet = CharacterSet(charactersIn: "<>\"'")

    static func parse(raw: String) -> Target {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: trimSet)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Target(kind: "unknown", url: "")
        }
        if looksLikeThreadID(trimmed) {
            return Target(kind: "thread", threadID: trimmed, url: trimmed)
        }
        let decoded = pctDecode(trimmed)
        let lower = asciiLower(decoded)
        if lower.contains("teams.microsoft.com/l/meetup-join")
            || lower.contains("teams.microsoft.com/meet")
        {
            if let tid = extractThreadID(decoded) {
                return Target(kind: "thread", threadID: tid, url: trimmed)
            }
            if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
                return Target(kind: "url", url: trimmed)
            }
        }
        if lower.contains("teams.live.com/meet/") {
            if let mid = extractLiveMeetID(trimmed) {
                return Target(kind: "meeting-id", meetingID: mid, url: trimmed)
            }
        }
        if trimmed.hasPrefix("https://") {
            return Target(kind: "url", url: trimmed)
        }
        return Target(kind: "unknown", url: trimmed)
    }

    /// Percent-decode %XX runs (best-effort; malformed runs pass through).
    static func pctDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25, i + 2 < bytes.count,
                isHex(bytes[i + 1]), isHex(bytes[i + 2])
            {
                out.append(hexVal(bytes[i + 1]) * 16 + hexVal(bytes[i + 2]))
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func isHex(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    static func hexVal(_ b: UInt8) -> UInt8 {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x41 && b <= 0x46 { return b - 0x41 + 10 }
        return b - 0x61 + 10
    }

    static func asciiLower(_ s: String) -> String {
        let mapped = s.unicodeScalars.map { scalar -> UnicodeScalar in
            let v = scalar.value
            if v >= 0x41 && v <= 0x5A { return UnicodeScalar(v + 32)! }
            return scalar
        }
        return String(String.UnicodeScalarView(mapped))
    }

    /// Native chat-service thread ids (`19:…`, `48:…`, `8:…`), no whitespace.
    static func looksLikeThreadID(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("19:") || t.hasPrefix("48:") || t.hasPrefix("8:") else {
            return false
        }
        return !t.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }

    /// First `19:…@thread…` span out of a (decoded) URL. Stops at `/`, `?`,
    /// `&`, `#`, quotes, or whitespace; trims trailing `.,)]`.
    static func extractThreadID(_ decoded: String) -> String? {
        guard let range = decoded.range(of: "19:") else { return nil }
        let tail = String(decoded[range.lowerBound...])
        let stop = CharacterSet(charactersIn: "/?&#\"' \t\n")
        let end: String.Index
        if let stopRange = tail.rangeOfCharacter(from: stop) {
            end = stopRange.lowerBound
        } else {
            end = tail.endIndex
        }
        // NOTE: Rust trim_end_matches strips trailing runs only; the
        // CharacterSet trims both ends, but ids start with "19:" so no
        // leading char is ever in the strip set.
        let id = String(tail[tail.startIndex ..< end])
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,)]"))
        guard id.contains("@") else { return nil }
        return id
    }

    /// `teams.live.com/meet/<id>` meeting id out of a URL (case-sensitive).
    static func extractLiveMeetID(_ url: String) -> String? {
        let marker = "teams.live.com/meet/"
        guard let range = url.range(of: marker) else { return nil }
        let tail = String(url[range.upperBound...])
        let stop = CharacterSet(charactersIn: "/?&#\"' \t\n")
        let end: String.Index
        if let stopRange = tail.rangeOfCharacter(from: stop) {
            end = stopRange.lowerBound
        } else {
            end = tail.endIndex
        }
        let id = String(tail[tail.startIndex ..< end]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return id.isEmpty ? nil : id
    }
}

extension CoreLocal {
    static func meetingJoinParse(raw: String) throws -> JoinParseResponse {
        let t = JoinParse.parse(raw: raw)
        var target: [String: Any] = ["kind": t.kind, "url": t.url]
        target["thread_id"] = t.threadID ?? NSNull()
        target["meeting_id"] = t.meetingID ?? NSNull()
        let data = try statusJSONData(["ok": true, "target": target])
        return try decodeOrThrow(JoinParseResponse.self, from: data)
    }
}
