// ShellWindowController.swift — one main window per account (UI-SPEC
// §5.1, §5.7, R1, R26).
//
// Stock window chrome only (R1). Restoration: frame autosave per account
// plus NavigationModel JSON; `isRestorable = false`; window tabbing off.
// The model is restored and applied before the first
// makeKeyAndOrderFront, so a window never opens on one section and
// jumps to another. Signed out, the content controller is
// SignInViewController (no rail, no split view); after sign-in it swaps
// to the shell exactly once.
import AppKit
import Combine
import OstMacCore
import SwiftUI

@MainActor
public final class ShellWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    NSToolbarItemValidation, ShellHost
{
    public let model: WindowModel
    public let navigator: Navigator
    let split: ShellSplitViewController
    private(set) var toolbarController: ShellToolbarController!
    private(set) var sheets: SheetPresenter!
    private var signIn: SignInViewController?
    /// The shell's minimum size while sign-in (content-sized) is shown.
    private var shellMinSize: NSSize?
    private var showingShell = false
    private var cancellables = Set<AnyCancellable>()
    private var titleRefreshQueued = false
    /// An inspector open requested before the window's frame was final.
    private var inspectorFitDeferred = false
    /// The deferred open was explicit (it may grow the window).
    private var inspectorDeferredExplicit = false

    /// Key (else main, else first) shell window controller.
    static var current: ShellWindowController? {
        (NSApp.keyWindow?.windowController as? ShellWindowController)
            ?? (NSApp.mainWindow?.windowController as? ShellWindowController)
            ?? NSApp.windows.lazy.compactMap { $0.windowController as? ShellWindowController }.first
    }

    public init(graph: any AccountGraph, options: LaunchOptions) {
        let key = options.demo ? "demo" : graph.graphAccountID
        let m = WindowModel(graph: graph, accountKey: key, options: options)
        let nav = Navigator(model: m)
        model = m
        navigator = nav
        let feed = RailBadgeFeed(SectionID.builtIns.flatMap { m.provider($0).badgeChanges(m) })
        let rail = Hosting.controller(RailView(navigator: nav, badges: feed), role: .pane, model: m)
        split = ShellSplitViewController(rail: rail)

        let minHeight = RailModel.minimumWindowHeight(itemHeight: RailModel.itemHeight(.medium))
        let size = options.windowSize ?? NSSize(width: 1280, height: 820)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 900, height: minHeight)
        window.title = "Chat"
        super.init(window: window)
        window.delegate = self

        sheets = SheetPresenter(model: model) { [weak window] in window?.contentViewController }
        model.presenter = sheets
        model.navigator = navigator
        navigator.host = self
        split.onInspectorCollapsed = { [weak self] collapsed in
            self?.navigator.inspectorDidChange(collapsed: collapsed)
        }
        toolbarController = ShellToolbarController(splitView: split.splitView, owner: self)
        observeStores()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: content (sign-in vs shell)

    /// Installs the shell, restores navigation, and applies it — all
    /// before the window is first shown.
    public func showShell() {
        guard !showingShell, let window else { return }
        showingShell = true
        let frame = window.frame
        let fromSignIn = signIn != nil
        // The shell minimum (900 × rail minimum, §5.1), read while the
        // window has no toolbar.
        let shellMin = shellMinSize ?? window.minSize
        window.contentViewController = split
        window.toolbar = toolbarController.toolbar
        toolbarController.setConnection(model.connection)
        if !model.options.evidence {
            split.setAutosaveName("main.\(model.accountKey)")
        }
        // Attaching a toolbar raises `minSize` by the toolbar's height
        // (900 × 600 became 900 × 620). The content fills the window
        // (full-size content view), so the content minimum is the window
        // minimum: pin it to the spec's size.
        Self.setContentMinSize(shellMin, on: window)
        shellMinSize = nil
        if fromSignIn {
            // The sign-in window is content-sized; the shell gets its
            // saved (or default) frame, keeping the sign-in window's center.
            let size = model.options.windowSize ?? NSSize(width: 1280, height: 820)
            window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                                   width: size.width, height: size.height), display: false)
            if !model.options.evidence {
                let name = "main.\(model.accountKey)"
                window.setFrameUsingName(name)
                window.setFrameAutosaveName(name)
            }
        } else if window.isVisible {
            window.setFrame(frame, display: false)
        }
        signIn = nil
        if !model.options.evidence, let state = Navigator.loadPersisted(model.accountKey) {
            navigator.restore(state)
        } else {
            navigator.applyAll()
        }
    }

    /// Signed-out content: centered, no rail, no split view (§5.7).
    public func showSignIn(evidence: SignInPresentation? = nil) {
        guard let window else { return }
        showingShell = false
        let vc = SignInViewController(model: model, evidence: evidence)
        signIn = vc
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        window.toolbar = nil
        if shellMinSize == nil { shellMinSize = window.minSize }
        window.contentViewController = vc
        window.title = "Sign In"
        window.subtitle = ""
        // Sized to its content (HIG windows), centered where the window
        // was; the controller follows later screen changes from the top.
        let size = vc.fittingContentSize
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        window.setContentSize(size)
        let f = window.frame
        window.setFrameOrigin(NSPoint(x: center.x - f.width / 2, y: center.y - f.height / 2))
    }

    var isShowingShell: Bool { showingShell }

    /// Sets the frame autosave name (per account) and default frame.
    func placeWindow() {
        guard let window else { return }
        if signIn != nil {
            // Sign-in keeps its content size; no shell frame autosave.
            if model.options.evidence {
                let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                window.setFrameTopLeftPoint(NSPoint(x: screen.minX + 40, y: screen.maxY - 40))
            } else {
                window.center()
            }
            return
        }
        if model.options.evidence {
            let size = model.options.windowSize ?? NSSize(width: 1280, height: 820)
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            window.setFrame(NSRect(x: screen.minX + 40, y: screen.maxY - size.height - 40,
                                   width: size.width, height: size.height), display: false)
        } else {
            window.center()
            window.setFrameAutosaveName("main.\(model.accountKey)")
        }
        resolveDeferredInspector()
    }

    /// With the frame final: open the deferred inspector if it fits
    /// (or was explicitly requested), else yield (the model records it
    /// collapsed).
    private func resolveDeferredInspector() {
        guard inspectorFitDeferred else { return }
        inspectorFitDeferred = false
        let explicit = inspectorDeferredExplicit
        inspectorDeferredExplicit = false
        let s = model.nav.section
        guard model.nav.search == nil, navigator.hasInspector(s), model.nav.isInspectorVisible(s) else { return }
        // Lay the panes out at the final frame first: expanding against
        // the pre-placement layout would widen the window.
        window?.layoutIfNeeded()
        if explicit || split.inspectorFits(in: window) {
            split.expandInspector(in: window)
        } else {
            navigator.inspectorDidChange(collapsed: true)
        }
    }

    // MARK: ShellHost (called by Navigator in the same call stack)

    func applyPanes(key: String, provider p: SectionProvider, layout: SectionLayout,
                    inspectorAvailable: Bool, inspectorVisible: Bool, searching: Bool) {
        guard showingShell else { return }
        let m = model
        split.listPane.show(key) {
            let v: AnyView = searching ? AnyView(SearchResultsList()) : p.listPane(m)
            return Hosting.controller(v, role: .pane, model: m)
        }
        split.detailPane.show(key) {
            let v: AnyView = searching ? AnyView(SearchDetailPane()) : p.detailPane(m)
            return Hosting.controller(v, role: .pane, model: m)
        }
        if inspectorAvailable {
            split.inspectorPane.show(key) {
                Hosting.controller(p.inspector(m) ?? AnyView(EmptyView()), role: .pane, model: m)
            }
        }
        split.setListCollapsed(layout == .full)
        // Inspector yield (§5.1): a route, restore or automatic open never
        // widens the window. Before the window is shown its frame is not
        // final (setting the split as content sizes it to the panes), so
        // the fit is decided once, in `placeWindow` (an explicit request
        // there, e.g. a `?thread=` route, still opens).
        let opening = inspectorVisible && split.inspectorItem.isCollapsed
        let explicit = navigator.explicitInspectorRequest
        if opening, window?.isVisible != true {
            inspectorDeferredExplicit = (inspectorFitDeferred && inspectorDeferredExplicit) || explicit
            inspectorFitDeferred = true
        } else if opening, !explicit, !split.inspectorFits(in: window) {
            // The model follows, as for a collapse from a window resize.
            navigator.inspectorDidChange(collapsed: true)
        } else {
            inspectorFitDeferred = false
            inspectorDeferredExplicit = false
            if opening {
                split.expandInspector(in: window)
            } else {
                split.setInspectorCollapsed(!inspectorVisible)
            }
        }
        // The list|detail tracking separator has nothing to track in `.full`.
        toolbarController.setListSeparatorHidden(layout == .full)
    }

    func applyToolbar(_ visible: Set<CommandID>) {
        guard showingShell else { return }
        toolbarController.sync(visible: visible)
        toolbarController.showQuery(model.nav.search?.query)
    }

    func applyTitle(_ title: String, subtitle: String) {
        guard showingShell, let window else { return }
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    /// AppKit ignores a `contentMinSize` equal to the value it stored
    /// before the toolbar raised it (it keeps reporting the raised one),
    /// so the size is cleared first.
    private static func setContentMinSize(_ size: NSSize, on window: NSWindow) {
        window.contentMinSize = .zero
        window.contentMinSize = size
    }

    func applyMinimumWindowHeight(_ height: CGFloat) {
        guard let window, window.contentMinSize.height != height else { return }
        Self.setContentMinSize(NSSize(width: window.contentMinSize.width, height: height), on: window)
        if window.frame.height < height {
            var f = window.frame
            f.origin.y -= height - f.height
            f.size.height = height
            window.setFrame(f, display: true)
        }
    }

    func clearSearchField() { toolbarController.clearSearch() }

    func focusSearchField(placeholder: String) {
        guard showingShell, let window, let item = toolbarController.searchItem else { return }
        if let tb = window.toolbar, !tb.isVisible { tb.isVisible = true }
        item.searchField.placeholderString = placeholder
        item.beginSearchInteraction()
    }

    // MARK: store observation (stores, never NavigationModel — R21)

    private func observeStores() {
        let g = model.graph
        g.unread.objectWillChange.merge(with: g.chats.objectWillChange)
            .sink { [weak self] _ in self?.queueTitleRefresh() }
            .store(in: &cancellables)
        guard let app = model.app else { return }
        // Teams subtitle ("N unread") follows the teams list live.
        app.teams.objectWillChange
            .sink { [weak self] _ in self?.queueTitleRefresh() }
            .store(in: &cancellables)
        app.auth.$state
            .sink { [weak self] state in self?.authChanged(state) }
            .store(in: &cancellables)
        app.$feedState
            .sink { [weak self] feed in self?.feedChanged(feed) }
            .store(in: &cancellables)
        app.$signedIn
            .sink { [weak self] signed in self?.signedInChanged(signed) }
            .store(in: &cancellables)
    }

    /// Store publishers fire in willSet; refresh after the value lands.
    private func queueTitleRefresh() {
        guard !titleRefreshQueued else { return }
        titleRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.titleRefreshQueued = false
            self.navigator.refreshTitle()
        }
    }

    private func authChanged(_ state: AuthState) {
        guard !model.options.demo else { return }
        switch state {
        case .expired, .refreshFailed: setConnection(.expired)
        case .signedIn: if model.connection == .expired { setConnection(.online) }
        default: break
        }
    }

    private func feedChanged(_ feed: RealtimeFeed.State) {
        guard !model.options.demo, model.connection != .expired else { return }
        setConnection(feed == .retryWait ? .offline : .online)
    }

    /// Also driven by the demo-only evidence modifier `connection=`.
    func setConnection(_ c: ConnectionState) {
        guard model.connection != c else { return }
        model.setConnection(c)
        toolbarController.setConnection(c)
        navigator.refreshToolbar()
    }

    private func signedInChanged(_ signed: Bool?) {
        guard !model.options.demo, let signed else { return }
        if signed {
            if !showingShell {
                showShell()
                navigator.resyncSelection()
            }
        } else if showingShell, model.graph.chats.chats.isEmpty {
            // Never swap back while the account has data (§5.7).
            showSignIn()
        }
    }

    // MARK: commands (R19)

    @objc public func performCommand(_ sender: Any?) {
        guard let (id, arg) = Self.invocation(sender) else { return }
        perform(id, arg: arg)
    }

    static func invocation(_ sender: Any?) -> (CommandID, String?)? {
        if let mi = sender as? NSMenuItem, let raw = mi.representedObject as? String {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            guard let first = parts.first else { return nil }
            return (CommandID(first), parts.count > 1 ? parts[1] : nil)
        }
        if let ti = sender as? NSToolbarItem { return (CommandID(ti.itemIdentifier.rawValue), nil) }
        return nil
    }

    func perform(_ id: CommandID, arg: String?) {
        if let owner = CommandCatalog.command(id)?.owner {
            _ = model.provider(owner).perform(id, arg: arg, model)
            return
        }
        switch id {
        case ShellCommand.goActivity, ShellCommand.goChat, ShellCommand.goTeams,
             ShellCommand.goCalendar, ShellCommand.goCalls, ShellCommand.goFiles:
            if let s = SectionID.builtIns.first(where: { ShellCommand.go($0) == id }) {
                navigator.select(section: s)
            }
        case ShellCommand.goApps: navigator.select(section: .apps)
        case _ where ShellCommand.goPinned.contains(id):
            if let i = ShellCommand.goPinned.firstIndex(of: id), i < model.rail.pinned.count {
                navigator.select(section: model.rail.pinned[i].section)
            }
        case ShellCommand.goTo: navigator.focusSearch(.goTo)
        case ShellCommand.search: navigator.focusSearch(.all)
        case ShellCommand.find: navigator.focusSearch(.conversation)
        case ShellCommand.findNext, ShellCommand.findPrevious:
            if model.frameHost.findKey != nil {
                model.frameHost.findAgain(backwards: id == ShellCommand.findPrevious)
            } else {
                model.search.step(id == ShellCommand.findNext ? 1 : -1)
            }
        case ShellCommand.inspector: navigator.toggleInspector()
        case ShellCommand.tabChat, ShellCommand.tabFiles, ShellCommand.tabNotes:
            if let ref = currentConversation {
                let t: ConversationTab = id == ShellCommand.tabChat ? .chat : id == ShellCommand.tabFiles ? .files : .notes
                navigator.setDetailTab(t, for: ref)
            } else if let teams = currentTeams {
                // ⌥⌘1–3 follow the active section: a channel's Posts | Files | Notes.
                teams.selectChannelTab(TeamsSection.channelTab(for: id), model)
            }
        case _ where ShellCommand.pageZoom.contains(id) && currentWebApp != nil:
            // In a web app, View ▸ zoom scales the page (§7.3).
            currentWebApp?.zoom(id == ShellCommand.zoomIn ? .in : id == ShellCommand.zoomOut ? .out : .actual, model)
        case ShellCommand.actualSize: model.setTextScale(1.0)
        case ShellCommand.zoomIn: model.setTextScale(TextScaleSteps.next(model.textScale, up: true))
        case ShellCommand.zoomOut: model.setTextScale(TextScaleSteps.next(model.textScale, up: false))
        case ShellCommand.nextUnread, ShellCommand.previousUnread:
            (model.provider(.chat) as? ChatSection)?.stepUnread(forward: id == ShellCommand.nextUnread, model)
        case ShellCommand.account: accountAction(arg)
        case ShellCommand.connection: if model.connection == .expired { presentSignInSheet() }
        case ShellCommand.signOut: confirmSignOut()
        case ShellCommand.settings: SettingsWindowController.shared.show()
        default: break
        }
    }

    private var currentConversation: ConversationRef? {
        guard model.nav.section == .chat, model.nav.search == nil else { return nil }
        return model.nav.selection(in: .chat)?.id
    }

    /// The web app on screen (not searching).
    private var currentWebApp: WebAppSection? {
        guard model.nav.search == nil, case .web = model.nav.section else { return nil }
        return model.provider(model.nav.section) as? WebAppSection
    }

    /// The Teams provider while Teams is on screen (not searching).
    private var currentTeams: TeamsSection? {
        guard model.nav.section == .teams, model.nav.search == nil else { return nil }
        return model.provider(.teams) as? TeamsSection
    }

    func validate(_ id: CommandID, arg: String? = nil) -> CommandValidation {
        guard showingShell else { return .disabled }
        if let owner = CommandCatalog.command(id)?.owner {
            return model.provider(owner).validate(id, arg: arg, model)
        }
        let nav = model.nav
        switch id {
        case ShellCommand.goActivity, ShellCommand.goChat, ShellCommand.goTeams,
             ShellCommand.goCalendar, ShellCommand.goCalls, ShellCommand.goFiles, ShellCommand.goApps:
            let target: SectionID = SectionID.builtIns.first { ShellCommand.go($0) == id } ?? .apps
            return CommandValidation(enabled: true, checked: nav.section == target && nav.search == nil)
        case _ where ShellCommand.goPinned.contains(id):
            let i = ShellCommand.goPinned.firstIndex(of: id) ?? 0
            guard i < model.rail.pinned.count else {
                return CommandValidation(enabled: false, title: "Pinned App \(i + 1)")
            }
            let e = model.rail.pinned[i]
            return CommandValidation(enabled: true, checked: nav.section == e.section, title: e.title)
        case ShellCommand.goTo, ShellCommand.search, ShellCommand.find, ShellCommand.account: return .enabled
        case ShellCommand.findNext, ShellCommand.findPrevious:
            if model.frameHost.findKey != nil { return CommandValidation(enabled: !model.frameHost.findQuery.isEmpty) }
            return CommandValidation(enabled: nav.search != nil && model.search.canStep)
        case ShellCommand.inspector:
            let has = nav.search == nil && navigator.hasInspector(nav.section)
            let on = nav.isInspectorVisible(nav.section)
            return CommandValidation(enabled: has, title: on && has ? "Hide Inspector" : "Show Inspector")
        case ShellCommand.tabChat, ShellCommand.tabFiles, ShellCommand.tabNotes:
            // Titles follow the section (Chat: Chat | Files | Notes;
            // Teams: Posts | Files | Notes), always set so they switch back.
            if let teams = currentTeams {
                let mine = TeamsSection.channelTab(for: id)
                let title = TeamsSection.channelTabTitle(mine)
                guard let t = teams.channelTab(model) else { return CommandValidation(enabled: false, title: title) }
                return CommandValidation(enabled: true, checked: t == mine, title: title)
            }
            let title = id == ShellCommand.tabChat ? "Chat" : id == ShellCommand.tabFiles ? "Files" : "Notes"
            guard let ref = currentConversation else { return CommandValidation(enabled: false, title: title) }
            let t = nav.tab(for: ref)
            let mine: ConversationTab = id == ShellCommand.tabChat ? .chat : id == ShellCommand.tabFiles ? .files : .notes
            return CommandValidation(enabled: true, checked: t == mine, title: title)
        case _ where ShellCommand.pageZoom.contains(id) && currentWebApp != nil:
            let z: WebAppSection.Zoom = id == ShellCommand.zoomIn ? .in : id == ShellCommand.zoomOut ? .out : .actual
            return CommandValidation(enabled: currentWebApp?.canZoom(z, model) ?? false)
        case ShellCommand.actualSize: return CommandValidation(enabled: model.textScale != 1.0)
        case ShellCommand.zoomIn: return CommandValidation(enabled: model.textScale < 2.0)
        case ShellCommand.zoomOut: return CommandValidation(enabled: model.textScale > 1.0)
        case ShellCommand.nextUnread, ShellCommand.previousUnread: return .enabled
        case ShellCommand.connection: return CommandValidation(enabled: model.connection == .expired)
        case ShellCommand.signOut: return CommandValidation(enabled: !model.options.demo && model.app != nil)
        case ShellCommand.settings: return .enabled // Calls pane (P3b); P4c adds the rest
        default: return .disabled // Help: not built yet
        }
    }

    func submenuItems(_ id: CommandID) -> [SubmenuItem] {
        if let owner = CommandCatalog.command(id)?.owner {
            return model.provider(owner).submenuItems(id, model)
        }
        guard id == ShellCommand.account else { return [] }
        let live = !model.options.demo && model.app != nil
        let own = model.app?.presence.own.flatMap { PresenceStatus(graphAvailability: $0.availability) }
        var out: [SubmenuItem] = [
            (PresenceStatus.available, "Available"), (.busy, "Busy"), (.dnd, "Do Not Disturb"),
            (.away, "Away"), (.offline, "Appear Offline"),
        ].map { status, title in
            SubmenuItem(title, arg: "presence:\(status.rawValue)", symbol: PresenceGlyph.symbol(status),
                        checked: own == status, enabled: live)
        }
        if let app = model.app {
            var first = true
            for acct in app.accounts.accounts {
                out.append(SubmenuItem(acct.displayName, arg: "account:\(acct.id)",
                                       checked: acct.id == app.accounts.activeID,
                                       enabled: live, separatorBefore: first))
                first = false
            }
        }
        out.append(SubmenuItem("Add Account…", arg: "add", enabled: live, separatorBefore: true))
        out.append(SubmenuItem("Sign Out…", arg: "signOut", enabled: live))
        return out
    }

    private func accountAction(_ arg: String?) {
        guard let arg, let app = model.app, !model.options.demo else { return }
        if arg.hasPrefix("presence:"), let s = PresenceStatus(rawValue: String(arg.dropFirst(9))) {
            app.presence.set(status: s)
        } else if arg.hasPrefix("account:") {
            app.switchAccount(to: String(arg.dropFirst(8)))
        } else if arg == "signOut" {
            confirmSignOut()
        } else if arg == "add" {
            presentAddAccount()
        } else if arg == "webSignIn" {
            presentWebAppsSignIn()
        }
    }

    /// Add Account… (§9.4 Accounts): sign-in on a fresh profile in a
    /// sheet; success records and activates the account.
    private func presentAddAccount() {
        guard let app = model.app, !model.options.demo else { return }
        bringForward()
        let vc = SignInViewController(model: model, evidence: nil, asSheet: true,
                                      adding: app.accounts.beginAdd()) { [weak app] vm in
            app?.completePendingAdd(vm)
        }
        sheets.present(vc, request: SheetRequest("addAccount", in: model.nav.section))
    }

    /// Sign In to Web Apps… (§9.4 Accounts, §7.3 SSO): Teams on the web in
    /// the account's store; the sheet closes once Teams loads signed in.
    private func presentWebAppsSignIn() {
        guard !model.options.demo, let url = URL(string: TeamsFrameConfig.defaultURL) else { return }
        bringForward()
        let model = self.model
        let sheet = WebAuthSheet(web: model.frameHost.makeSignInWebView(), start: url,
                                 redirectURI: FrameHost.webAppsSignedInPrefix) { _ in model.dismissSheet() }
        sheets.present(sheet, request: SheetRequest("webAppsSignIn", in: model.nav.section))
    }

    /// Settings actions show their sheet on this window.
    private func bringForward() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func confirmSignOut() {
        guard let window, let app = model.app, !model.options.demo else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of Better Teams?"
        alert.informativeText = "Your chats stay on this Mac until you sign in again."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { resp in
            guard resp == .alertFirstButtonReturn else { return }
            Task { await app.auth.signOut() }
        }
    }

    private func presentSignInSheet() {
        let vc = SignInViewController(model: model, evidence: nil, asSheet: true)
        sheets.present(vc, request: SheetRequest("signIn", in: model.nav.section))
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let (id, arg) = Self.invocation(item) else { return false }
        let v = validate(id, arg: arg)
        if let t = v.title, item.title != t { item.title = t }
        item.state = v.checked ? .on : .off
        return v.enabled
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(CommandID(item.itemIdentifier.rawValue)).enabled
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        sheets.dismiss()
    }
}

/// Text-size steps (§10).
enum TextScaleSteps {
    static let steps: [Double] = [1.0, 1.15, 1.3, 1.5, 1.75, 2.0]

    static func next(_ v: Double, up: Bool) -> Double {
        if up { return steps.first { $0 > v + 0.001 } ?? 2.0 }
        return steps.last { $0 < v - 0.001 } ?? 1.0
    }
}

extension PresenceStatus {
    /// Graph availability string → status (nil when unknown).
    init?(graphAvailability raw: String?) {
        guard let raw else { return nil }
        switch raw {
        case "Available", "AvailableIdle": self = .available
        case "Busy", "BusyIdle", "InACall", "InAMeeting": self = .busy
        case "DoNotDisturb", "Presenting", "Focusing": self = .dnd
        case "Away", "BeRightBack": self = .away
        case "Offline", "PresenceUnknown": self = .offline
        default: return nil
        }
    }
}
