// CopilotMarkdown.swift — COPILOT-BUILD: assistant markdown → text.
//
// Answers arrive as markdown (Zenity type:2 `text`). Parsed with the
// system markdown parser; unparseable text falls back to verbatim
// (never dropped, never raw-HTML rendered).
import Foundation

public enum CopilotMarkdown {
    /// Markdown → attributed string for `Text`. Partial input while
    /// streaming still parses (unclosed spans degrade to literal).
    public static func attributed(_ markdown: String) -> AttributedString {
        if let a = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return a
        }
        return AttributedString(markdown)
    }
}
