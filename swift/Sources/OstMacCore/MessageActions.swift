// MessageActions.swift — om-msgactions lane: copy/forward/save helpers.
//
// Pure logic behind the bubble context menu (top-level items only, never
// a submenu). Copy builds a text+rich payload and hands it to an injected
// writer (tests capture it; production passes the live pasteboard
// writer), so no test ever touches the live pasteboard. Forward posts
// via ConversationStore.forward(_:toChatID:) (demo-recorded, live via
// the plain send path) with a forwarded-attribution header.
import AppKit
import Foundation

/// Copy/forward/save text + filename builders. No view or FFI code.
public enum MessageActions {
    /// What Copy puts on the pasteboard: exactly what the bubble shows
    /// (shortcodes expanded, same source as MessageRender.attributedBody)
    /// plus one `title — url` line per bot-post row (title alone when
    /// no link parsed). Plain messages are unchanged (no rows).
    public static func copyText(for message: ChatMessage) -> String {
        let body = MessageRender.bubbleText(for: message)
        let parsedCards = MessageBubbleState.cards(for: message)
        let cards = parsedCards.flatMap(\.copyLines)
        let posts = MessageRender.botPosts(fromRaw: message.raw ?? message.content)
        let rows: [String]
        if MessageBubbleState.shouldShowFallbackRows(posts: posts, cards: parsedCards) {
            rows = posts.map { post in
                if let url = post.url { return "\(post.title) — \(url)" }
                return post.title
            }
        } else {
            rows = []
        }
        return ([body] + cards + rows).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One Copy payload: the plain bubble text plus an RTF rendering
    /// of the same text (bold mentions, monospaced code, links), so
    /// rich targets paste styled text and plain targets paste text.
    /// `rtf` is nil when there is no text to style.
    public struct CopyPayload: Sendable, Equatable {
        public let text: String
        public let rtf: Data?

        public init(text: String, rtf: Data? = nil) {
            self.text = text
            self.rtf = rtf
        }
    }

    /// Build the Copy payload for one bubble: `copyText` plus its RTF.
    /// Pure — the caller decides where it goes via `copy(_:write:)`.
    public static func copyPayload(
        for message: ChatMessage, highlighting ownName: String? = nil
    ) -> CopyPayload {
        let text = copyText(for: message)
        guard !text.isEmpty else { return CopyPayload(text: text, rtf: nil) }
        let styled = NSAttributedString(MessageRender.attributedBody(
            text: text, raw: message.raw, highlighting: ownName))
        let rtf = try? styled.data(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return CopyPayload(text: text, rtf: rtf)
    }

    /// Copy one bubble through an injected writer: production passes
    /// `liveCopyWriter`, tests pass a capturing closure (no live
    /// pasteboard involved).
    public static func copy(
        _ message: ChatMessage, highlighting ownName: String? = nil,
        write: (CopyPayload) -> Void
    ) {
        write(copyPayload(for: message, highlighting: ownName))
    }

    /// The production Copy writer: text as `.string`, RTF as `.rtf`
    /// when present. The only live-pasteboard touch in the copy path.
    public static func liveCopyWriter(_ payload: CopyPayload) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload.text, forType: .string)
        if let rtf = payload.rtf {
            pb.setData(rtf, forType: .rtf)
        }
    }

    /// What Forward posts to the picked chat: the plain bubble text
    /// with a one-line forwarded-attribution header naming the
    /// original sender (the plain send path carries no forward
    /// metadata, so the header is the attribution; the destination
    /// bubble still stamps its own sender/time below it).
    public static func forwardBody(for message: ChatMessage) -> String {
        let who = message.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = who.isEmpty ? "Unknown" : who
        return "Forwarded from \(name):\n\(copyText(for: message))"
    }

    /// What Save writes to disk: a stable header (sender + raw ISO
    /// timestamp, never the relative displayTime) plus the bubble text.
    /// Image-only bubbles still save their header (text may be empty).
    public static func saveBody(for message: ChatMessage) -> String {
        "From: \(message.sender)\nDate: \(message.timestamp)\n\n\(copyText(for: message))\n"
    }

    /// Default save-panel filename: `message-<sanitized id>.txt`.
    /// Falls back to `message.txt` when the id sanitizes to nothing.
    public static func saveFilename(for message: ChatMessage) -> String {
        let base = sanitizedFilename("message-\(message.id)")
        let stem = base.isEmpty ? "message" : base
        return "\(stem).txt"
    }

    /// Filename-safe: runs of anything outside [A-Za-z0-9._-] become one
    /// `-`, leading/trailing dots + dashes trimmed, stem capped at 60
    /// chars (extension added by the caller).
    public static func sanitizedFilename(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var dash = false
        for ch in raw {
            let ok = ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-"
            if ok {
                out.append(ch)
                dash = false
            } else if !dash {
                out.append("-")
                dash = true
            }
        }
        while out.hasPrefix(".") || out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix(".") || out.hasSuffix("-") { out.removeLast() }
        if out.count > 60 { out = String(out.prefix(60)) }
        while out.hasSuffix(".") || out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// One forwarded bubble (om-msgactions): source id + destination +
    /// sent body. Host-side only (never decoded from core).
    public struct ForwardRecord: Equatable, Sendable {
        public let messageID: String
        public let destChatID: String
        public let body: String

        public init(messageID: String, destChatID: String, body: String) {
            self.messageID = messageID
            self.destChatID = destChatID
            self.body = body
        }
    }

    /// One-line quote for the forward sheet header: sender + collapsed
    /// preview (120 chars + ellipsis, same shape as reply quotes).
    public static func forwardPreview(for message: ChatMessage) -> String {
        let flat = copyText(for: message)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > 120 else { return flat.isEmpty ? "(no text)" : flat }
        return String(flat.prefix(120)) + "…"
    }
}
