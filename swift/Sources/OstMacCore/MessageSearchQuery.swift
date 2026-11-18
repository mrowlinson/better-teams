// MessageSearchQuery.swift — SHORTCUTS-R2 (SRCH-02/04): search operators
// + slash commands. One pure parser shared by every search surface
// (server post-filter, on-device index, feed matcher), so `from:`, `in:`,
// `date:` and `/unread`/`/saved` mean the same thing everywhere.
//
// Operators (case-insensitive keys; values may be `"quoted …"`):
//   from:<name>  sender display-name substring ("from:ava" finds Ava)
//   in:<chat>    conversation id, channel/team id, or chat display-name
//                substring (resolved by the caller's name hook)
//   date:<stamp> ISO prefix on the message timestamp ("date:2026-11-17",
//                "date:2026-11", "date:2026")
// Free text (whatever is left) keeps the old semantics verbatim: server
// free-text ranking, local token AND, feed substring match.
// Slash commands (first token only; unknown slashes stay plain text):
//   /unread  keep hits in unread threads (caller's unread hook)
//   /saved   the saved-messages list instead of search hits
import Foundation

/// Parsed search query: free text plus optional operator predicates.
public struct MessageSearchQuery: Equatable, Sendable {
    /// Slash command, when the query opens with one.
    public var slash: SlashCommand?
    /// Sender substring (`from:`), folded for compare.
    public var from: String?
    /// Conversation scope (`in:`), folded for compare.
    public var inScope: String?
    /// Timestamp ISO prefix (`date:`).
    public var date: String?
    /// Free text (operator tokens removed, quotes unwrapped).
    public var text: String

    /// True when any predicate narrows beyond the free text.
    public var hasFilters: Bool {
        slash != nil || from != nil || inScope != nil || date != nil
    }

    public init(
        text: String, from: String? = nil, inScope: String? = nil,
        date: String? = nil, slash: SlashCommand? = nil
    ) {
        self.text = text
        self.from = from
        self.inScope = inScope
        self.date = date
        self.slash = slash
    }

    // MARK: - Parse

    /// Split `raw` into free text + operators. Operator keys match
    /// case-insensitively; a value may be `"double quoted"`. The first
    /// whitespace-separated token may be a known slash command. Unknown
    /// `key:` prefixes and unknown slashes stay literal text (no surprise
    /// narrowing on a typo like "date;2026").
    public static func parse(_ raw: String) -> MessageSearchQuery {
        var slash: SlashCommand?
        var from: String?
        var inScope: String?
        var date: String?
        var words: [String] = []
        var tokens = tokenize(raw)
        if let first = tokens.first, let cmd = SlashCommand(rawValue: first.lowercased()) {
            slash = cmd
            tokens.removeFirst()
        }
        for token in tokens {
            if let (key, value) = splitOperator(token), !value.isEmpty {
                switch key {
                case "from":
                    if from == nil { from = fold(value) } else { words.append(token) }
                case "in":
                    if inScope == nil { inScope = fold(value) } else { words.append(token) }
                case "date":
                    if date == nil { date = value } else { words.append(token) }
                default: words.append(token)
                }
            } else {
                words.append(token)
            }
        }
        return MessageSearchQuery(
            text: words.joined(separator: " "),
            from: from, inScope: inScope, date: date, slash: slash)
    }

    // MARK: - Match

    /// Client-side predicate over one hit's fields. `chatName` resolves a
    /// chat/channel id to its display name for `in:` (nil = ids only);
    /// `isUnread` answers /unread per chat id (nil = no thread is unread).
    /// Slash `.saved` is a source switch, not a filter — always true here.
    public func matches(
        sender: String, chatID: String, channelID: String? = nil,
        teamID: String? = nil, timestamp: String = "",
        chatName: ((String) -> String?)? = nil,
        isUnread: ((String) -> Bool)? = nil
    ) -> Bool {
        if let from, !Self.senderFolded(sender).contains(from) { return false }
        if let inScope {
            let scope = Self.fold(chatID)
            let channel = Self.fold(channelID ?? "")
            let team = Self.fold(teamID ?? "")
            let name = Self.fold(chatName?(chatID) ?? "")
            let nameByChannel = Self.fold(channelID.flatMap { chatName?($0) } ?? "")
            if !scope.contains(inScope) && !channel.contains(inScope)
                && !team.contains(inScope) && !name.contains(inScope)
                && !nameByChannel.contains(inScope) { return false }
        }
        if let date, !timestamp.hasPrefix(date) { return false }
        if slash == .unread, !(isUnread?(chatID) ?? false) { return false }
        return true
    }

    /// Hit-shaped convenience over `matches(sender:chatID:…)`.
    public func matches(
        _ hit: SearchHit,
        chatName: ((String) -> String?)? = nil,
        isUnread: ((String) -> Bool)? = nil
    ) -> Bool {
        matches(
            sender: hit.sender, chatID: hit.chatID,
            channelID: hit.channelID, teamID: hit.teamID,
            timestamp: hit.timestamp, chatName: chatName, isUnread: isUnread)
    }

    // MARK: - Tokenize

    /// Whitespace split that keeps `"quoted …"` spans (quotes stripped).
    /// An unterminated quote runs to the end (no silent token loss).
    static func tokenize(_ raw: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted: Character?
        var has = false
        for ch in raw {
            if let q = quoted {
                if ch == q {
                    quoted = nil
                } else {
                    cur.append(ch)
                }
                has = true
            } else if ch == "\"" || ch == "”" || ch == "“" {
                quoted = ch
                has = true
            } else if ch.isWhitespace {
                if has {
                    out.append(cur)
                    cur = ""
                    has = false
                }
            } else {
                cur.append(ch)
                has = true
            }
        }
        if has { out.append(cur) }
        return out
    }

    /// `key:value` split (ASCII colon only; first colon wins). The key must
    /// be all letters (`date:2026` yes, `9:12` or `::` no).
    static func splitOperator(_ token: String) -> (key: String, value: String)? {
        guard let i = token.firstIndex(of: ":") else { return nil }
        let key = String(token[..<i]).lowercased()
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter }) else { return nil }
        return (key, String(token[token.index(after: i)...]))
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func senderFolded(_ s: String) -> String { fold(s) }
}

/// Leading slash command (closed set; unknown slashes stay plain text).
public enum SlashCommand: String, Sendable, Equatable, CaseIterable {
    /// Keep hits in unread threads (needs the caller's unread hook).
    case unread = "/unread"
    /// Search the saved-messages list instead of the index/server.
    case saved = "/saved"
}
