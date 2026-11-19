// AdaptiveCard.swift — om-jc-cards lane: Adaptive Card renderer core;
// ADAPTIVE-ACTIONS lane: Submit/ShowCard/ToggleVisibility adopted.
//
// Model: shallow parse of the Adaptive Card elements Teams bots post
// (TextBlock / FactSet / Image / Container / ColumnSet, one nesting
// level) plus adopted actions: Action.OpenUrl (http(s) buttons),
// Action.Submit (parsed with its data, rendered disabled — no bot
// reply channel exists in this build), Action.ShowCard (inline nested
// card, one level), Action.ToggleVisibility (client-side; targets must
// resolve to a rendered element id). Execute, inputs, and unknown
// actions are OUT of scope: cards carrying them set `needsFallback`
// and the bubble keeps the BotPostRows fallback row alongside the
// rendered card. Cards whose action data identifies an approval carry
// `approval` for the hub deep-link.
//
// Entry: `AdaptiveCard.cards(fromRaw:)` mines card JSON from the same
// `raw ?? content` string the posts path reads. Shapes (all real):
//   - bare card: {"type":"AdaptiveCard","body":[...],"actions":[...]}
//   - attachment envelope: {"contentType":"...card.adaptive","content":{...}}
//   - message envelope: {"attachments":[{...envelope...}]}
import Foundation
import Combine

/// One parsed Adaptive Card. Shallow: containers/columns nest one
/// level (deeper elements drop); inputs never parse (fallback signal).
public struct AdaptiveCard: Sendable, Equatable {
    // MARK: - Elements

    public struct TextBlock: Sendable, Equatable {
        public enum Size: String, Sendable { case small, `default`, medium, large, extraLarge }
        public enum Weight: String, Sendable { case lighter, `default`, bolder }
        public enum Color: String, Sendable {
            case `default`, dark, light, accent, good, attention, warning
        }

        public let text: String
        public let size: Size
        public let weight: Weight
        public let color: Color
        public let isSubtle: Bool
        public let wrap: Bool
        /// Element id (ToggleVisibility targets; "" when absent).
        public let id: String

        public init(
            text: String, size: Size = .default, weight: Weight = .default,
            color: Color = .default, isSubtle: Bool = false, wrap: Bool = false,
            id: String = ""
        ) {
            self.text = text
            self.size = size
            self.weight = weight
            self.color = color
            self.isSubtle = isSubtle
            self.wrap = wrap
            self.id = id
        }
    }

    public struct Fact: Sendable, Equatable {
        public let title: String
        public let value: String
        public init(title: String, value: String) {
            self.title = title
            self.value = value
        }
    }

    public struct FactSet: Sendable, Equatable {
        public let id: String
        public let facts: [Fact]
        public init(id: String = "", facts: [Fact]) {
            self.id = id
            self.facts = facts
        }
    }

    public struct CardImage: Sendable, Equatable {
        public let url: String
        public let altText: String
        /// Element id (ToggleVisibility targets; "" when absent).
        public let id: String
        public init(url: String, altText: String = "", id: String = "") {
            self.url = url
            self.altText = altText
            self.id = id
        }
    }

    public struct CardContainer: Sendable, Equatable {
        public let id: String
        public let items: [Element]
        public init(id: String = "", items: [Element]) {
            self.id = id
            self.items = items
        }
    }

    public struct CardColumns: Sendable, Equatable {
        public let id: String
        public let columns: [[Element]]
        public init(id: String = "", columns: [[Element]]) {
            self.id = id
            self.columns = columns
        }
    }

    public enum Element: Sendable, Equatable {
        case text(TextBlock)
        case facts(FactSet)
        case image(CardImage)
        /// Shallow container: leaves only (no nested containers).
        case container(CardContainer)
        /// Shallow column set: each column holds leaves only.
        case columns(CardColumns)
    }

    public struct OpenURLAction: Sendable, Equatable {
        public let title: String
        public let url: String
        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }
    }

    /// Adopted Submit: title + string-valued `data` pairs (approval ids
    /// are strings; numbers/bools/nesting drop — the payload posts
    /// nowhere, so nothing is lost). Rendered disabled (no bot reply
    /// channel); see `submitDisabledReason`.
    public struct SubmitAction: Sendable, Equatable {
        public let title: String
        public let data: [String: String]
        public init(title: String, data: [String: String] = [:]) {
            self.title = title
            self.data = data
        }
    }

    /// Adopted ShowCard: title + the nested card (one level; deeper
    /// ShowCards fall back). Renders as inline expansion.
    public struct ShowCardAction: Sendable, Equatable {
        public let title: String
        public let card: AdaptiveCard
        public init(title: String, card: AdaptiveCard) {
            self.title = title
            self.card = card
        }
    }

    /// One ToggleVisibility target: the element id plus an absolute
    /// `isVisible` (nil = flip the current state).
    public struct ToggleTarget: Sendable, Equatable {
        public let elementId: String
        public let isVisible: Bool?
        public init(elementId: String, isVisible: Bool? = nil) {
            self.elementId = elementId
            self.isVisible = isVisible
        }
    }

    /// Adopted ToggleVisibility: title + targets (≥1 must resolve to a
    /// rendered element id, else the button is dropped — a button that
    /// flips nothing would be fake — and the card marks fallback).
    public struct ToggleVisibilityAction: Sendable, Equatable {
        public let title: String
        public let targets: [ToggleTarget]
        public init(title: String, targets: [ToggleTarget]) {
            self.title = title
            self.targets = targets
        }
    }

    /// Adopted actions, in payload order. Execute/unknown never appear
    /// here (fallback signal instead).
    public enum CardAction: Sendable, Equatable {
        case openURL(OpenURLAction)
        case submit(SubmitAction)
        indirect case showCard(ShowCardAction)
        case toggle(ToggleVisibilityAction)

        public var title: String {
            switch self {
            case .openURL(let a): return a.title
            case .submit(let a): return a.title
            case .showCard(let a): return a.title
            case .toggle(let a): return a.title
            }
        }

        public var isSubmit: Bool {
            if case .submit = self { return true }
            return false
        }
    }

    /// Hub deep-link for approval-identified cards (an action `data` id
    /// key). The approvals hub is the one channel that exists.
    public struct ApprovalLink: Sendable, Equatable {
        public let id: String
        public init(id: String) {
            self.id = id
        }
    }

    public let body: [Element]
    public let actions: [CardAction]
    /// Set when an action's data identifies an approval (Submit data
    /// adopted, Execute data fallback — both route to the hub).
    public let approval: ApprovalLink?
    /// True when the payload carried Execute/inputs/unknown actions (or
    /// unhonorable adopted shapes): the bubble keeps the fallback
    /// BotPostRows row too.
    public let needsFallback: Bool

    public init(
        body: [Element], actions: [CardAction] = [],
        approval: ApprovalLink? = nil, needsFallback: Bool = false
    ) {
        self.body = body
        self.actions = actions
        self.approval = approval
        self.needsFallback = needsFallback
    }

    /// Honest reason on every Submit button (help + caption): posting an
    /// action payload needs the bot reply channel (Bot Framework invoke
    /// / value post), which this build doesn't have. Guards pin this.
    public static let submitDisabledReason =
        "Submit needs the bot reply channel, which this build doesn't have yet."

    /// Hub deep-link for approval-identified cards (`app/approvals/<id>`).
    public var approvalRoute: String? {
        approval.map { "app/approvals/\($0.id)" }
    }

    // MARK: - Caps (hostile-blob bounds, same spirit as maxBotRows)

    static let maxBody = 20
    static let maxFacts = 20
    static let maxActions = 6
    static let maxColumns = 6
    static let maxText = 2000
    static let maxDataPairs = 20
    static let maxDataKey = 64
    static let maxDataValue = 500
    static let maxToggleTargets = 10
    static let maxElementID = 128
    static let maxApprovalID = 200
    static let maxShowCardDepth = 1

    /// Lowercased `data` keys whose string value identifies an approval
    /// (best-effort: no live approval-card sample exists yet — the trial
    /// approval GET 401s without admin consent — so the live shape stays
    /// part of the live gap; see REPORT).
    static let approvalIDKeys: Set<String> = [
        "approvalid", "approvalitemid", "flowapprovalid",
        "approval_id", "msdyn_flow_approval",
    ]

    /// Teams/Graph content type for an Adaptive Card attachment.
    static let adaptiveContentType = "application/vnd.microsoft.card.adaptive"

    // MARK: - Mining

    /// Cards for one message: envelope shapes unwrapped to bare card
    /// objects, each parsed shallow. Anything else yields no cards.
    /// Memoized per raw payload (om-perf-swift-render): the bubble
    /// parses each message once per content change instead of 2-3x
    /// per body-eval (cards + fallback gating + placeholder check).
    public static func cards(fromRaw raw: String?) -> [AdaptiveCard] {
        guard let raw else { return [] }
        cardsLock.lock()
        if let hit = cardsCache[raw] {
            cardsLock.unlock()
            return hit
        }
        cardsLock.unlock()
        let out = cardsUncached(fromRaw: raw)
        cardsLock.lock()
        cardsComputes += 1
        if cardsCache.count >= maxCardCacheEntries { cardsCache.removeAll() }
        cardsCache[raw] = out
        cardsLock.unlock()
        return out
    }

    static func cardsUncached(fromRaw raw: String) -> [AdaptiveCard] {
        guard MessageRender.looksLikeJSONObject(raw),
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        return cardObjects(from: json).compactMap { parse(card: $0) }.prefix(10).map { $0 }
    }

    static let maxCardCacheEntries = 1000
    private static let cardsLock = NSLock()
    private static var cardsCache: [String: [AdaptiveCard]] = [:]

    /// Actual parses, excluding cache hits (perf-guard tests only).
    static var cardsComputes = 0

    /// Drop the cached parses + zero the counter (tests only).
    static func resetCardsCache() {
        cardsLock.lock()
        defer { cardsLock.unlock() }
        cardsCache.removeAll()
        cardsComputes = 0
    }

    /// Bare card dicts from any envelope shape: message envelope
    /// attachments[], single attachment envelope content, or the
    /// object itself when it already is a card.
    static func cardObjects(from json: Any) -> [Any] {
        if let top = json as? [String: Any] {
            if let attachments = top["attachments"] as? [Any] {
                return attachments.compactMap { attachmentContent($0) }
            }
            if let content = attachmentContent(json) { return [content] }
            if isCardObject(top) { return [top] }
            return []
        }
        return []
    }

    /// The card object inside one attachment envelope, or nil when the
    /// content type is not adaptive (foreign attachments stay out).
    static func attachmentContent(_ value: Any) -> Any? {
        guard let obj = value as? [String: Any],
              let type = obj["contentType"] as? String,
              type.lowercased() == adaptiveContentType,
              let content = obj["content"]
        else { return nil }
        return content
    }

    static func isCardObject(_ obj: [String: Any]) -> Bool {
        (obj["type"] as? String)?.lowercased() == "adaptivecard"
    }

    // MARK: - Parse

    /// One bare card object -> model. Nil when nothing renderable
    /// parsed (the bubble placeholder owns such payloads). `depth` is
    /// the ShowCard nesting level (top card 0; deeper ShowCards fall back).
    static func parse(card value: Any, depth: Int = 0) -> AdaptiveCard? {
        guard let obj = value as? [String: Any], isCardObject(obj) else { return nil }
        var fallback = false
        let body = ((obj["body"] as? [Any]) ?? []).prefix(maxBody).compactMap {
            parseElement($0, nested: false, fallback: &fallback)
        }
        var actions: [CardAction] = []
        var approval: ApprovalLink?
        for raw in ((obj["actions"] as? [Any]) ?? []).prefix(maxActions) {
            parseAction(raw, actions: &actions, fallback: &fallback, depth: depth, approval: &approval)
        }
        // ActionSet elements may carry actions too (shallow).
        for raw in ((obj["body"] as? [Any]) ?? []).prefix(maxBody) {
            if let el = raw as? [String: Any],
               (el["type"] as? String)?.lowercased() == "actionset"
            {
                for sub in ((el["actions"] as? [Any]) ?? []).prefix(maxActions) {
                    parseAction(sub, actions: &actions, fallback: &fallback, depth: depth, approval: &approval)
                }
            }
        }
        // Toggle targets must resolve to a rendered element id in this
        // card's own scope: an all-miss toggle renders no button (a
        // button that flips nothing would be fake) and marks fallback
        // so Teams still owns the interaction.
        let ids = elementIDs(in: body)
        actions = actions.filter {
            guard case .toggle(let t) = $0 else { return true }
            let ok = t.targets.contains { ids.contains($0.elementId) }
            if !ok { fallback = true }
            return ok
        }
        guard !body.isEmpty || !actions.isEmpty else { return nil }
        return AdaptiveCard(body: body, actions: actions, approval: approval, needsFallback: fallback)
    }

    /// Every rendered element id in one body (own scope: a nested
    /// ShowCard resolves its own toggles against its own body).
    static func elementIDs(in body: [Element]) -> Set<String> {
        var out = Set<String>()
        func walk(_ el: Element) {
            switch el {
            case .text(let t):
                if !t.id.isEmpty { out.insert(t.id) }
            case .facts(let s):
                if !s.id.isEmpty { out.insert(s.id) }
            case .image(let i):
                if !i.id.isEmpty { out.insert(i.id) }
            case .container(let c):
                if !c.id.isEmpty { out.insert(c.id) }
                c.items.forEach(walk)
            case .columns(let c):
                if !c.id.isEmpty { out.insert(c.id) }
                c.columns.forEach { $0.forEach(walk) }
            }
        }
        body.forEach(walk)
        return out
    }

    /// One body element. Nested (inside Container/Column): leaves only;
    /// deeper containers/sets drop. Input.* marks fallback, never parses.
    static func parseElement(_ value: Any, nested: Bool, fallback: inout Bool) -> Element? {
        guard let obj = value as? [String: Any],
              let type = (obj["type"] as? String)?.lowercased()
        else { return nil }
        switch type {
        case "textblock":
            guard let text = nonEmptyString(obj["text"]) else { return nil }
            return .text(TextBlock(
                text: String(text.prefix(maxText)),
                size: size(of: obj), weight: weight(of: obj),
                color: color(of: obj),
                isSubtle: obj["isSubtle"] as? Bool ?? false,
                wrap: obj["wrap"] as? Bool ?? false,
                id: elementID(obj)))
        case "image":
            guard let url = nonEmptyString(obj["url"]) else { return nil }
            return .image(CardImage(
                url: url, altText: (obj["altText"] as? String ?? ""),
                id: elementID(obj)))
        case "factset":
            let facts = ((obj["facts"] as? [Any]) ?? []).prefix(maxFacts).compactMap { raw -> Fact? in
                guard let f = raw as? [String: Any],
                      let title = nonEmptyString(f["title"]),
                      let value = nonEmptyString(f["value"])
                else { return nil }
                return Fact(
                    title: String(title.prefix(maxText)),
                    value: String(value.prefix(maxText)))
            }
            return facts.isEmpty ? nil : .facts(FactSet(id: elementID(obj), facts: facts))
        case "container":
            guard !nested else { return nil }
            let items = ((obj["items"] as? [Any]) ?? []).prefix(maxBody).compactMap {
                parseElement($0, nested: true, fallback: &fallback)
            }
            return .container(CardContainer(id: elementID(obj), items: items))
        case "columnset":
            guard !nested else { return nil }
            let cols = ((obj["columns"] as? [Any]) ?? []).prefix(maxColumns).map { raw -> [Element] in
                guard let col = raw as? [String: Any] else { return [] }
                return ((col["items"] as? [Any]) ?? []).prefix(maxBody).compactMap {
                    parseElement($0, nested: true, fallback: &fallback)
                }
            }
            return .columns(CardColumns(id: elementID(obj), columns: cols))
        case "actionset":
            // Actions mined in parse(card:); no body element.
            return nil
        default:
            // Input.* and every unknown element: fallback signal.
            fallback = true
            return nil
        }
    }

    /// One action dict. Adopted: OpenUrl (http(s)), Submit (+data),
    /// ShowCard (nested card, depth-capped), ToggleVisibility (targets
    /// parsed; resolution against rendered ids happens in `parse`).
    /// Execute/unknown mark fallback; Execute data still mines an
    /// approval id (the hub owns what we can't fire).
    static func parseAction(
        _ value: Any, actions: inout [CardAction],
        fallback: inout Bool, depth: Int, approval: inout ApprovalLink?
    ) {
        guard let obj = value as? [String: Any],
              let type = (obj["type"] as? String)?.lowercased()
        else { return }
        switch type {
        case "action.openurl":
            guard let url = nonEmptyString(obj["url"] ?? obj["uri"]),
                  AdaptiveCard.linkTarget(for: url) != nil
            else { return }
            let title = nonEmptyString(obj["title"]) ?? url
            actions.append(.openURL(OpenURLAction(
                title: String(title.prefix(140)), url: url)))
        case "action.submit":
            let title = nonEmptyString(obj["title"]) ?? "Submit"
            mineApproval(from: obj["data"], approval: &approval)
            actions.append(.submit(SubmitAction(
                title: String(title.prefix(140)),
                data: stringPairs(obj["data"]))))
        case "action.showcard":
            guard depth < maxShowCardDepth,
                  let raw = obj["card"],
                  let nested = parse(card: raw, depth: depth + 1)
            else { fallback = true; return }
            let title = nonEmptyString(obj["title"]) ?? "Details"
            if nested.needsFallback { fallback = true }
            if approval == nil { approval = nested.approval }
            actions.append(.showCard(ShowCardAction(
                title: String(title.prefix(140)), card: nested)))
        case "action.togglevisibility":
            let targets = toggleTargets(obj["targetElements"])
            guard !targets.isEmpty else { fallback = true; return }
            let title = nonEmptyString(obj["title"]) ?? "Show / hide"
            actions.append(.toggle(ToggleVisibilityAction(
                title: String(title.prefix(140)), targets: targets)))
        case "action.execute":
            mineApproval(from: obj["data"], approval: &approval)
            fallback = true
        default:
            fallback = true
        }
    }

    /// String-valued `data` pairs (approval ids are strings;
    /// numbers/bools/nesting drop — the payload posts nowhere, so
    /// nothing is lost). Capped; hostile blobs can't grow the model.
    static func stringPairs(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict.prefix(maxDataPairs) {
            guard let s = v as? String,
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            out[String(k.prefix(maxDataKey))] = String(s.prefix(maxDataValue))
        }
        return out
    }

    /// Approval id from one action's `data` (Submit adopted, Execute
    /// fallback — both identify the hub item). First id-keyed non-empty
    /// string wins; route-unsafe ids (/, ?, whitespace) never mine.
    static func mineApproval(from data: Any?, approval: inout ApprovalLink?) {
        guard approval == nil,
              let dict = data as? [String: Any]
        else { return }
        for (k, v) in dict {
            guard approvalIDKeys.contains(k.lowercased()),
                  let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, s.count <= maxApprovalID,
                  s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !s.contains("/"), !s.contains("?")
            else { continue }
            approval = ApprovalLink(id: s)
            return
        }
    }

    /// ToggleVisibility targets: `["id"]` strings and/or
    /// `[{"elementId":"id","isVisible":bool}]` objects (both real
    /// shapes). Empty ids drop; zero valid targets = unparseable.
    static func toggleTargets(_ value: Any?) -> [ToggleTarget] {
        // Liberal: a lone string target (out-of-spec but unambiguous).
        guard let raw = value as? [Any] else {
            guard let s = nonEmptyString(value) else { return [] }
            return [ToggleTarget(elementId: String(s.prefix(maxElementID)))]
        }
        var out: [ToggleTarget] = []
        for t in raw.prefix(maxToggleTargets) {
            if let s = t as? String, let id = nonEmptyString(s) {
                out.append(ToggleTarget(elementId: String(id.prefix(maxElementID))))
            } else if let o = t as? [String: Any],
                      let id = nonEmptyString(o["elementId"])
            {
                out.append(ToggleTarget(
                    elementId: String(id.prefix(maxElementID)),
                    isVisible: o["isVisible"] as? Bool))
            }
        }
        return out
    }

    /// One element's `id` (ToggleVisibility scope; "" when absent).
    static func elementID(_ obj: [String: Any]) -> String {
        guard let s = nonEmptyString(obj["id"]) else { return "" }
        return String(s.prefix(maxElementID))
    }

    /// http(s)-only link target (nil for any other scheme).
    public static func linkTarget(for raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    // MARK: - Field readers

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !s.isEmpty
        else { return nil }
        return s
    }

    static func size(of obj: [String: Any]) -> TextBlock.Size {
        switch (obj["size"] as? String)?.lowercased() {
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "extralarge": return .extraLarge
        default: return .default
        }
    }

    static func weight(of obj: [String: Any]) -> TextBlock.Weight {
        switch (obj["weight"] as? String)?.lowercased() {
        case "lighter": return .lighter
        case "bolder": return .bolder
        default: return .default
        }
    }

    static func color(of obj: [String: Any]) -> TextBlock.Color {
        switch (obj["color"] as? String)?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        case "accent": return .accent
        case "good": return .good
        case "attention": return .attention
        case "warning": return .warning
        default: return .default
        }
    }

    // MARK: - Copy text

    /// Plain lines for Copy: text blocks, `title — value` fact rows,
    /// image alts, and action lines (OpenUrl `title — url`, Submit with
    /// its unavailable note, ShowCard title + nested lines, toggle
    /// title). No raw JSON.
    public var copyLines: [String] {
        var out: [String] = []
        for el in body { appendCopy(of: el, to: &out) }
        for a in actions {
            switch a {
            case .openURL(let u): out.append("\(u.title) — \(u.url)")
            case .submit(let s): out.append("\(s.title) — submit unavailable in this build")
            case .showCard(let s):
                out.append(s.title)
                for line in s.card.copyLines { out.append(line) }
            case .toggle(let t): out.append(t.title)
            }
        }
        return out
    }

    private func appendCopy(of el: Element, to out: inout [String]) {
        switch el {
        case let .text(t): out.append(t.text)
        case let .facts(set):
            for f in set.facts { out.append("\(f.title) — \(f.value)") }
        case let .image(img):
            out.append(img.altText.isEmpty ? img.url : img.altText)
        case let .container(c):
            for i in c.items { appendCopy(of: i, to: &out) }
        case let .columns(c):
            for col in c.columns { for i in col { appendCopy(of: i, to: &out) } }
        }
    }
}

/// Bubble posts-path gating (pure, testable): cards render when any
/// parse; fallback rows render when posts exist AND (no cards, or some
/// card needs fallback for its Submit/inputs/Execute surface).
public enum MessageBubbleState {
    public static func cards(for message: ChatMessage) -> [AdaptiveCard] {
        AdaptiveCard.cards(fromRaw: message.raw ?? message.content)
    }

    public static func shouldShowCards(for message: ChatMessage) -> Bool {
        !cards(for: message).isEmpty
    }

    public static func shouldShowFallbackRows(for message: ChatMessage) -> Bool {
        shouldShowFallbackRows(
            posts: MessageRender.botPosts(fromRaw: message.raw ?? message.content),
            cards: cards(for: message))
    }

    /// Gating over precomputed parses (om-perf-swift-render): callers
    /// that already hold `posts` + `cards` skip the re-parse entirely.
    /// Same truth table as `shouldShowFallbackRows(for:)`.
    public static func shouldShowFallbackRows(posts: [MessageRender.BotPost], cards: [AdaptiveCard]) -> Bool {
        guard !posts.isEmpty else { return false }
        return cards.isEmpty || cards.contains(where: \.needsFallback)
    }
}

