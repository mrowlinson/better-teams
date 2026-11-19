// LoopComponent.swift — Loop component mining + live gate (LOOPBUILD lane).
//
// A Teams Loop component is a chat message carrying `cards` JSON with a
// fluid card: contentType `application/vnd.microsoft.card.fluidEmbedCard`
// (Embed mode) or legacy `application/vnd.microsoft.card.fluid`
// (Collaborate mode), content.componentUrl holding the embed URL
// (mined reloop/REPORT.md §2.6 — first-party read is cards-JSON).
import Foundation

/// One mined Loop component: its embed URL + render mode.
public struct LoopEmbed: Sendable, Equatable {
    public let componentURL: String
    public let mode: LoopEmbedMode

    public init(componentURL: String, mode: LoopEmbedMode) {
        self.componentURL = componentURL
        self.mode = mode
    }

    /// Host of the component URL for the static card's subtitle.
    public var host: String {
        URL(string: componentURL)?.host ?? ""
    }
}

/// Render mode: Embed (fluidEmbedCard) or legacy Collaborate.
public enum LoopEmbedMode: String, Sendable, Equatable {
    case embed
    case collaborate
}

/// Component kinds Teams' composer offers (mined
/// `composeEnabledComponents`, reloop/REPORT.md §2.8).
public struct LoopComponentKind: Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let symbol: String

    public init(id: String, displayName: String, symbol: String) {
        self.id = id
        self.displayName = displayName
        self.symbol = symbol
    }
}

public enum LoopComponent {
    /// Embed-mode card content type (mined read path).
    public static let embedContentType = "application/vnd.microsoft.card.fluidEmbedCard"
    /// Legacy Collaborate-mode card content type (mined read path).
    public static let legacyContentType = "application/vnd.microsoft.card.fluid"

    /// The 11 composer component kinds (mined order).
    public static let kinds: [LoopComponentKind] = [
        LoopComponentKind(id: "bulletedList", displayName: "Bulleted list", symbol: "list.bullet"),
        LoopComponentKind(id: "checklist", displayName: "Checklist", symbol: "checkmark.square"),
        LoopComponentKind(id: "FFX-KanbanBoard", displayName: "Kanban board", symbol: "square.grid.2x2"),
        LoopComponentKind(id: "numberedList", displayName: "Numbered list", symbol: "list.number"),
        LoopComponentKind(id: "paragraph", displayName: "Paragraph", symbol: "paragraphsign"),
        LoopComponentKind(id: "FFX-ProgressTracker", displayName: "Progress tracker", symbol: "chart.bar"),
        LoopComponentKind(id: "questionAnswer", displayName: "Q&A", symbol: "questionmark.circle"),
        LoopComponentKind(id: "FFX-RetroBoard", displayName: "Retro board", symbol: "rectangle.3.group"),
        LoopComponentKind(id: "table", displayName: "Table", symbol: "tablecells"),
        LoopComponentKind(id: "votingTable", displayName: "Voting table", symbol: "hand.thumbsup"),
        LoopComponentKind(id: "actionItems", displayName: "Action items", symbol: "bolt.circle"),
    ]

    // MARK: - mining

    /// All Loop embeds in `cards` (wire string form or a bare
    /// array/object), in wire order; [] when none or unparseable.
    public static func mine(fromCards cards: String?) -> [LoopEmbed] {
        guard let cards, !cards.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = cards.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let arr: [[String: Any]]
        if let a = json as? [[String: Any]] {
            arr = a
        } else if let o = json as? [String: Any] {
            arr = [o]
        } else {
            return []
        }
        return arr.compactMap { card in
            let ct = ((card["contentType"] as? String) ?? "")
            let mode: LoopEmbedMode
            if ct.caseInsensitiveCompare(embedContentType) == .orderedSame {
                mode = .embed
            } else if ct.caseInsensitiveCompare(legacyContentType) == .orderedSame {
                mode = .collaborate
            } else {
                return nil
            }
            guard let content = card["content"] as? [String: Any],
                  let url = content["componentUrl"] as? String, !url.isEmpty
            else { return nil }
            return LoopEmbed(componentURL: url, mode: mode)
        }
    }

    /// First embed in `cards` (the timeline renders one card per
    /// message), or nil when the message carries no Loop card.
    public static func first(fromCards cards: String?) -> LoopEmbed? {
        mine(fromCards: cards).first
    }

    /// `cards` JSON for one component URL (E1 shape — mirrors
    /// `ost::api::embed_cards_json`; the core's shapes call is the
    /// pinned source, this builds optimistic/evidence bubbles).
    public static func cardsJSON(componentURL: String) -> String {
        let card: [[String: Any]] = [[
            "contentType": embedContentType,
            "content": ["componentUrl": componentURL],
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }

    /// S1 read coords parsed from a component URL: the host comes
    /// from the URL itself, drive/item from the `?nav=` payload
    /// (`d=`/`f=`). Nil when the URL has no usable nav.
    public static func readCoords(componentURL: String) -> (host: String, drive: String, item: String)? {
        guard let url = URL(string: componentURL),
              let host = url.host, !host.isEmpty,
              let items = URLComponents(string: componentURL)?.queryItems,
              let nav = items.first(where: { $0.name == "nav" })?.value,
              let data = Data(base64Encoded: nav),
              let payload = String(data: data, encoding: .utf8)
        else { return nil }
        var parts: [String: String] = [:]
        for kv in payload.split(separator: "&") {
            let pair = kv.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0]] = pair[1].removingPercentEncoding ?? pair[1] }
        }
        guard let d = parts["d"], !d.isEmpty, let f = parts["f"], !f.isEmpty else { return nil }
        return (host, d, f)
    }
}

/// Live-sync gate state: ready, or disabled with the honest reason.
public enum LoopGateState: Sendable, Equatable {
    case ready
    case disabled(reason: String)
}

/// Live gate for Loop sync (create/send/read). The default probe
/// reports disabled: tenant auth is down for new grants and the
/// banned employer tenant is off-limits, so no grant can be proven
/// in this lane — phase 2 flips the probe after P2-1 proves
/// the Loop + site audiences. No fake probe traffic: a probe that
/// "checks" would burn the fragile token pool for an answer we
/// already know.
public enum LoopGate {
    public static let defaultReason =
        "Loop sync needs trial-tenant grants (phase 2 captures). The component link below still works."

    /// Injected probe (tests flip it; phase 2 wires the grant check).
    public static var probe: @Sendable () -> LoopGateState = {
        .disabled(reason: defaultReason)
    }

    public static var state: LoopGateState { probe() }

    /// True only when live traffic may go out.
    public static var isLive: Bool {
        if case .ready = state { return true }
        return false
    }
}
