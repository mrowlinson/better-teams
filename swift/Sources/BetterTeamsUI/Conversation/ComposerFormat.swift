// ComposerFormat.swift — COMPOSER-A (C1a): rich-text markdown transforms.
//
// The composer field stays plain text (`isRichText = false`); formatting
// inserts markdown markers and the wire renders them to Teams HTML
// (`build_message_html`). Everything here is pure string math over the
// UTF-16 selection the `NSTextView` reports, so it is unit-tested
// without a window. Markers:
//
//   **bold**  *italic*  __underline__  ~~strike~~  `code`
//   "- " bullets, "1. " numbers, "> " quotes, markdown tables
import AppKit

/// One formatting action (format bar button or keyboard shortcut).
enum ComposerFormatAction: Int, CaseIterable, Sendable {
    case bold
    case italic
    case underline
    case strike
    case inlineCode
    case bulletList
    case numberedList
    case quote
    case table
}

/// Pure markdown transforms for the composer field.
enum ComposerFormat {
    /// Marker pair each inline action wraps with.
    static func markers(for action: ComposerFormatAction) -> (open: String, close: String)? {
        switch action {
        case .bold: ("**", "**")
        case .italic: ("*", "*")
        case .underline: ("__", "__")
        case .strike: ("~~", "~~")
        case .inlineCode: ("`", "`")
        default: nil
        }
    }

    /// `⌘B/I/U` (keyCodes 11/34/32, command-only, no shift/option).
    /// Marked text is handled by the caller (IME guard lives in the view).
    static func shortcutAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ComposerFormatAction? {
        guard modifiers.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
        switch keyCode {
        case 11: return .bold
        case 34: return .italic
        case 32: return .underline
        default: return nil
        }
    }

    /// Applies `action` at `selection`, returning the new text and the
    /// selection to restore. Inline actions toggle: an exactly-wrapped
    /// selection unwraps, anything else wraps (empty selection inserts a
    /// bare pair with the caret between). Line actions toggle the prefix
    /// on every line the selection touches (current line when empty).
    static func apply(_ action: ComposerFormatAction, to text: String, selection: NSRange) -> (String, NSRange) {
        let ns = text as NSString
        let sel = clamped(selection, in: ns)
        if let m = markers(for: action) {
            return applyInline(open: m.open, close: m.close, ns: ns, selection: sel)
        }
        switch action {
        case .bulletList: return applyLines(prefix: .bullet, ns: ns, selection: sel)
        case .numberedList: return applyLines(prefix: .numbered, ns: ns, selection: sel)
        case .quote: return applyLines(prefix: .quote, ns: ns, selection: sel)
        case .table: return applyTable(ns: ns, selection: sel)
        default: return (text, sel) // unreachable (all inline handled above)
        }
    }

    // MARK: - Inline

    private static func applyInline(open: String, close: String, ns: NSString,
                                    selection sel: NSRange) -> (String, NSRange) {
        if sel.length == 0 {
            let out = ns.replacingCharacters(in: sel, with: open + close)
            return (out, NSRange(location: sel.location + (open as NSString).length, length: 0))
        }
        let inner = ns.substring(with: sel)
        // Unwrap only the matching layer: single markers must not sit
        // inside a doubled one ("**x**" + italic wraps to "***x***"
        // instead of corrupting to "*x*"); bold wins the "***x***"
        // ambiguity (same priority as the wire parser).
        let forbid: (String, String)?
        if open == "*" && close == "*" { forbid = ("**", "**") }
        else if open == "`" && close == "`" { forbid = ("``", "``") }
        else if open == "~~" && close == "~~" { forbid = ("~~~", "~~~") }
        else { forbid = nil }
        if let core = wrappedCore(inner, open: open, close: close, forbidding: forbid), !core.isEmpty {
            let out = ns.replacingCharacters(in: sel, with: core)
            return (out, NSRange(location: sel.location, length: (core as NSString).length))
        }
        let out = ns.replacingCharacters(in: sel, with: open + inner + close)
        return (out, NSRange(location: sel.location, length: sel.length + ((open + close) as NSString).length))
    }

    /// The text between one `open`/`close` layer, or nil when `s` is not
    /// wrapped in exactly that layer (`forbidding` names the longer
    /// doubled form that shadows it).
    private static func wrappedCore(_ s: String, open: String, close: String,
                                    forbidding: (String, String)?) -> String? {
        guard s.hasPrefix(open), s.hasSuffix(close),
              s.count >= open.count + close.count
        else { return nil }
        if let (fo, fc) = forbidding, s.hasPrefix(fo) || s.hasSuffix(fc) { return nil }
        return String(s.dropFirst(open.count).dropLast(close.count))
    }

    // MARK: - Line prefixes

    private enum LinePrefix { case bullet, numbered, quote }

    private static func applyLines(prefix: LinePrefix, ns: NSString, selection sel: NSRange) -> (String, NSRange) {
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: sel.length))
        var lines: [(range: NSRange, text: String)] = []
        ns.enumerateSubstrings(in: lineRange, options: [.byLines, .substringNotRequired]) { _, r, _, _ in
            lines.append((r, ns.substring(with: r)))
        }
        guard !lines.isEmpty else { return (ns as String, sel) }
        // Only content lines vote (blank lines never block a toggle-off).
        let content = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let allSet = !content.isEmpty && content.allSatisfy { hasPrefix($0.text, prefix) }
        // New text per line, computed top-down (numbers run 1, 2, 3…).
        var number = 1
        var replacement: [String?] = Array(repeating: nil, count: lines.count)
        for (idx, line) in lines.enumerated() {
            let t = line.text
            if t.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if allSet {
                replacement[idx] = stripPrefix(t, prefix)
            } else if !hasPrefix(t, prefix) {
                let n = prefix == .numbered ? "\(number). " : label(prefix)
                number += 1
                let indent = t.prefix(while: { $0 == " " || $0 == "\t" })
                replacement[idx] = String(indent) + n + String(t.dropFirst(indent.count))
            }
        }
        // Apply bottom-up so earlier ranges stay valid.
        var out = ns as String
        for idx in lines.indices.reversed() {
            if let r = replacement[idx] {
                out = (out as NSString).replacingCharacters(in: lines[idx].range, with: r)
            }
        }
        // Restore: the touched line span in the new text (length shifts by
        // the net inserted/removed prefix width).
        let first = lines.first!.range.location
        let lastEnd = lines.last!.range.location + lines.last!.range.length
        let shift = (out as NSString).length - ns.length
        return (out, clamped(NSRange(location: first, length: max(0, (lastEnd - first) + shift)), in: out as NSString))
    }

    private static func label(_ p: LinePrefix) -> String {
        switch p {
        case .bullet: "- "
        case .numbered: "1. " // placeholder; renumbered at insert
        case .quote: "> "
        }
    }

    private static func hasPrefix(_ line: String, _ p: LinePrefix) -> Bool {
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        switch p {
        case .bullet: return t.hasPrefix("- ") || t.hasPrefix("* ")
        case .numbered: return numberedPrefixLength(t) != nil
        case .quote: return t.hasPrefix("> ") || t == ">" || t.hasPrefix(">")
        }
    }

    private static func numberedPrefixLength(_ t: some StringProtocol) -> Int? {
        var i = t.startIndex
        while i < t.endIndex, t[i].isNumber { i = t.index(after: i) }
        guard i > t.startIndex, i < t.endIndex, t[i] == "." else { return nil }
        let after = t.index(after: i)
        guard after < t.endIndex, t[after] == " " else { return nil }
        return t.distance(from: t.startIndex, to: t.index(after: after))
    }

    private static func stripPrefix(_ line: String, _ p: LinePrefix) -> String {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = String(line.dropFirst(indent.count))
        switch p {
        case .bullet:
            if rest.hasPrefix("- ") || rest.hasPrefix("* ") { return String(indent) + String(rest.dropFirst(2)) }
            return line
        case .numbered:
            if let n = numberedPrefixLength(rest) { return String(indent) + String(rest.dropFirst(n)) }
            return line
        case .quote:
            if rest.hasPrefix("> ") { return String(indent) + String(rest.dropFirst(2)) }
            if rest == ">" { return String(indent) }
            if rest.hasPrefix(">") { return String(indent) + String(rest.dropFirst(1)) }
            return line
        }
    }

    // MARK: - Table

    /// Inserts a 2×2 skeleton at the caret (a selection collapses to its
    /// start first, never deleted). Caret lands in the first cell.
    static let tableSkeleton = "|  |  |\n|---|---|\n|  |  |"

    private static func applyTable(ns: NSString, selection sel: NSRange) -> (String, NSRange) {
        var insert = tableSkeleton
        // Own line: pad with newlines so the table never glues to prose.
        let before: String = sel.location > 0 ? ns.substring(to: sel.location) : ""
        let after: String = sel.location < ns.length ? ns.substring(from: sel.location) : ""
        var at = sel.location
        var prefix = ""
        var suffix = ""
        if !before.isEmpty, !before.hasSuffix("\n") { prefix = "\n" }
        if !after.isEmpty, !after.hasPrefix("\n") { suffix = "\n" }
        insert = prefix + tableSkeleton + suffix
        let out = ns.replacingCharacters(in: NSRange(location: sel.location, length: 0), with: insert)
        at += (prefix as NSString).length + 2 // inside the first cell
        return (out, NSRange(location: at, length: 0))
    }

    // MARK: - Bounds

    private static func clamped(_ r: NSRange, in ns: NSString) -> NSRange {
        let loc = min(max(0, r.location), ns.length)
        let end = min(max(loc, r.location + r.length), ns.length)
        return NSRange(location: loc, length: end - loc)
    }
}
