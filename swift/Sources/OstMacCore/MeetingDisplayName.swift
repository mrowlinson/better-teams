// MeetingDisplayName.swift — transcripts-fix lane: legible row titles.
//
// Teams writes `Title-YYYYMMDD[sepHHMMSS].mp4` (+ `.vtt` / transcript
// `.docx` twins), sometimes with server bracket codes. Rows showing
// the raw filename are unreadable, so this pure module turns any
// recording/transcript filename into `Title · Sep 24, 2026`.
//
// Exact rules (`displayName(for:calendarTitle:)`):
//  1. Strip directories + the last extension (any ext, not just media).
//  2. Strip trailing `[...]` segments (server codes) repeatedly.
//  3. Strip a trailing `(...)` segment ONLY when it looks like a
//     server code: 4+ chars of A-Z 0-9 hyphen (so `Q3 (final)` keeps
//     its parens but `Standup (AB12-X9)` loses them).
//  4. Strip a trailing transcript/recording token (`-transcript`,
//     `_transcript`, ` transcript`, same for `transcription` and
//     `recording`, any case), before AND after the date parse, so both
//     `Title-transcript-20260924` and `Title-20260924-transcript` work.
//  5. Parse a trailing `-YYYYMMDD` with an optional time suffix
//     (`_HHMMSS`, `-HHMMSS`, ` HHMMSS`, `THHMMSS`); the time is dropped.
//     The date must be a real calendar day (month 1-12, day valid for
//     month+year incl. leap years); otherwise the digits stay in the title.
//  6. Calendar join: when `calendarTitle` is passed AND confident,
//     the calendar title (owner's canonical casing) replaces the parsed
//     title. Confident = normalized equality, or one normalized side
//     contains the other with the shorter side >= 4 chars. Normalize =
//     lowercase + collapse whitespace. A confident join never drops the
//     `· date` part.
//  7. Output: `Title` alone when no date parsed, else
//     `Title · Sep 24, 2026`. The date part is locale-fixed (en_US
//     `MMM d, yyyy`) so rows + tests are stable; empty titles fall back
//     to the stripped stem, never to "".
//
// Pure + shared: `TranscriptItem.displayName` and the `RecordingItem`
// extension below both delegate here, so recordings and transcripts
// rows render identically. View wiring follows in the ui-rebuild lane.
import Foundation

/// Pure meeting-filename -> legible-title transforms. See the file
/// header for the exact rules.
public enum MeetingDisplayName {
    /// `Weekly Sync-20260924.vtt` -> `Weekly Sync · Sep 24, 2026`.
    public static func displayName(for filename: String, calendarTitle: String? = nil) -> String {
        let stem = stripExtension(filename)
        let (title, date) = parse(stem)
        let resolved = joinCalendar(parsedTitle: title, calendarTitle: calendarTitle)
        guard let date else { return resolved.isEmpty ? stem : resolved }
        let base = resolved.isEmpty ? stem : resolved
        return "\(base) · \(formatDate(date))"
    }

    /// Split a stem into (title, date). Exposed for tests.
    public static func parse(_ stem: String) -> (title: String, date: DateComponents?) {
        var rest = stripBracketCodes(stem)
        rest = stripKindToken(rest)
        var date: DateComponents?
        (rest, date) = splitDate(rest)
        rest = stripKindToken(rest)
        return (rest.trimmingCharacters(in: .whitespaces), date)
    }

    // MARK: - Steps

    /// Last path component minus its last extension. `noext` -> `noext`.
    public static func stripExtension(_ filename: String) -> String {
        let base = (filename as NSString).lastPathComponent
        let stripped = (base as NSString).deletingPathExtension
        return stripped.isEmpty ? base : stripped
    }

    /// Drop trailing `[...]` segments (any content) + trailing `(...)`
    /// segments that match the server-code shape (`^[A-Z0-9-]{4,}$`).
    public static func stripBracketCodes(_ stem: String) -> String {
        var out = stem.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            if out.hasSuffix("]"), let open = out.lastIndex(of: "[") {
                out = String(out[..<open]).trimmingCharacters(in: .whitespaces)
                changed = true
                continue
            }
            if out.hasSuffix(")"), let open = out.lastIndex(of: "(") {
                let inner = String(out[out.index(after: open)..<out.index(before: out.endIndex)])
                if isServerCode(inner) {
                    out = String(out[..<open]).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return out
    }

    /// Server-code shape: 4+ chars, only A-Z 0-9 hyphen.
    public static func isServerCode(_ s: String) -> Bool {
        guard s.count >= 4 else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter && $0.isUppercase || $0.isNumber || $0 == "-") }
    }

    /// Drop one trailing transcript/recording/transcription token with
    /// a `-`, `_`, or space separator (any case).
    public static func stripKindToken(_ s: String) -> String {
        let lower = s.lowercased()
        for token in ["transcription", "transcript", "recording"] {
            for sep in ["-\(token)", "_\(token)", " \(token)"] {
                if lower.hasSuffix(sep) {
                    return String(s.dropLast(sep.count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return s
    }

    /// Split a trailing `-YYYYMMDD` + optional time suffix. Returns the
    /// title remainder + validated date, or the input + nil when no
    /// valid date is present.
    public static func splitDate(_ s: String) -> (String, DateComponents?) {
        // Optional time suffix first: `_HHMMSS` / `-HHMMSS` / ` HHMMSS` / `THHMMSS`.
        var core = s
        if let t = timeSuffixRange(in: core) {
            core = String(core[..<t.lowerBound])
        }
        // Trailing `-YYYYMMDD` (also accepts `_`/space separators).
        guard core.count >= 9 else { return (s, nil) }
        let tail8 = String(core.suffix(8))
        let sepIndex = core.index(core.endIndex, offsetBy: -9)
        let sep = core[sepIndex]
        guard (sep == "-" || sep == "_" || sep == " "), tail8.allSatisfy(\.isNumber) else {
            return (s, nil)
        }
        let y = Int(tail8.prefix(4))!
        let m = Int(tail8.dropFirst(4).prefix(2))!
        let d = Int(tail8.suffix(2))!
        guard isRealDay(year: y, month: m, day: d) else { return (s, nil) }
        let title = String(core[..<sepIndex]).trimmingCharacters(in: .whitespaces)
        return (title, DateComponents(year: y, month: m, day: d))
    }

    /// Range of a trailing time suffix, or nil. Strictly 6 digits.
    static func timeSuffixRange(in s: String) -> Range<String.Index>? {
        guard s.count >= 8 else { return nil }
        let tail6 = String(s.suffix(6))
        guard tail6.allSatisfy(\.isNumber) else { return nil }
        let sepIndex = s.index(s.endIndex, offsetBy: -7)
        let sep = s[sepIndex]
        guard sep == "_" || sep == "-" || sep == " " || sep == "T" else { return nil }
        // The char before the separator must be a digit (else the "time"
        // is really the date's own digits, e.g. bare `-YYYYMMDD`).
        guard sepIndex > s.startIndex else { return nil }
        let before = s[s.index(before: sepIndex)]
        guard before.isNumber else { return nil }
        return sepIndex..<s.endIndex
    }

    /// True for real calendar days (month/day ranges + leap years).
    public static func isRealDay(year: Int, month: Int, day: Int) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return false }
        let round = cal.dateComponents([.year, .month, .day], from: date)
        return round.year == year && round.month == month && round.day == day
    }

    /// Calendar-title join: confident matches take the calendar title.
    public static func joinCalendar(parsedTitle: String, calendarTitle: String?) -> String {
        guard let cal = calendarTitle?.trimmingCharacters(in: .whitespaces),
              !cal.isEmpty, !parsedTitle.isEmpty
        else {
            return parsedTitle
        }
        let a = normalize(parsedTitle), b = normalize(cal)
        if a == b { return cal }
        let short = min(a.count, b.count)
        if short >= 4, a.contains(b) || b.contains(a) { return cal }
        return parsedTitle
    }

    /// Lowercase + collapse runs of whitespace.
    public static func normalize(_ s: String) -> String {
        s.lowercased().split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// `Sep 24, 2026`, locale-fixed.
    public static func formatDate(_ comps: DateComponents) -> String {
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return "\(comps.month!)/\(comps.day!)/\(comps.year!)" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "MMM d, yyyy"
        return out.string(from: date)
    }
}

/// Transcripts rows render through the shared transform.
public extension TranscriptItem {
    /// Legible row title (`Weekly Sync · Sep 24, 2026`).
    var displayName: String {
        MeetingDisplayName.displayName(for: name)
    }
}

/// Recordings rows render through the same transform (shared module,
/// identical output for sibling `.mp4`/`.vtt` stems).
public extension RecordingItem {
    /// Legible row title (`Weekly Sync · Sep 24, 2026`).
    var displayName: String {
        MeetingDisplayName.displayName(for: name)
    }
}
