// SearchModel.swift — UI-only search state (UI-SPEC §5.5, §11.3).
//
// Navigator writes the query and scope (`setQuery`, R21); this model
// starts the store searches from that call (R24: never from a view),
// owns the result selection and the optional conversation scope (⌘F),
// and opens results. Result data stays in the core stores
// (`MessageSearchStore`, `FilePeopleSearchStore`); views observe them
// directly (R3, R28).
import Foundation
import Observation
import OstMacCore

/// One selectable search result (list tag and detail key).
public enum SearchResultID: Hashable, Sendable {
    case target(String)   // chat, channel or team (Top Hits)
    case message(String)  // SearchHit.id
    case person(String)   // TeamMember.id
    case file(String)     // SharedFile.id

    var tag: String {
        switch self {
        case .target(let id): "t:\(id)"
        case .message(let id): "m:\(id)"
        case .person(let id): "p:\(id)"
        case .file(let id): "f:\(id)"
        }
    }

    init?(tag: String) {
        guard tag.count > 2 else { return nil }
        let rest = String(tag.dropFirst(2))
        switch tag.prefix(2) {
        case "t:": self = .target(rest)
        case "m:": self = .message(rest)
        case "p:": self = .person(rest)
        case "f:": self = .file(rest)
        default: return nil
        }
    }
}

/// The conversation ⌘F scopes a search to (§5.5).
public struct SearchConversationScope: Equatable, Sendable {
    public let id: String
    public let name: String
}

/// Which result sections a scope shows and how many rows each (pure,
/// unit-tested). `nil` = no cap.
public struct SearchSectionPlan: Equatable, Sendable {
    public var topHits: Int?
    public var messages: Int?
    public var people: Int?
    public var files: Int?

    static let hidden = 0

    public static func plan(_ scope: SearchScope, inConversation: Bool) -> SearchSectionPlan {
        if inConversation { return SearchSectionPlan(topHits: hidden, messages: nil, people: hidden, files: hidden) }
        switch scope {
        case .all: return SearchSectionPlan(topHits: 5, messages: 5, people: 3, files: 3)
        case .messages: return SearchSectionPlan(topHits: hidden, messages: nil, people: hidden, files: hidden)
        case .people: return SearchSectionPlan(topHits: hidden, messages: hidden, people: nil, files: hidden)
        case .files: return SearchSectionPlan(topHits: hidden, messages: hidden, people: hidden, files: nil)
        }
    }

    static func take<T>(_ rows: [T], _ cap: Int?) -> [T] {
        guard let cap else { return rows }
        return Array(rows.prefix(cap))
    }
}

@Observable
@MainActor
public final class SearchModel {
    public private(set) var query = ""
    public private(set) var scope: SearchScope = .all
    /// ⌘F: the conversation the next search is limited to (§5.5).
    public private(set) var conversation: SearchConversationScope?
    /// True while the conversation scope is the active segment.
    public private(set) var inConversation = false
    /// Selected result (UI-only; cleared on every new query).
    public private(set) var selected: SearchResultID?
    /// ⌘F find: every on-device message of the scoped conversation that
    /// matches the query (case- and diacritic-insensitive), merged with
    /// the server hits in that conversation.
    private(set) var findHits: [SearchHit] = []
    /// Evidence: result to select once rows arrive (`search?…&result=`).
    @ObservationIgnored private var pendingResult: Int?
    /// Evidence: key to press once rows arrive (`then=open` = Return on
    /// the selected/top result; `then=esc` = Esc).
    @ObservationIgnored private var pendingAction: String?
    @ObservationIgnored weak var window: WindowModel?

    public init() {}

    // MARK: Navigator-driven (R21)

    func setQuery(_ q: String, scope s: SearchScope) {
        if q.isEmpty {
            reset()
            return
        }
        let changed = query != q
        if changed { query = q }
        if scope != s { scope = s }
        if changed {
            selected = nil
            run(q)
        }
    }

    /// Focus with or without a conversation scope (⌘F vs ⌥⌘F / ⌘K).
    func prepare(conversation c: SearchConversationScope?) {
        if conversation != c { conversation = c }
        let on = c != nil
        if inConversation != on { inConversation = on }
        refreshFindHits()
    }

    private func refreshFindHits() {
        let hits = conversation.flatMap { c in window?.app?.localSearch.hits(matching: query, inChat: c.id) } ?? []
        if hits != findHits { findHits = hits }
    }

    /// Find-in-conversation rows: the server hits in the conversation
    /// plus its on-device matches, once each, newest first.
    static func conversationHits(server: [SearchHit], local: [SearchHit]) -> [SearchHit] {
        var seen = Set<String>()
        return (server + local)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func preselect(_ raw: String?, then action: String? = nil) {
        pendingResult = raw.flatMap(Int.init)
        pendingAction = action
        applyPendingResult()
    }

    private func reset() {
        if !query.isEmpty { query = "" }
        if scope != .all { scope = .all }
        if selected != nil { selected = nil }
        if conversation != nil { conversation = nil }
        if inConversation { inConversation = false }
        if !findHits.isEmpty { findHits = [] }
        pendingResult = nil
        pendingAction = nil
        guard let app = window?.app else { return }
        Task { await app.messageSearch.search(query: "") }
        app.filePeople.clear()
    }

    /// Starts every source for `q`: messages (the offline index first,
    /// then the server window merged above it; while offline the list
    /// shows the index hits), people and files. Stale completions are
    /// dropped by the stores.
    private func run(_ q: String) {
        refreshFindHits()
        guard let app = window?.app else { return }
        Task { [weak self] in
            await app.messageSearch.search(query: q)
            self?.resultsDidChange()
        }
        Task { [weak self] in
            await app.filePeople.search(query: q)
            self?.resultsDidChange()
        }
    }

    /// A source finished: the toolbar subtitle counts the new rows, and
    /// a pending evidence selection/action applies.
    private func resultsDidChange() {
        refreshFindHits()
        window?.navigator?.refreshTitle()
        applyPendingResult()
    }

    // MARK: user actions (views call these; they never write nav)

    func setScope(_ s: SearchScope) {
        if inConversation { inConversation = false }
        window?.navigator?.beginSearch(query: query, scope: s)
    }

    func setConversationScopeActive() {
        guard conversation != nil, !inConversation else { return }
        inConversation = true
        selected = nil
        window?.navigator?.refreshTitle()
    }

    /// Toolbar subtitle in search mode (§5.4 "subtitle = context"): how
    /// many results are listed, and the conversation a ⌘F search is
    /// limited to. Empty while the first results are on their way.
    func subtitle() -> String {
        let n = orderedResults().count
        if n == 0, isSearching { return "" }
        let count = n == 0 ? "No results" : n == 1 ? "1 result" : "\(n) results"
        guard inConversation, let c = conversation else { return count }
        return "\(count) in \(c.name)"
    }

    var isSearching: Bool {
        guard let app = window?.app else { return false }
        return window?.connection == .offline
            ? app.localSearch.isSearching
            : app.messageSearch.isSearching || app.filePeople.isSearching
    }

    /// Selecting a result opens it in the detail pane (R24: the load
    /// starts here, not in the view).
    func select(_ id: SearchResultID?) {
        guard selected != id else { return }
        selected = id
        defer { window?.navigator?.refreshToolbar() } // conversation items follow the detail (§6.2)
        guard let id, let m = window else { return }
        switch id {
        case .target(let tid):
            if let t = target(tid), let open = t.openID { m.graph.openChat(id: open, name: t.openName) }
        case .message(let hid):
            if let hit = messageHit(hid) { open(hit) }
        case .person, .file:
            break
        }
    }

    /// Return / double-click: open the result in its section and leave
    /// search mode (§5.5 "Return on a top hit opens it and exits").
    func activate(_ id: SearchResultID?) {
        guard let id = id ?? firstResult(), let m = window, let nav = m.navigator else { return }
        m.app?.searchRecents.record(query)
        switch id {
        case .target(let tid):
            guard let t = target(tid), let open = t.openID else { return }
            m.graph.openChat(id: open, name: t.openName)
            openInChat(open, nav)
        case .message(let hid):
            guard let hit = messageHit(hid) else { return }
            open(hit)
            openInChat(hit.chatID, nav)
        case .file(let fid):
            // A file hit whose source conversation is known (core-b
            // `SharedFile.source_id`) opens that chat or channel.
            guard let f = file(fid), let src = f.source_id, !src.isEmpty else { return select(id) }
            openSource(src, name: f.source_name, m, nav)
        case .person:
            select(id)
        }
    }

    /// Opens a file's source conversation: a channel in the Teams
    /// section (its team from the joined list), else the chat.
    private func openSource(_ id: String, name: String?, _ m: WindowModel, _ nav: Navigator) {
        if let team = m.app?.teams.teams.first(where: { $0.channels.contains { $0.channelId == id } }) {
            nav.select(TeamsSelection(teamID: team.teamId, channelID: id).selection, in: .teams)
            nav.select(section: .teams)
            return
        }
        m.graph.openChat(id: id, name: name)
        openInChat(id, nav)
    }

    /// ↑/↓ from the search field (and ⌘G / ⇧⌘G) step through results.
    func step(_ delta: Int) {
        let rows = orderedResults()
        guard !rows.isEmpty else { return }
        let i = selected.flatMap { rows.firstIndex(of: $0) }
        let next = i.map { min(max($0 + delta, 0), rows.count - 1) } ?? (delta > 0 ? 0 : rows.count - 1)
        select(rows[next])
    }

    var canStep: Bool { !orderedResults().isEmpty }

    // MARK: rows (one source for list, keys and stepping)

    struct Rows {
        var topHits: [JumpTarget] = []
        var messages: [SearchHit] = []
        var people: [TeamMember] = []
        var files: [SharedFile] = []
    }

    func rows() -> Rows {
        guard let m = window else { return Rows() }
        let plan = SearchSectionPlan.plan(scope, inConversation: inConversation)
        var r = Rows()
        if plan.topHits != SearchSectionPlan.hidden {
            let targets = JumpTargets.build(chats: m.graph.chats.chats, teams: m.app?.teams.teams ?? [])
            r.topHits = SearchSectionPlan.take(FuzzyMatch.ranked(targets, query: query), plan.topHits)
        }
        if plan.messages != SearchSectionPlan.hidden {
            var hits = messageHits()
            if inConversation, let c = conversation {
                hits = Self.conversationHits(server: hits.filter { $0.chatID == c.id }, local: findHits)
            }
            r.messages = SearchSectionPlan.take(hits, plan.messages)
        }
        if let app = m.app {
            if plan.people != SearchSectionPlan.hidden {
                r.people = SearchSectionPlan.take(app.filePeople.people, plan.people)
            }
            if plan.files != SearchSectionPlan.hidden {
                r.files = SearchSectionPlan.take(app.filePeople.files, plan.files)
            }
        }
        return r
    }

    func orderedResults() -> [SearchResultID] {
        let r = rows()
        return r.topHits.map { .target($0.id) } + r.messages.map { .message($0.id) }
            + r.people.map { .person($0.id) } + r.files.map { .file($0.id) }
    }

    /// Message hits: the server window merged with the offline index, or
    /// the offline index alone while offline.
    func messageHits() -> [SearchHit] {
        guard let app = window?.app else { return [] }
        return window?.connection == .offline ? app.localSearch.hits : app.messageSearch.hits
    }

    func target(_ id: String) -> JumpTarget? {
        guard let m = window else { return nil }
        return JumpTargets.build(chats: m.graph.chats.chats, teams: m.app?.teams.teams ?? []).first { $0.id == id }
    }

    func messageHit(_ id: String) -> SearchHit? {
        messageHits().first { $0.id == id } ?? findHits.first { $0.id == id }
    }
    func person(_ id: String) -> TeamMember? { window?.app?.filePeople.people.first { $0.id == id } }
    func file(_ id: String) -> SharedFile? { window?.app?.filePeople.files.first { $0.id == id } }

    private func firstResult() -> SearchResultID? { orderedResults().first }

    private func open(_ hit: SearchHit) {
        if let app = window?.app {
            app.jumpToMessage(hit)
        } else {
            window?.graph.openChat(id: hit.chatID, name: nil)
        }
    }

    /// Leaves search on the conversation (Chat section for chats; the
    /// section that owns channels arrives with P2c).
    private func openInChat(_ id: String, _ nav: Navigator) {
        nav.select(SectionSelection(id: id), in: .chat)
        nav.select(section: .chat)
    }

    func applyPendingResult() {
        let ordered = orderedResults()
        if let i = pendingResult {
            guard i >= 0, i < ordered.count else { return }
            pendingResult = nil
            select(ordered[i])
        }
        // Actions wait for the sources to finish (and, for Return, for a
        // top hit when the scope has them) so they act on final rows.
        guard let action = pendingAction, !isSearching, !ordered.isEmpty else { return }
        if action == "open", SearchSectionPlan.plan(scope, inConversation: inConversation).topHits != 0,
           rows().topHits.isEmpty { return }
        pendingAction = nil
        switch action {
        case "open": activate(selected)
        case "esc": window?.navigator?.endSearch()
        default: break
        }
    }
}
