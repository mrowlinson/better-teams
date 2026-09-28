// CodeBlocks.swift — top10-code lane: fenced code blocks for composer + render.
//
// Demand (#8 code-first): pasted code must keep its indent end to end, and
// ``` fences must render as code, not literal backticks. This file is the
// pure core: fence parsing (shared by send + render), the send-body
// normalizer (line endings only — interior bytes untouched), and the
// fenced-info-string → highlight.js language map.
import Foundation

/// Fenced code blocks (``` or ~~~, CommonMark-ish, line-based).
public enum CodeBlocks {
    /// One parsed piece of a message: prose (styled normally) or code
    /// (fence lines consumed, mono + highlighted, never mined for
    /// mentions/links/shortcodes).
    public struct Segment: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case prose
            case code
        }

        public let kind: Kind
        /// Prose text (boundary newlines included), or the code WITHOUT
        /// fence lines.
        public let text: String
        /// Fenced info string, canonicalized (`swift`, `python`, …).
        /// Nil for prose and for bare/unknown fences (auto-detect).
        public let language: String?

        public init(kind: Kind, text: String, language: String? = nil) {
            self.kind = kind
            self.text = text
            self.language = language
        }
    }

    /// Max fenced blocks parsed per message (hostile-input cap; extra
    /// fences stay prose, never drop).
    public static let maxBlocks = 50

    /// True when `text` holds at least one fence line. Cheap pre-check so
    /// fence-less messages keep the legacy render path bit-identical.
    public static func containsFence(in text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if fenceMarker(String(line)) != nil { return true }
        }
        return false
    }

    /// Split `text` into prose/code segments. Fence lines are consumed;
    /// the newline that separated prose from a fence stays with the prose
    /// (so `hi\n```…```\nbye` renders `hi`, code, `bye` on three
    /// lines). An unclosed fence runs to end of text (GitHub parity;
    /// covers mid-typing states). Code interiors are byte-exact.
    public static func segments(in text: String) -> [Segment] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [Segment] = []
        var prose: [String] = []
        var code: [String]? = nil
        var codeLang: String? = nil
        var codeChar: Character = "`"
        var codeLen = 3
        var blocks = 0
        /// The closer just consumed was newline-terminated, so the next
        /// prose line needs a leading "\n" to keep its line.
        var leadNewline = false

        for (idx, line) in lines.enumerated() {
            let isLast = idx == lines.count - 1
            if code == nil {
                if blocks < maxBlocks, let m = fenceMarker(line), m.isOpener {
                    if !prose.isEmpty {
                        // The opener line follows, so the last prose line
                        // was newline-terminated: keep it.
                        out.append(Segment(
                            kind: .prose,
                            text: (leadNewline ? "\n" : "") + prose.joined(separator: "\n") + "\n"))
                        prose = []
                    }
                    leadNewline = false
                    code = []
                    codeLang = m.language
                    codeChar = m.char
                    codeLen = m.length
                    blocks += 1
                } else {
                    prose.append(line)
                }
            } else if isCloser(line, char: codeChar, length: codeLen) {
                out.append(Segment(kind: .code, text: code!.joined(separator: "\n"), language: codeLang))
                code = nil
                codeLang = nil
                leadNewline = !isLast
            } else {
                code!.append(line)
            }
        }
        if code != nil {
            out.append(Segment(kind: .code, text: code!.joined(separator: "\n"), language: codeLang))
        } else if !prose.isEmpty {
            out.append(Segment(
                kind: .prose,
                text: (leadNewline ? "\n" : "") + prose.joined(separator: "\n")))
        }
        return out
    }

    /// Ranges covering each fenced block INCLUDING its fence lines (for
    /// shortcode/link/mention exclusion over the original text).
    public static func codeRanges(in text: String) -> [Range<String.Index>] {
        // Line walk with ranges: opening fence line start → closing fence
        // line end (or text end when unclosed).
        var lines: [(line: String, range: Range<String.Index>)] = []
        var lineStart = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                lines.append((String(text[lineStart ..< i]), lineStart ..< text.index(after: i)))
                i = text.index(after: i)
                lineStart = i
            } else {
                i = text.index(after: i)
            }
        }
        lines.append((String(text[lineStart...]), lineStart ..< text.endIndex))
        var out: [Range<String.Index>] = []
        var open: (start: String.Index, char: Character, len: Int)? = nil
        var blocks = 0
        for (line, range) in lines {
            if let o = open {
                if isCloser(line, char: o.char, length: o.len) {
                    out.append(o.start ..< range.upperBound)
                    open = nil
                }
            } else if blocks < maxBlocks, let m = fenceMarker(line), m.isOpener {
                open = (range.lowerBound, m.char, m.length)
                blocks += 1
            }
        }
        if let o = open {
            out.append(o.start ..< text.endIndex)
        }
        return out
    }

    // MARK: - Send body

    /// Composer → core body: line endings normalized, outer whitespace
    /// trimmed (existing send contract), interior bytes untouched —
    /// indentation survives verbatim.
    public static func sendBody(for text: String) -> String {
        CodePaste.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fence grammar

    private struct Marker {
        let char: Character // "`" or "~"
        let length: Int // run length (≥ 3)
        let language: String? // canonical info string (openers only)
        let isOpener: Bool
    }

    /// Classify one source line: opener (```info / ~~~info / bare), or nil
    /// (not a fence line). Leading whitespace (any indent) allowed; info
    /// strings containing the fence char are not fences (CommonMark); a
    /// bare fence opens when prose is open, closes when code is open
    /// (decided by the caller via `isCloser`).
    private static func fenceMarker(_ line: String) -> Marker? {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        guard i < line.endIndex else { return nil }
        let c = line[i]
        guard c == "`" || c == "~" else { return nil }
        var j = i
        while j < line.endIndex, line[j] == c { j = line.index(after: j) }
        let len = line.distance(from: i, to: j)
        guard len >= 3 else { return nil }
        let rest = String(line[j...]).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            return Marker(char: c, length: len, language: nil, isOpener: true)
        }
        if c == "`", rest.contains("`") { return nil }
        if c == "~", rest.contains("~") { return nil }
        // Info string present → opener only (closers carry no info).
        let info = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return Marker(char: c, length: len, language: canonicalLanguage(info), isOpener: true)
    }

    /// A closer line: optional indent + ≥ opening-length run of the same
    /// char + nothing but whitespace after. An info-carrying line never
    /// closes (it would have been an opener).
    private static func isCloser(_ line: String, char: Character, length: Int) -> Bool {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        var j = i
        while j < line.endIndex, line[j] == char { j = line.index(after: j) }
        guard line.distance(from: i, to: j) >= length else { return false }
        return String(line[j...]).trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Language map

    /// Bundled highlight.js grammars (v11.10.0 common set).
    public static let supportedLanguages: Set<String> = [
        "bash", "c", "cpp", "csharp", "css", "diff", "go", "graphql",
        "ini", "java", "javascript", "json", "kotlin", "less", "lua",
        "makefile", "markdown", "objectivec", "perl", "php",
        "plaintext", "python", "r", "ruby", "rust", "scss", "shell",
        "sql", "swift", "typescript", "vbnet", "wasm", "xml", "yaml",
    ]

    private static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "py3": "python", "gyp": "python",
        "rb": "ruby", "rs": "rust", "golang": "go",
        "kt": "kotlin", "kts": "kotlin",
        "c++": "cpp", "hpp": "cpp", "hxx": "cpp", "cc": "cpp",
        "h": "c", "cs": "csharp", "c#": "csharp",
        "sh": "bash", "zsh": "bash", "fish": "bash",
        "yml": "yaml", "md": "markdown", "json5": "json",
        "m": "objectivec", "mm": "objectivec",
        "pl": "perl", "pm": "perl",
        "html": "xml", "xhtml": "xml",
        "patch": "diff", "tex": "plaintext", "text": "plaintext",
        "txt": "plaintext", "vb": "vbnet", "gql": "graphql",
        "toml": "ini", "cfg": "ini",
        "make": "makefile", "mk": "makefile",
        "wat": "wasm", "scala": "java",
    ]

    /// Info string → bundled grammar id, or nil (bare/unknown → auto).
    public static func canonicalLanguage(_ info: String) -> String? {
        let key = info.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if supportedLanguages.contains(key) { return key }
        if let mapped = aliases[key], supportedLanguages.contains(mapped) { return mapped }
        return nil
    }
}
