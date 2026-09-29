// CatchUpOnDevice.swift — AICATCH lane: on-device catch-up building blocks.
//
// Apple's on-device model is the only catch-up engine users see. Its
// limits (measured on this Mac) shape everything here:
//   - Context window is 4096 tokens (prompt + response), so long
//     threads are chunked and summarized map-reduce style: per-chunk
//     notes, then one combining pass. Token counts are ESTIMATED
//     conservatively (3 UTF-8 bytes per token; English averages ~4).
//   - Guided generation refuses often, so output is plain text in an
//     abstractly described layout and `CatchUpSummaryParser` reads it.
//   - The model copies prompt examples as facts, so prompts describe
//     the layout in words and carry NO example content.
// Mention flagging is deterministic (mention entities in the message
// markup, via `Mentions`) and never asks the model.
import Foundation

// MARK: - Mode

/// The one Catch Up setting (Settings ▸ AI).
public enum CatchUpMode: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Button hidden, no model work at all.
    case off
    /// Summaries run when the user clicks Catch Up (on demand).
    case onClick = "on-click"
    /// Summaries of conversations with new messages stay current in the
    /// background (debounced, incremental, paused on low power/heat).
    case alwaysUpToDate = "always"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .onClick: "When I click the AI button"
        case .alwaysUpToDate: "Always up to date"
        }
    }
}

// MARK: - Streaming seam

/// A transport that can stream cumulative partial text (on-device).
public protocol CatchUpStreamingTransport: CatchUpTransport {
    func stream(prompt: String, maxTokens: Int?, onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

// MARK: - Token budget + chunking

public enum CatchUpChunker {
    /// Measured system-model context (prompt + response).
    public static let contextTokens = 4096
    /// Response caps per call kind.
    public static let finalResponseTokens = 500
    public static let notesResponseTokens = 220
    /// Instruction text + safety margin.
    public static let overheadTokens = 400
    /// Input tokens one call may carry (transcript or notes). Well
    /// under 4096 − 500 − 400: the 3-byte estimate already overcounts,
    /// and the margin absorbs tokenizer surprises (names, emoji, code).
    public static let inputBudget = 2400
    /// Per-chat cap: only the newest chunks are read (older history is
    /// what the user has most likely seen; bounds per-cycle work).
    public static let maxChunks = 4
    /// One message line never exceeds this many characters.
    public static let maxLineChars = 800

    /// Conservative estimate: 3 UTF-8 bytes per token, rounded up.
    public static func estimateTokens(_ s: String) -> Int {
        (s.utf8.count + 2) / 3
    }

    /// "Sender: text" lines, oldest first; deleted/empty messages drop,
    /// newlines fold, each line capped at `maxLineChars`.
    public static func lines(_ messages: [ChatMessage]) -> [String] {
        messages.compactMap { m in
            guard !m.deleted else { return nil }
            let text = m.content.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let line = "\(m.sender): \(text)"
            return line.count > maxLineChars ? String(line.prefix(maxLineChars)) + "…" : line
        }
    }

    /// Greedy line packing: every chunk's estimate stays within
    /// `budget` (a single oversized line is truncated to fit). Keeps
    /// only the newest `maxChunks` chunks, oldest first.
    public static func chunks(_ lines: [String], budget: Int = inputBudget, maxChunks: Int = maxChunks) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        var curTokens = 0
        // Walk newest → oldest so the cap drops the head, not the tail.
        for raw in lines.reversed() {
            var line = raw
            if estimateTokens(line) + 1 > budget {
                line = String(line.prefix(max(0, (budget - 2) * 3)))
            }
            let t = estimateTokens(line) + 1 // + newline
            if curTokens + t > budget, !cur.isEmpty {
                out.append(cur.reversed().joined(separator: "\n"))
                if out.count == maxChunks { return out.reversed() }
                cur = []
                curTokens = 0
            }
            cur.append(line)
            curTokens += t
        }
        if !cur.isEmpty, out.count < maxChunks { out.append(cur.reversed().joined(separator: "\n")) }
        return out.reversed()
    }
}

// MARK: - Prompts (no example content, ever)

public enum CatchUpPrompts {
    static let layout = """
        Write plain text with exactly three parts, in this order:
        A line that starts with SUMMARY: followed by one or two sentences on what the conversation is about and where it stands.
        A line that says POINTS: followed by up to five lines, each starting with "- ", covering decisions, questions and news, oldest first.
        A line that says ACTIONS: followed by one line per task, each starting with "- ", naming who owns it when the messages say so. If there are no tasks, write "- None".
        Leave out social chat: food or drink orders, greetings, thanks, jokes, celebrations, and plans whose moment has passed.
        Write nothing else.
        """

    static let messagesHeader = "Messages, oldest first, one per line as \"Sender: text\":"

    /// Whole conversation fits one call.
    public static func final(transcript: String) -> String {
        """
        You help someone catch up on a work conversation they missed. Use only facts written in the messages below. Do not guess and do not add anything that is not written there.

        \(layout)

        \(messagesHeader)
        \(transcript)
        """
    }

    /// Map step: notes for one part of a long conversation.
    public static func notes(chunk: String) -> String {
        """
        Below is one part of a longer work conversation. Write up to six short lines, each starting with "- ", that record the decisions, questions, requests and tasks in this part and who is involved. Skip social chat such as food orders, greetings and thanks. Use only facts written in the messages. Write nothing else.

        \(messagesHeader)
        \(chunk)
        """
    }

    /// Reduce step: combine per-part notes.
    public static func combine(notes: String) -> String {
        """
        You help someone catch up on a work conversation they missed. Below are notes taken from consecutive parts of it, oldest first. Use only facts written in the notes. Do not guess and do not add anything else.

        \(layout)

        Notes:
        \(notes)
        """
    }

    /// Incremental step: fold new messages into the previous catch-up.
    public static func update(previous: String, newMessages: String) -> String {
        """
        You keep a running catch-up of a work conversation. Below is the current catch-up, then the messages that arrived after it. Rewrite the catch-up so it covers everything. Use only facts written in the current catch-up and the new messages. Do not guess and do not add anything else.

        \(layout)

        Current catch-up:
        \(previous)

        New \(messagesHeader.prefix(1).lowercased())\(messagesHeader.dropFirst())
        \(newMessages)
        """
    }
}

// MARK: - Parser

/// The model's plain-text catch-up, read into parts. Lenient: accepts
/// markdown decoration, "TL;DR"/"Key points"/"Action items" spellings,
/// and any bullet glyph. Output with no recognizable headers keeps its
/// bullets as points and the rest as the summary.
public struct ParsedCatchUp: Sendable, Equatable {
    public var summary: String
    public var points: [String]
    public var actions: [String]

    public init(summary: String = "", points: [String] = [], actions: [String] = []) {
        self.summary = summary
        self.points = points
        self.actions = actions
    }

    public var isEmpty: Bool { summary.isEmpty && points.isEmpty && actions.isEmpty }

    /// One list line with an identity for lists (position + text: the
    /// same line in the same slot keeps its row across re-parses).
    public struct Line: Identifiable, Sendable, Equatable {
        public let id: String
        public let text: String
    }

    public var pointLines: [Line] { Self.lines(points, "p") }
    public var actionLines: [Line] { Self.lines(actions, "a") }

    static func lines(_ items: [String], _ tag: String) -> [Line] {
        var out: [Line] = []
        for i in items.indices { out.append(Line(id: "\(tag)\(i):\(items[i])", text: items[i])) }
        return out
    }
}

public enum CatchUpSummaryParser {
    enum Part { case summary, points, actions }

    static let headers: [(String, Part)] = [
        ("summary", .summary), ("tl;dr", .summary), ("tldr", .summary),
        ("key points", .points), ("points", .points),
        ("action items", .actions), ("actions", .actions),
    ]

    public static func parse(_ text: String) -> ParsedCatchUp {
        var out = ParsedCatchUp()
        var part: Part?
        var summaryLines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            line = line.replacingOccurrences(of: "**", with: "")
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if let (p, rest) = header(line) {
                part = p
                if !rest.isEmpty { add(rest, to: p, &out, &summaryLines) }
                continue
            }
            let (isBullet, body) = bullet(line)
            guard !body.isEmpty else { continue }
            add(body, to: part ?? (isBullet ? .points : .summary), &out, &summaryLines)
        }
        out.summary = summaryLines.joined(separator: " ")
        out.actions.removeAll { isNone($0) }
        out.points.removeAll { isNone($0) }
        return out
    }

    private static func add(_ s: String, to p: Part, _ out: inout ParsedCatchUp, _ summary: inout [String]) {
        switch p {
        case .summary: summary.append(s)
        case .points: out.points.append(s)
        case .actions: out.actions.append(s)
        }
    }

    /// "SUMMARY: text", "1. TL;DR — text", "Key points:" → (part, rest).
    static func header(_ line: String) -> (Part, String)? {
        var l = line
        // Numbered section prefix ("1. ", "2) ").
        if let r = l.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) { l.removeSubrange(r) }
        let lower = l.lowercased()
        // The key must end the line or be followed by a separator, so
        // prose like "Summary of the week" stays prose.
        for (key, p) in headers where lower.hasPrefix(key) {
            let after = l.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            if after.isEmpty { return (p, "") }
            guard let f = after.first, f == ":" || f == "—" || f == "–" || f == "-" else { continue }
            return (p, after.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func bullet(_ line: String) -> (Bool, String) {
        for g in ["- ", "• ", "* ", "– ", "— "] where line.hasPrefix(g) {
            // Doubled glyphs ("- - text", seen from the model) strip too.
            return (true, bullet(String(line.dropFirst(g.count)).trimmingCharacters(in: .whitespaces)).1)
        }
        if let r = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return (true, String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return (false, line)
    }

    static func isNone(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return t == "none" || t == "n/a" || t == "no tasks" || t == "no action items"
    }
}

// MARK: - Engine

/// One conversation → one catch-up, within the 4096-token window:
/// single call when the transcript fits, else notes per chunk (map)
/// then one combining pass (reduce, hierarchical if the notes overflow).
/// `previous` enables the cheap incremental path: fold only the
/// messages after `afterMessageID` into the last catch-up.
public struct OnDeviceCatchUpEngine: Sendable {
    public let transport: any CatchUpTransport

    public init(transport: any CatchUpTransport) {
        self.transport = transport
    }

    public struct Previous: Sendable, Equatable {
        public let text: String
        public let afterMessageID: String
        public init(text: String, afterMessageID: String) {
            self.text = text
            self.afterMessageID = afterMessageID
        }
    }

    /// Calls made by the last `summarize` (tests + measurement).
    public enum Plan: Equatable, Sendable {
        case single, incremental, mapReduce(chunks: Int)
    }

    /// Which path `summarize` takes for these inputs (pure).
    public static func plan(messages: [ChatMessage], previous: Previous?) -> Plan {
        if let previous, let tail = newLines(messages, after: previous.afterMessageID), !tail.isEmpty,
           CatchUpChunker.estimateTokens(previous.text) + CatchUpChunker.estimateTokens(tail.joined(separator: "\n"))
           <= CatchUpChunker.inputBudget
        {
            return .incremental
        }
        let chunks = CatchUpChunker.chunks(CatchUpChunker.lines(messages))
        return chunks.count <= 1 ? .single : .mapReduce(chunks: chunks.count)
    }

    public func summarize(
        messages: [ChatMessage], previous: Previous? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let plan = Self.plan(messages: messages, previous: previous)
        switch plan {
        case .incremental:
            let tail = Self.newLines(messages, after: previous!.afterMessageID) ?? []
            return try await call(CatchUpPrompts.update(previous: previous!.text, newMessages: tail.joined(separator: "\n")),
                                  maxTokens: CatchUpChunker.finalResponseTokens, onPartial: onPartial)
        case .single:
            let chunks = CatchUpChunker.chunks(CatchUpChunker.lines(messages))
            guard let only = chunks.first else { throw CatchUpError.empty }
            return try await call(CatchUpPrompts.final(transcript: only),
                                  maxTokens: CatchUpChunker.finalResponseTokens, onPartial: onPartial)
        case .mapReduce:
            let chunks = CatchUpChunker.chunks(CatchUpChunker.lines(messages))
            var notes: [String] = []
            for c in chunks {
                try Task.checkCancellation()
                let n = try await call(CatchUpPrompts.notes(chunk: c), maxTokens: CatchUpChunker.notesResponseTokens, onPartial: nil)
                notes.append(n.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Hierarchical reduce: combine groups until one fits.
            var joined = notes.joined(separator: "\n")
            while CatchUpChunker.estimateTokens(joined) > CatchUpChunker.inputBudget, notes.count > 1 {
                let groups = CatchUpChunker.chunks(notes, maxChunks: .max)
                guard groups.count < notes.count else { break }
                var next: [String] = []
                for g in groups {
                    try Task.checkCancellation()
                    next.append(try await call(CatchUpPrompts.notes(chunk: g), maxTokens: CatchUpChunker.notesResponseTokens, onPartial: nil))
                }
                notes = next
                joined = notes.joined(separator: "\n")
            }
            try Task.checkCancellation()
            return try await call(CatchUpPrompts.combine(notes: joined),
                                  maxTokens: CatchUpChunker.finalResponseTokens, onPartial: onPartial)
        }
    }

    /// Lines after `id` (nil when `id` is no longer in the window —
    /// the incremental path then falls back to a full summary).
    static func newLines(_ messages: [ChatMessage], after id: String) -> [String]? {
        guard let i = messages.lastIndex(where: { $0.id == id }) else { return nil }
        return CatchUpChunker.lines(Array(messages[(i + 1)...]))
    }

    private func call(_ prompt: String, maxTokens: Int, onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        let text: String
        if let onPartial, let s = transport as? any CatchUpStreamingTransport {
            text = try await s.stream(prompt: prompt, maxTokens: maxTokens, onPartial: onPartial)
        } else {
            text = try await transport.complete(baseURL: "", apiKey: "", model: "", prompt: prompt)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatchUpError.empty }
        return text
    }
}

// MARK: - Mentions (deterministic)

/// One message that mentions the signed-in user or the whole chat.
public struct CatchUpMention: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        /// @mentions the signed-in user.
        case you
        /// @everyone / @channel / @team.
        case everyone
        /// A Teams tag (@tag) whose members include the signed-in user.
        case tag
    }

    public let kind: Kind
    public let chatID: String
    public let chatName: String
    public let messageID: String
    public let sender: String
    public let timestamp: String
    public let preview: String

    public var id: String { "\(chatID):\(messageID)" }

    public init(kind: Kind, chatID: String, chatName: String, messageID: String,
                sender: String, timestamp: String, preview: String) {
        self.kind = kind
        self.chatID = chatID
        self.chatName = chatName
        self.messageID = messageID
        self.sender = sender
        self.timestamp = timestamp
        self.preview = preview
    }
}

public enum CatchUpMentions {
    /// Mention kind for one message from its mention entities (the
    /// unstripped markup's `<at>` tags / Mention spans), never from
    /// text guesses or the model. Own and deleted messages never flag.
    /// A message that names the user AND the whole chat reads `.you`.
    public static func kind(of m: ChatMessage, ownerMRI: String?, ownerDisplayName: String,
                            ownerTags: Set<String> = []) -> CatchUpMention.Kind? {
        guard !m.deleted, !m.isOwn else { return nil }
        let own = ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty, m.sender == own { return nil }
        guard let raw = m.raw, !raw.isEmpty else { return nil }
        let mentions = Mentions.parse(content: raw)
        guard !mentions.isEmpty else { return nil }
        if Mentions.mentionsOwner(mentions, ownerMRI: ownerMRI, ownerDisplayName: own) { return .you }
        if Mentions.mentionsChannelOrEveryone(mentions) { return .everyone }
        if CatchUpTags.mentionsTag(mentions, ownerTags: ownerTags) { return .tag }
        return nil
    }

    /// Flagged messages in `messages`, oldest first.
    public static func flag(_ messages: [ChatMessage], chatID: String, chatName: String,
                            ownerMRI: String?, ownerDisplayName: String,
                            ownerTags: Set<String> = []) -> [CatchUpMention] {
        messages.compactMap { m in
            kind(of: m, ownerMRI: ownerMRI, ownerDisplayName: ownerDisplayName, ownerTags: ownerTags).map {
                CatchUpMention(kind: $0, chatID: chatID, chatName: chatName, messageID: m.id,
                               sender: m.sender, timestamp: m.timestamp,
                               preview: String(m.content.replacingOccurrences(of: "\n", with: " ").prefix(200)))
            }
        }
    }
}
