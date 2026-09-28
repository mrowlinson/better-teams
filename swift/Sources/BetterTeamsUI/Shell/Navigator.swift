// Navigator.swift — the only writer of NavigationModel (UI-SPEC R21,
// DL5, §11.3).
//
// Every method mutates the model and then, in the same call stack,
// applies the AppKit side (pane child swap, list-pane collapse, toolbar
// visibility, window title) through `ShellHost`. AppKit never observes
// the model asynchronously, so no intermediate frame is ever visible.
import Foundation
import OstMacCore

/// Write capability for NavigationModel; only Navigator can mint one.
public struct NavigationWriteToken {
    fileprivate init() {}
}

/// The AppKit side a Navigator drives (ShellWindowController).
@MainActor
protocol ShellHost: AnyObject {
    func applyPanes(key: String, provider: SectionProvider, layout: SectionLayout,
                    inspectorAvailable: Bool, inspectorVisible: Bool, searching: Bool)
    func applyToolbar(_ visible: Set<CommandID>)
    func applyTitle(_ title: String, subtitle: String)
    func clearSearchField()
    func focusSearchField(placeholder: String)
    /// Rail item height changed (sidebar icon size, §5.2): the window's
    /// minimum height follows so fixed rail items never overflow.
    func applyMinimumWindowHeight(_ height: CGFloat)
}

extension ShellHost {
    func applyMinimumWindowHeight(_ height: CGFloat) {}
}

/// Sections whose provider has an inspector (§5.3 table).
@MainActor
protocol InspectorCapable {
    var hasInspector: Bool { get }
    /// Per-selection answer (Calendar: Week view only, §5.3).
    func hasInspector(for sel: SectionSelection?) -> Bool
}

extension InspectorCapable {
    func hasInspector(for sel: SectionSelection?) -> Bool { hasInspector }
}

@MainActor
public final class Navigator {
    public let model: WindowModel
    weak var host: ShellHost?
    private let token = NavigationWriteToken()

    public init(model: WindowModel) {
        self.model = model
    }

    private var nav: NavigationModel { model.nav }

    // MARK: sections and selection

    public func select(section s: SectionID) {
        endPageFind()
        if nav.search != nil { exitSearchState(restore: false) }
        noteTransient(s)
        nav.setSection(s, token)
        applyAll()
        model.provider(s).selectionDidChange(nav.selection(in: s), model)
        persist()
    }

    public func select(_ sel: SectionSelection?, in s: SectionID) {
        nav.setSelection(sel, in: s, token)
        if s == nav.section { applyAll() }
        model.provider(s).selectionDidChange(sel, model)
        persist()
    }

    public func setDetailTab(_ t: ConversationTab, for ref: ConversationRef) {
        nav.setTab(t, for: ref, token)
        persist()
    }

    // MARK: pinned apps (§5.2)

    /// Unpins; the app on screen stays listed as the transient item, so
    /// the rail never shows a selected app it does not list.
    public func unpin(_ e: RailEntry) {
        model.rail.unpin(e)
        if nav.section == e.section { model.rail.setTransient(e) }
    }

    /// Close App (transient item): leaves it if on screen, then unloads it.
    public func closeTransient() {
        guard let t = model.rail.transient else { return }
        model.rail.setTransient(nil)
        if nav.section == t.section { select(section: .apps) }
        if case .web(let id) = t { model.frameHost.unload(.app(id)) }
    }

    /// Previous section (call ended while selected, §8).
    public func returnToPrevious() {
        select(section: nav.previousSection ?? .chat)
    }

    // MARK: inspector (R25)

    public func toggleInspector() {
        setInspector(!nav.isInspectorVisible(nav.section), explicit: true)
    }

    /// True only while an explicit Show Inspector (toolbar, menu, "N
    /// replies") is applied: that alone may widen a window too narrow
    /// for the inspector; routes, restores and automatic opens yield.
    private(set) var explicitInspectorRequest = false

    public func setInspector(_ visible: Bool, explicit: Bool = false) {
        guard hasInspector(nav.section) else { return }
        nav.setInspector(visible, in: nav.section, token)
        explicitInspectorRequest = explicit
        defer { explicitInspectorRequest = false }
        applyAll()
        persist()
    }

    /// User or system collapse reported by the shell's KVO. Equality
    /// guarded and never echoed back to the split item.
    func inspectorDidChange(collapsed: Bool) {
        let s = nav.section
        guard nav.search == nil, hasInspector(s), nav.isInspectorVisible(s) == collapsed else { return }
        nav.setInspector(!collapsed, in: s, token)
        host?.applyToolbar(visibleToolbar())
        persist()
    }

    // MARK: search mode (§5.5)

    public func beginSearch(query: String, scope: SearchScope = .all) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return endSearch() }
        let restore = nav.search.map { ($0.restoreSection, $0.restoreSelection) }
            ?? (nav.section, nav.selection(in: nav.section))
        nav.setSearch(SearchState(query: q, scope: scope,
                                  restoreSection: restore.0, restoreSelection: restore.1), token)
        model.search.setQuery(q, scope: scope)
        applyAll()
    }

    /// Esc or the clear button: restores the exact prior section,
    /// selection, and layout.
    public func endSearch() {
        guard nav.search != nil else { return }
        exitSearchState(restore: true)
        host?.clearSearchField()
        applyAll()
        model.provider(nav.section).selectionDidChange(nav.selection(in: nav.section), model)
        persist()
    }

    private func exitSearchState(restore: Bool) {
        guard let s = nav.search else { return }
        nav.setSearch(nil, token)
        model.search.setQuery("", scope: .all)
        if restore {
            nav.setSection(s.restoreSection, token)
            nav.setSelection(s.restoreSelection, in: s.restoreSection, token)
        } else {
            host?.clearSearchField()
        }
    }

    public enum SearchFocus { case all, goTo, conversation }

    /// The scope a new search starts in: searching inside Files searches
    /// files (§6.6 "scope Files, or searching inside this section").
    static func initialScope(for section: SectionID) -> SearchScope {
        section == .files ? .files : .all
    }

    /// ⌥⌘F focuses the field (all); ⌘K = Go To… (all, Return opens the
    /// top hit); ⌘F scopes it to the conversation on screen, when there
    /// is one ("Search in ‹name›", §5.5).
    public func focusSearch(_ mode: SearchFocus) {
        // ⌘F in a web app: the field becomes Find in Page (§5.5, G10).
        if mode == .conversation, nav.search == nil, case .web(let id) = nav.section,
           model.frameHost.page(.app(id)) != nil {
            model.frameHost.beginFind(.app(id))
            host?.focusSearchField(placeholder: "Find in Page")
            return
        }
        endPageFind()
        let scope = mode == .conversation ? conversationOnScreen() : nil
        model.search.prepare(conversation: scope)
        let inFiles = nav.search == nil && nav.section == .files
        let placeholder = switch mode {
        case .goTo: "Go To…"
        case .all: inFiles ? "Search in Files" : "Search"
        case .conversation: scope.map { "Search in \($0.name)" } ?? (inFiles ? "Search in Files" : "Search")
        }
        host?.focusSearchField(placeholder: placeholder)
    }

    /// The conversation the detail pane shows (Chat selection, or the
    /// chat behind the selected Activity item).
    /// Leaves Find in Page (section change, route, other search focus).
    func endPageFind() {
        guard model.frameHost.findKey != nil else { return }
        model.frameHost.endFind()
        host?.clearSearchField()
    }

    private func conversationOnScreen() -> SearchConversationScope? {
        let id: String?
        switch nav.section {
        case .chat: id = nav.selection(in: .chat)?.id
        case .activity: id = nav.selection(in: .activity)?.id.flatMap { model.app?.activity.item(id: $0)?.chatID }
        default: id = nil
        }
        guard let id, !id.isEmpty else { return nil }
        return conversationScope(id)
    }

    private func conversationScope(_ id: String) -> SearchConversationScope {
        let conv = model.graph.conv
        var name: String? = model.graph.chats.chat(id: id)?.name
        if name == nil { name = model.app?.chatNameOrNil(for: id) }
        // Demo names before the header title: at launch the header is
        // still the "Conversation" placeholder (the list has not loaded).
        if name == nil { name = DemoData.name(for: id) }
        if name == nil, conv.chatID == id, !conv.headerTitle.isEmpty { name = conv.headerTitle }
        return SearchConversationScope(id: id, name: name ?? "Conversation")
    }

    // MARK: routes

    /// Applies a route: section, selection, tab, inspector, forced state.
    public func apply(_ route: Route) {
        endPageFind()
        if route.head == "search" {
            let scope = route.query["scope"].flatMap(SearchScope.init(rawValue:)) ?? .all
            if model.options.demo {
                // Evidence: `from=<route>` is the state search began in
                // (Esc restores it); `in=<chat>` is a ⌘F conversation scope.
                if let from = route.query["from"].flatMap(Route.init(string:)), from.head != "search" {
                    apply(from)
                }
                if let cid = route.query["in"], !cid.isEmpty {
                    model.search.prepare(conversation: conversationScope(cid))
                }
            }
            beginSearch(query: route.query["q"] ?? "", scope: scope)
            model.search.preselect(route.query["result"],
                                   then: model.options.demo ? route.query["then"] : nil)
            return
        }
        guard let s = route.section else { return }
        if let pins = route.query["pins"].flatMap(Int.init), model.options.demo {
            model.rail.seedDemoPins(pins)
        }
        model.setForced(route.forcedState, for: s)
        let p = model.provider(s)
        let sel = p.selection(for: route)
        if nav.search != nil { exitSearchState(restore: false) }
        noteTransient(s)
        nav.setSection(s, token)
        nav.setSelection(sel, in: s, token)
        if let raw = route.query["tab"], let t = ConversationTab(rawValue: raw), let ref = sel?.id {
            nav.setTab(t, for: ref, token)
        }
        if let insp = route.inspector {
            nav.setInspector(insp != "0", in: s, token)
            model.setInspectorSegment(insp == "1" || insp == "0" ? nil : insp)
        }
        applyAll()
        p.selectionDidChange(sel, model)
        persist()
    }

    /// Restores persisted state before the window is first shown (R26).
    func restore(_ state: NavigationState) {
        nav.restore(state, token)
        if case .call = nav.section { nav.setSection(.chat, token) }
        applyAll()
    }

    /// Re-drives the current selection's loads (after startup).
    func resyncSelection() {
        model.provider(nav.section).selectionDidChange(nav.selection(in: nav.section), model)
        // Top hits need the chat list (loaded by startup).
        if nav.search != nil { model.search.applyPendingResult() }
    }

    /// An unpinned app opened by route or Go To shows as the rail's
    /// transient item; opening another unpinned app replaces it (§5.2).
    private func noteTransient(_ s: SectionID) {
        let e: RailEntry
        switch s {
        case .native(let n): e = .native(n)
        case .web(let id): e = .web(id)
        default: return
        }
        if !model.rail.pinned.contains(e) { model.rail.setTransient(e) }
    }

    // MARK: apply (same call stack)

    func hasInspector(_ s: SectionID) -> Bool {
        (model.provider(s) as? InspectorCapable)?.hasInspector(for: nav.selection(in: s)) ?? false
    }

    private func visibleToolbar() -> Set<CommandID> {
        let s = nav.section
        let p = model.provider(s)
        let searching = nav.search != nil
        let sel = nav.selection(in: s)
        // The conversation view is shared (Chat, Activity, Search): when
        // it is on screen its items (Call, Catch Up) come with it (§6.2).
        let conv = ConversationToolbar.chatID(model) != nil ? ConversationToolbar.items : []
        // Catch Up Off (Settings ▸ AI) hides the AI button everywhere.
        let catchUpOff = (model.app?.catchUp.mode ?? .off) == .off
        let items = (p.toolbarItems(sel) + (searching ? [] : conv)).filter { !(catchUpOff && $0 == ChatCommands.catchUp) }
        return ToolbarModel.visible(
            items: items, layout: searching ? .listDetail : p.layout(sel),
            hasInspector: hasInspector(s), searching: searching,
            call: model.call?.showsToolbarItem(in: s) ?? false, connection: model.connection,
            searchItems: searching ? conv.filter { !(catchUpOff && $0 == ChatCommands.catchUp) } : [])
    }

    /// Pushes the model to AppKit. Public for evidence and the shell's
    /// connection/subtitle refresh; always synchronous.
    func applyAll() {
        guard let host else { return }
        let s = nav.section
        let p = model.provider(s)
        let searching = nav.search != nil
        let layout: SectionLayout = searching ? .listDetail : p.layout(nav.selection(in: s))
        let available = !searching && hasInspector(s)
        host.applyPanes(key: searching ? "search" : s.key, provider: p, layout: layout,
                        inspectorAvailable: available,
                        inspectorVisible: available && nav.isInspectorVisible(s), searching: searching)
        host.applyToolbar(visibleToolbar())
        host.applyTitle(searching ? "Search" : p.title, subtitle: searching ? model.search.subtitle() : p.subtitle(model))
    }

    /// Title/subtitle only (store-driven subtitle changes; in search
    /// mode, the result count).
    func refreshTitle() {
        guard nav.search == nil else {
            host?.applyTitle("Search", subtitle: model.search.subtitle())
            return
        }
        let p = model.provider(nav.section)
        host?.applyTitle(p.title, subtitle: p.subtitle(model))
    }

    func refreshToolbar() { host?.applyToolbar(visibleToolbar()) }

    /// Reported by the rail when its item height changes (not
    /// navigation state; forwarded straight to the shell).
    func railItemHeightDidChange(_ itemHeight: CGFloat) {
        host?.applyMinimumWindowHeight(RailModel.minimumWindowHeight(itemHeight: itemHeight))
    }

    private func persist() {
        guard !model.options.evidence else { return }
        guard let data = try? JSONEncoder().encode(nav.snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey(model.accountKey))
    }

    static func defaultsKey(_ account: String) -> String { "bt.nav.\(account)" }

    static func loadPersisted(_ account: String) -> NavigationState? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(account)) else { return nil }
        return try? JSONDecoder().decode(NavigationState.self, from: data)
    }
}
