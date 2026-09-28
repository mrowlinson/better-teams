// CodeHighlight.swift — top10-code lane: syntax colors for code blocks.
//
// Engine pick (lane decision, justified): highlight.js 11.10.0, run
// headless in JavaScriptCore, spans mapped onto the native AttributedString
// bubble. Rejected: swift-syntax (Swift-only — demand is multi-language
// VS Code pastes — plus a huge package dep and minutes of compile on a
// pegged box) and highlight.js-in-WebView (breaks the native Text
// selection/menu bridge, per-bubble web processes). This pick adds zero
// Swift package deps, works offline (grammar bundle embedded in
// HighlightJSSource.swift), covers 36 languages, and degrades to mono on
// ANY engine failure — highlighting can never blank a bubble.
import Foundation
import JavaScriptCore

/// Syntax highlighting: code + language → token runs. Token → color is
/// the UI's palette (MessageTextAttributes.swift).
/// All engine contact runs under one lock (JSContext is not thread-safe);
/// every failure mode returns plain (mono, uncolored) runs.
public enum CodeHighlight {
    /// Token buckets the palette maps to colors. `plain` = uncolored.
    public enum Token: String, Hashable, Sendable, Codable {
        case keyword
        case string
        case comment
        case number
        case title
        case type
        case tag
        case plain
    }

    /// One run: `text` slices concatenate to the input code exactly.
    public struct Run: Equatable, Sendable {
        public let text: String
        public let token: Token

        public init(text: String, token: Token) {
            self.text = text
            self.token = token
        }
    }

    /// Max chars highlighted per block (bigger → mono; keeps body-eval
    /// cost bounded — the styled cache still memoizes the rest).
    public static let maxCodeChars = 20_000

    /// Engine version pin (fails safe: nil context → nil).
    public static func engineVersion() -> String? {
        highlightLock.lock()
        defer { highlightLock.unlock() }
        guard let ctx = sharedContext() else { return nil }
        return ctx.objectForKeyedSubscript("hljs")?
            .objectForKeyedSubscript("versionString").toString()
    }

    /// True when the engine loaded and answers (tests + diagnostics).
    public static func isAvailable() -> Bool {
        engineVersion() != nil
    }

    /// True when `language` names a bundled grammar (canonical ids only;
    /// use `CodeBlocks.canonicalLanguage` for info strings).
    public static func supports(_ language: String) -> Bool {
        highlightLock.lock()
        defer { highlightLock.unlock() }
        guard let ctx = sharedContext(),
              let hljs = ctx.objectForKeyedSubscript("hljs"),
              let hit = hljs.invokeMethod("getLanguage", withArguments: [language])
        else { return false }
        return !hit.isUndefined && !hit.isNull
    }

    /// Highlight `code` (canonical `language`, or nil → auto-detect).
    /// Returns runs concatenating to `code` exactly; empty code → [].
    /// Oversize/failure → single `.plain` run (callers still go mono).
    public static func runs(code: String, language: String?) -> [Run] {
        guard !code.isEmpty else { return [] }
        guard code.count <= maxCodeChars else { return [Run(text: code, token: .plain)] }
        highlightLock.lock()
        defer { highlightLock.unlock() }
        guard let ctx = sharedContext(),
              let hljs = ctx.objectForKeyedSubscript("hljs")
        else { return [Run(text: code, token: .plain)] }
        let html: String?
        if let language {
            let opts = ctx.evaluateScript("({language: \(jsString(language)), ignoreIllegals: true})")
            html = hljs.invokeMethod("highlight", withArguments: [code, opts as Any])?
                .objectForKeyedSubscript("value").toString()
        } else {
            html = hljs.invokeMethod("highlightAuto", withArguments: [code])?
                .objectForKeyedSubscript("value").toString()
        }
        // Unknown grammars throw inside the engine: swallow (handler is a
        // no-op) and degrade to plain — highlighting never fails a bubble.
        if ctx.exception != nil {
            ctx.exception = nil
            return [Run(text: code, token: .plain)]
        }
        guard let html else { return [Run(text: code, token: .plain)] }
        return runsFromHTML(html, code: code)
    }

    // MARK: - Engine (locked)

    private static let highlightLock = NSLock()
    private static var context: JSContext?

    /// Caller holds `highlightLock`.
    private static func sharedContext() -> JSContext? {
        if let context { return context }
        guard let script = HighlightJSSource.script() else { return nil }
        let ctx = JSContext()
        ctx?.exceptionHandler = { _, _ in }
        ctx?.evaluateScript(script)
        guard ctx?.objectForKeyedSubscript("hljs") != nil else { return nil }
        // `hljs` exists but may be undefined on partial load; verify.
        if ctx?.objectForKeyedSubscript("hljs")?.isUndefined == true { return nil }
        context = ctx
        return ctx
    }

    /// JS string literal for an identifier (canonical ids are [a-z]+, but
    /// quote defensively — never interpolate raw into script).
    private static func jsString(_ s: String) -> String {
        "\"" + s.map { c -> String in
            switch c {
            case "\"": return "\\\""
            case "\\": return "\\\\"
            case "\n": return "\\n"
            case "\r": return "\\r"
            default: return String(c)
            }
        }.joined() + "\""
    }

    // MARK: - Span HTML → runs

    /// Flatten hljs `<span class="hljs-x">` HTML into runs. Entities are
    /// decoded per text chunk (hljs escapes `&<>"`); nested spans take the
    /// INNERMOST class. The decoded concatenation must equal `code`
    /// exactly, else the whole block degrades to `.plain` (never emit
    /// misaligned colors).
    static func runsFromHTML(_ html: String, code: String) -> [Run] {
        var runs: [(String, [String])] = [] // (decoded text, class stack)
        var stack: [String] = []
        var i = html.startIndex
        var buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            runs.append((MessageRender.decodeEntities(buf), stack))
            buf = ""
        }
        while i < html.endIndex {
            if html[i] == "<",
                let gt = html[i...].firstIndex(of: ">")
            {
                let tag = String(html[html.index(after: i) ..< gt])
                flush()
                if tag.hasPrefix("/span") {
                    if !stack.isEmpty { stack.removeLast() }
                } else if tag.hasPrefix("span") {
                    stack.append(spanClass(tag) ?? "")
                }
                // Other tags (hljs emits none) are skipped, text kept.
                i = html.index(after: gt)
            } else {
                buf.append(html[i])
                i = html.index(after: i)
            }
        }
        flush()
        // Merge adjacent same-token runs, then verify alignment.
        var merged: [Run] = []
        for (text, classes) in runs {
            let tok = tokenFor(classes: classes)
            if let last = merged.last, last.token == tok {
                merged[merged.count - 1] = Run(text: last.text + text, token: tok)
            } else {
                merged.append(Run(text: text, token: tok))
            }
        }
        guard merged.map(\.text).joined() == code else {
            return [Run(text: code, token: .plain)]
        }
        return merged
    }

    /// First `hljs-*` class on the span tag (hljs joins extras with
    /// spaces, e.g. `hljs-title function_`).
    private static func spanClass(_ tag: String) -> String? {
        guard let r = tag.range(of: "class=\"") else { return nil }
        let rest = tag[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Innermost meaningful class → token. Unknown classes → `.plain`
    /// (mono, uncolored — never a wrong color).
    static func tokenFor(classes: [String]) -> Token {
        for cls in classes.reversed() {
            for part in cls.split(separator: " ") {
                let c = part.hasPrefix("hljs-") ? String(part.dropFirst(5)) : String(part)
                switch c {
                case "keyword", "selector-tag", "doctag": return .keyword
                case "string", "regexp": return .string
                case "comment", "quote": return .comment
                case "number": return .number
                case "title", "title.function_", "title.class_", "section": return .title
                case "type", "built_in", "literal", "symbol", "class": return .type
                case "tag", "name", "attr", "attribute", "selector-id",
                     "selector-class", "selector-attr", "selector-pseudo": return .tag
                case "hljs", "function_", "class_": continue // modifiers, keep looking out
                default: continue // unknown → keep looking outward, else plain
                }
            }
        }
        return .plain
    }
}
