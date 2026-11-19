// PraiseCard.swift — Praise post mining + outgoing shape (PRAISE lane).
//
// A Teams Praise post is a chat message carrying an Adaptive Card
// attachment (contentType `application/vnd.microsoft.card.adaptive`):
// a ColumnSet with the badge Image (altText = badge name) beside the
// "<sender> sent praise to" / recipient / note TextBlocks, plus the
// Praise app id. Mining keys on the "sent praise to" marker so
// arbitrary bot cards never classify as praise.
import Foundation

/// One mined Praise post.
public struct PraisePost: Sendable, Equatable {
    public let badge: PraiseBadge?
    public let sender: String
    public let recipient: String
    public let note: String

    public init(badge: PraiseBadge?, sender: String, recipient: String, note: String) {
        self.badge = badge
        self.sender = sender
        self.recipient = recipient
        self.note = note
    }
}

public enum PraiseCard {
    /// Praise app id real clients stamp on the attachment.
    public static let appID = "d832a33f-28c2-4969-8ad0-4fee681dc5b4"
    /// Adaptive Card content type carried on praise attachments.
    public static let adaptiveContentType = "application/vnd.microsoft.card.adaptive"
    /// Marker line every Praise card carries.
    public static let sentMarker = "sent praise to"

    // MARK: - mining

    /// The Praise post in `raw` (attachment envelope, bare card, or a
    /// message envelope), or nil when no Praise marker is present.
    /// Fields are best-effort: badge from the badge Image altText (then
    /// card texts), sender from the marker line, recipient the line
    /// after the marker, note the remaining text.
    public static func mine(fromRaw raw: String?) -> PraisePost? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.localizedCaseInsensitiveContains(sentMarker) else { return nil }
        let texts = cardTexts(fromRaw: raw)
        guard let markerIndex = texts.firstIndex(where: { $0.localizedCaseInsensitiveContains(sentMarker) }) else {
            return nil
        }
        let marker = texts[markerIndex]
        let sender = senderName(fromMarker: marker)
        let recipient = markerIndex + 1 < texts.count ? texts[markerIndex + 1] : ""
        let note = markerIndex + 2 < texts.count ? texts[(markerIndex + 2)...].joined(separator: "\n") : ""
        return PraisePost(badge: badge(in: texts, raw: raw), sender: sender,
                          recipient: recipient, note: note)
    }

    /// Ordered TextBlock strings of the praise card (depth-first, one
    /// nesting level — same shallow shape as `AdaptiveCard`).
    static func cardTexts(fromRaw raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let card = praiseCardObject(from: json)
        else { return [] }
        var out: [String] = []
        collectTexts(card["body"], into: &out)
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The card object inside an envelope (attachments array, bare
    /// card, or message envelope).
    static func praiseCardObject(from json: [String: Any]) -> [String: Any]? {
        if let type_ = json["type"] as? String, type_.caseInsensitiveCompare("AdaptiveCard") == .orderedSame {
            return json
        }
        if let atts = json["attachments"] as? [[String: Any]] {
            for a in atts {
                let ct = (a["contentType"] as? String) ?? ""
                guard ct.caseInsensitiveCompare(adaptiveContentType) == .orderedSame else { continue }
                if let content = a["content"] as? [String: Any] { return content }
                if let s = a["content"] as? String,
                   let d = s.data(using: .utf8),
                   let content = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                {
                    return content
                }
            }
        }
        return nil
    }

    /// Depth-first TextBlock collection: ColumnSet columns and
    /// Container/Column items, one nesting level each.
    static func collectTexts(_ node: Any?, into out: inout [String]) {
        guard let items = node as? [[String: Any]] else { return }
        for item in items {
            let type_ = (item["type"] as? String) ?? ""
            if type_.caseInsensitiveCompare("TextBlock") == .orderedSame,
               let text = item["text"] as? String
            {
                out.append(text)
            } else if type_.caseInsensitiveCompare("ColumnSet") == .orderedSame {
                for col in (item["columns"] as? [[String: Any]]) ?? [] {
                    collectTexts(col["items"], into: &out)
                }
            } else if type_.caseInsensitiveCompare("Container") == .orderedSame ||
                type_.caseInsensitiveCompare("Column") == .orderedSame
            {
                collectTexts(item["items"], into: &out)
            }
        }
    }

    /// "Matti Paukkonen sent praise to" -> "Matti Paukkonen".
    static func senderName(fromMarker marker: String) -> String {
        guard let r = marker.range(of: sentMarker, options: .caseInsensitive) else { return "" }
        return String(marker[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Badge: badge Image altText first (the real layout), then any
    /// card text naming a badge.
    static func badge(in texts: [String], raw: String) -> PraiseBadge? {
        if let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let card = praiseCardObject(from: json)
        {
            var alts: [String] = []
            collectAltTexts(card["body"], into: &alts)
            for alt in alts {
                if let b = PraiseBadge(wireToken: alt) { return b }
            }
        }
        for text in texts {
            if let b = PraiseBadge(wireToken: text) { return b }
            for badge in PraiseBadge.allCases where text.localizedCaseInsensitiveContains(badge.displayName) {
                return badge
            }
        }
        return nil
    }

    /// Depth-first Image altText collection (same shallow shape).
    static func collectAltTexts(_ node: Any?, into out: inout [String]) {
        guard let items = node as? [[String: Any]] else { return }
        for item in items {
            let type_ = (item["type"] as? String) ?? ""
            if type_.caseInsensitiveCompare("Image") == .orderedSame,
               let alt = item["altText"] as? String, !alt.isEmpty
            {
                out.append(alt)
            } else if type_.caseInsensitiveCompare("ColumnSet") == .orderedSame {
                for col in (item["columns"] as? [[String: Any]]) ?? [] {
                    collectAltTexts(col["items"], into: &out)
                }
            } else if type_.caseInsensitiveCompare("Container") == .orderedSame ||
                type_.caseInsensitiveCompare("Column") == .orderedSame
            {
                collectAltTexts(item["items"], into: &out)
            }
        }
    }

    // MARK: - outgoing shape

    /// The Adaptive Card object for one Praise post (wire-exact: the
    /// same object the Rust `praise_card_content` builder emits, so
    /// both sides mine and render identically).
    public static func card(badge: PraiseBadge, recipient: String, note: String,
                            sender: String) -> [String: Any] {
        [
            "type": "AdaptiveCard",
            "version": "1.0",
            "body": [[
                "type": "ColumnSet",
                "spacing": "large",
                "separator": true,
                "columns": [
                    ["type": "Column", "width": "auto", "items": [[
                        "type": "TextBlock", "text": badge.displayName,
                        "weight": "bolder", "size": "large", "horizontalAlignment": "center",
                    ]]],
                    ["type": "Column", "width": "stretch", "spacing": "medium", "items": [
                        ["type": "TextBlock", "wrap": true, "size": "small", "isSubtle": true,
                         "text": "\(sender) sent praise to"],
                        ["type": "TextBlock", "wrap": true, "spacing": "small",
                         "weight": "bolder", "size": "medium", "text": recipient],
                        ["type": "TextBlock", "spacing": "small", "wrap": true, "text": note],
                    ]],
                ],
            ]],
        ]
    }

    /// POST body pieces for one Praise send (mirrors the Rust
    /// `praise_message_body` shape, pinned here for the optimistic
    /// bubble and for tests): HTML content naming the attachment id,
    /// one Adaptive Card attachment carrying the card.
    /// Returns a JSON-compatible dictionary:
    /// `contentType`, `content`,
    /// `attachments: {id, contentType, content: card}`.
    public static func envelope(badge: PraiseBadge, recipient: String, note: String,
                                sender: String, attachmentID: String) -> [String: Any] {
        [
            "contentType": "html",
            "content": "<attachment id=\"\(attachmentID)\"></attachment>",
            "attachments": [
                "id": attachmentID,
                "contentType": adaptiveContentType,
                "appID": appID,
                "content": card(badge: badge, recipient: recipient, note: note, sender: sender),
            ] as [String: Any],
        ]
    }

    /// The miner-readable envelope JSON for one Praise post (the shape
    /// the optimistic bubble stores as its raw payload).
    public static func envelopeJSON(badge: PraiseBadge, recipient: String, note: String,
                                    sender: String, attachmentID: String) -> String? {
        let env = envelope(badge: badge, recipient: recipient, note: note,
                           sender: sender, attachmentID: attachmentID)
        guard let atts = env["attachments"] else { return nil }
        return (try? JSONSerialization.data(withJSONObject: ["attachments": [atts]], options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Suggested recipient: the other conversation's latest speaker
    /// (the 1:1 peer), or "" when nobody else has spoken.
    public static func suggestRecipient(messages: [ChatMessage], ownName: String?) -> String {
        messages.last { !$0.isOwn && $0.sender != ownName && !$0.sender.isEmpty }?.sender ?? ""
    }
}
