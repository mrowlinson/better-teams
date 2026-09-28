// CodePaste.swift — top10-code lane: plain-text-first paste for the composer.
//
// Demand (#8 code-first): TechCommunity 2349812 — pasting from VS Code
// strips indentation because the composer consumes the styled clipboard
// flavor. Rule: the `.string` flavor always wins; styled flavors (RTF/HTML)
// are fallback-only and convert without collapsing whitespace. Both
// composers are plain TextFields (stock paste already takes `.string`),
// so the wired fallback only fires when NO string flavor exists — stock
// behavior is never overridden, only rescued.
import AppKit
import Combine

/// Plain-text-first paste resolution. Pure except the live-pasteboard
/// convenience (which tests never touch — they inject flavors).
public enum CodePaste {
    /// Line-ending normalization: CRLF/CR → LF. Nothing else changes —
    /// tabs, leading spaces, and blank lines survive verbatim.
    public static func normalize(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\r\n", with: "\n")
        out = out.replacingOccurrences(of: "\r", with: "\n")
        return out
    }

    /// Pick paste text from clipboard flavors: `.string` first; else RTF
    /// converted to plain; else HTML converted to plain (block boundaries
    /// become newlines, never spaces — indent survives). Nil when no
    /// usable flavor exists. Never trims: the caller owns edge policy.
    public static func resolve(string: String?, rtf: Data?, html: String?) -> String? {
        if let string { return normalize(string) }
        if let rtf, let converted = plainFromRTF(rtf) { return normalize(converted) }
        if let html { return normalize(plainFromHTML(html)) }
        return nil
    }

    /// RTF data → plain string. Nil on unparseable input.
    public static func plainFromRTF(_ data: Data) -> String? {
        guard let attr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
        else { return nil }
        return attr.string
    }

    /// HTML → plain string, indent-preserving: block closes and `<br>`
    /// become newlines BEFORE tags strip (the bubble stripper maps them
    /// to spaces instead — wrong for paste). Entities decoded.
    public static func plainFromHTML(_ html: String) -> String {
        var s = html
        // Block boundaries → newline (case-insensitive).
        for tag in ["br", "p", "div", "pre", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
                    "blockquote", "section", "article", "header", "footer", "ul", "ol"]
        {
            s = s.replacingOccurrences(of: "</\(tag)", with: "\n</\(tag)", options: .caseInsensitive)
            if tag == "br" {
                s = s.replacingOccurrences(of: "<\(tag)", with: "\n<\(tag)", options: .caseInsensitive)
            }
        }
        return MessageRender.decodeEntities(MessageRender.stripTags(s))
    }

    /// Live flavors → paste text. Tests inject flavors into `resolve`
    /// instead; this is the only live-pasteboard read.
    public static func resolvedPaste(from pb: NSPasteboard = .general) -> String? {
        resolve(
            string: pb.string(forType: .string),
            rtf: pb.data(forType: .rtf),
            html: pb.string(forType: .html))
    }

    /// True when stock paste would insert nothing useful but a styled
    /// flavor exists to rescue: no `.string`, but RTF or HTML present.
    /// The ONLY case the composer intercepts (append-at-end; the
    /// alternative is an empty paste).
    public static func shouldInterceptPaste(from pb: NSPasteboard = .general) -> Bool {
        guard pb.string(forType: .string) == nil else { return false }
        return pb.data(forType: .rtf) != nil || pb.string(forType: .html) != nil
    }
}

