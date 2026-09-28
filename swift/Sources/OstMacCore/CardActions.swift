// CardActions.swift — om-jd-cardactions lane: card action buttons +
// "Open in Teams" fallback, wired into the J-C card renderer.
//
// Adaptive `actions[]` / O365 `potentialAction[]` mine into OpenUrl
// buttons (safe locally: http(s) browser opens); Submit / Execute /
// inputs / message extensions / unknown actions collapse to ONE
// "Open in Teams" fallback row (Teams owns the interaction).
// Rendered cards show their rows inside AdaptiveCardView; the bubble
// keeps a decoupled CardActionRows block for non-card payloads only
// (no-op when empty).
//
// Deep-link probe: MS documents the MESSAGE form for channel threads
// (`/l/message/<channelId>/<messageId>?tenantId=…&groupId=…`) and the
// CHAT form (`/l/chat/<chatId>/conversations`); tenant/group ids are
// not plumbed in OstMac and no live Teams click was possible here, so
// the fallback stays on the https BROWSER form (never `msteams://` —
// unverified scheme could dead-end). Channel ids get the per-message
// path, chats the conversations path, missing ids the Teams home.
import Foundation
import Combine

/// One locally-openable card button: title + http(s) target.
public struct CardActionButton: Sendable, Equatable {
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

/// Mined card interactivity: OpenUrl buttons plus whether anything
/// needs Teams (Submit/Execute/inputs/extensions/unknown/custom-scheme).
public struct CardActionSet: Sendable, Equatable {
    public let openURLs: [CardActionButton]
    public let needsTeamsFallback: Bool

    public init(openURLs: [CardActionButton], needsTeamsFallback: Bool) {
        self.openURLs = openURLs
        self.needsTeamsFallback = needsTeamsFallback
    }

    /// No buttons and no fallback: the bubble renders nothing.
    public var isEmpty: Bool { openURLs.isEmpty && !needsTeamsFallback }

    public static let empty = CardActionSet(openURLs: [], needsTeamsFallback: false)
}

public enum CardActions {
    /// Max OpenUrl buttons per bubble (hostile-card cap, mirrors rows).
    public static let maxButtons = 5

    /// Teams web home: fallback when chat/message ids are missing.
    public static let teamsHomeURL = URL(string: "https://teams.microsoft.com")!

    /// Mine one message's card actions. `raw` is the server payload
    /// (`message.raw ?? message.content`); non-JSON input (attachment
    /// HTML, prose) yields `.empty` — bot-post rows already cover links.
    /// Memoized per raw payload (om-perf-swift-render): one JSON parse
    /// per content change instead of one per body-eval.
    public static func actions(fromRaw raw: String?) -> CardActionSet {
        guard let raw else { return .empty }
        actionsLock.lock()
        if let hit = actionsCache[raw] {
            actionsLock.unlock()
            return hit
        }
        actionsLock.unlock()
        let out = actionsUncached(fromRaw: raw)
        actionsLock.lock()
        actionsComputes += 1
        if actionsCache.count >= maxActionsCacheEntries { actionsCache.removeAll() }
        actionsCache[raw] = out
        actionsLock.unlock()
        return out
    }

    static func actionsUncached(fromRaw raw: String) -> CardActionSet {
        guard MessageRender.looksLikeJSONObject(raw),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return .empty }
        var buttons: [CardActionButton] = []
        var fallback = false
        for candidate in cardCandidates(from: json) {
            mine(candidate, depth: 8, buttons: &buttons, fallback: &fallback)
            if buttons.count >= maxButtons { break }
        }
        return CardActionSet(
            openURLs: Array(buttons.prefix(maxButtons)),
            needsTeamsFallback: fallback)
    }

    static let maxActionsCacheEntries = 1000
    private static let actionsLock = NSLock()
    private static var actionsCache: [String: CardActionSet] = [:]

    /// Actual mines, excluding cache hits (perf-guard tests only).
    static var actionsComputes = 0

    /// Drop the cached mines + zero the counter (tests only).
    static func resetActionsCache() {
        actionsLock.lock()
        defer { actionsLock.unlock() }
        actionsCache.removeAll()
        actionsComputes = 0
    }

    /// Top object plus each `attachments[]` element's `content`
    /// (Adaptive cards nest there — same shape as bot-post mining).
    static func cardCandidates(from json: Any) -> [Any] {
        var out: [Any] = [json]
        if let top = json as? [String: Any],
           let attachments = top["attachments"] as? [Any]
        {
            for a in attachments {
                if let dict = a as? [String: Any], let content = dict["content"] {
                    out.append(content)
                } else {
                    out.append(a)
                }
            }
        }
        return out
    }

    /// Walk one card body: `actions[]` (Adaptive), `potentialAction[]`
    /// (O365), `composeExtension` (message extension), `Input.*` (form
    /// inputs anywhere in `body`). Depth-capped; ShowCard recurses.
    static func mine(
        _ value: Any, depth: Int,
        buttons: inout [CardActionButton], fallback: inout Bool
    ) {
        guard depth > 0, buttons.count < maxButtons else { return }
        guard let dict = value as? [String: Any] else {
            if let array = value as? [Any] {
                for element in array {
                    mine(element, depth: depth - 1, buttons: &buttons, fallback: &fallback)
                }
            }
            return
        }
        if dict.keys.contains(where: { $0.lowercased() == "composeextension" }) {
            fallback = true
        }
        if let type = (dict["type"] as? String)?.lowercased(),
           type.hasPrefix("input.")
        {
            fallback = true
        }
        if let actions = dict["actions"] as? [Any] {
            for action in actions {
                mineAction(action, depth: depth - 1, buttons: &buttons, fallback: &fallback)
            }
        }
        if let potential = dict["potentialAction"] as? [Any] {
            for action in potential {
                minePotentialAction(action, buttons: &buttons, fallback: &fallback)
            }
        }
        // Inputs hide in body/columns/ShowCard cards: recurse into every
        // child value (actions re-mined idempotently: same buttons twice
        // only if the card repeats them, capped by maxButtons).
        for key in ["body", "columns", "items", "card", "content"] {
            if let child = dict[key] {
                mine(child, depth: depth - 1, buttons: &buttons, fallback: &fallback)
            }
        }
    }

    /// One Adaptive action: OpenUrl → button (http(s) only, else
    /// fallback); ToggleVisibility is inert locally (ignored);
    /// ShowCard recurses; everything else (Submit/Execute/unknown)
    /// needs Teams.
    static func mineAction(
        _ action: Any, depth: Int,
        buttons: inout [CardActionButton], fallback: inout Bool
    ) {
        guard let dict = action as? [String: Any] else { return }
        let type = ((dict["type"] as? String) ?? "").lowercased()
        switch type {
        case "action.openurl":
            if let s = dict["url"] as? String,
               let url = httpURL(from: s)
            {
                let title = ((dict["title"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buttons.append(CardActionButton(
                    title: title.isEmpty ? (url.host ?? s) : title, url: url))
            } else {
                fallback = true
            }
        case "action.showcard":
            if let card = dict["card"] {
                mine(card, depth: depth, buttons: &buttons, fallback: &fallback)
            }
        case "action.togglevisibility":
            break
        default:
            fallback = true
        }
    }

    /// One O365 potential action: OpenUri targets → button (first
    /// http(s) uri wins); HttpPOST/ActionCard/unknown need Teams.
    static func minePotentialAction(
        _ action: Any,
        buttons: inout [CardActionButton], fallback: inout Bool
    ) {
        guard let dict = action as? [String: Any] else { return }
        let type = ((dict["@type"] as? String) ?? "").lowercased()
        guard type == "openuri" else {
            fallback = true
            return
        }
        let name = ((dict["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let targets = dict["targets"] as? [Any] {
            for target in targets {
                if let t = target as? [String: Any],
                   let s = t["uri"] as? String,
                   let url = httpURL(from: s)
                {
                    buttons.append(CardActionButton(
                        title: name.isEmpty ? (url.host ?? s) : name, url: url))
                    return
                }
            }
        }
        fallback = true
    }

    /// Parsed http(s) URL, nil for anything else (same gate as rows).
    static func httpURL(from raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    /// "Open in Teams" target (browser form — see header): per-message
    /// path for channels, conversations path for chats, home when an
    /// id is missing. Tenant/group params omitted (not plumbed).
    public static func fallbackURL(chatID: String?, messageID: String) -> URL {
        guard let chat = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chat.isEmpty,
              !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let home = URL(string: "https://teams.microsoft.com")
        else { return teamsHomeURL }
        let path = isChannelID(chat)
            ? "/l/message/\(chat)/\(messageID)"
            : "/l/chat/\(chat)/conversations"
        return URL(string: path, relativeTo: home) ?? teamsHomeURL
    }

    /// Channel ids are `19:...@thread.tacv2` (ChannelTabsStore parity;
    /// local copy: that helper is MainActor-bound, this model is not).
    static func isChannelID(_ id: String) -> Bool {
        let t = id.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("19:") && t.hasSuffix("@thread.tacv2")
    }
}

