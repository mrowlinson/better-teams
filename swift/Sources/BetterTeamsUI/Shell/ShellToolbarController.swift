// ShellToolbarController.swift — one NSToolbar, fixed identifiers
// (UI-SPEC §5.4, DL3).
//
// The identifier list is the fixed superset of every item any state can
// show, created once at window creation. Items are never inserted,
// removed, or recreated after launch; `sync(visible:)` flips `isHidden`
// on the difference. Enablement comes from validation, never hiding.
//
//   sidebarTracking | list group | list·detail tracking | detail group
//   | flexible | status items (connection, call, …)
//   | trailing group (inspector toggle, account, search — last)
//
// There is no `.inspectorTrackingSeparator` (UI-SPEC §5.4, P2c-fix
// decision). The region after that separator is only as wide as the
// inspector column and is sized from every item in it, hidden ones
// included: search placed there collapsed to its icon whenever the
// inspector was closed, and search placed before it left the inspector
// column's toolbar area empty and broke "search last". Without it the
// detail region runs to the window's trailing edge: the flexible space
// absorbs any hidden status item, search ends the toolbar 8 pt from the
// edge (HIG search fields: "Put a search field at the trailing side of
// the toolbar") and keeps its full field with the inspector open or
// closed. Placement is structural: `layout` puts every `.trailing`
// command that is not in `trailingGroup` (connection, the P4a call
// item, any future status item) after the flexible space and before
// the trailing group, which only holds always-visible items. Pinned by
// `testToolbarTrailingGroupEndsWithSearch`.
import AppKit

extension NSToolbarItem.Identifier {
    static let listDetailSeparator = NSToolbarItem.Identifier("shell.listDetailSeparator")
    /// Rail | list divider (index 0). The rail is a plain split item that
    /// starts below the toolbar (TOOLBARLINE), so the system
    /// `.sidebarTrackingSeparator` (sidebar items only) does not apply.
    static let railListSeparator = NSToolbarItem.Identifier("shell.railListSeparator")
}

@MainActor
final class ShellToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    let toolbar = NSToolbar(identifier: "BetterTeams.main")
    private let order: [NSToolbarItem.Identifier]
    private let commandIDs: [CommandID]
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    /// Last visible set, applied to items NSToolbar creates after a sync.
    private var lastVisible: Set<CommandID>?
    private var listSeparatorHidden = false
    private var menuDelegates: [DynamicMenuDelegate] = []
    private weak var splitView: NSSplitView?
    private weak var owner: ShellWindowController?
    private let debounce = Debounce(milliseconds: 250)

    init(splitView: NSSplitView, owner: ShellWindowController) {
        self.splitView = splitView
        self.owner = owner
        let layout = Self.layout(CommandCatalog.toolbarCommands)
        commandIDs = layout.commandIDs
        order = layout.order
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    static func ident(_ id: CommandID) -> NSToolbarItem.Identifier { .init(id.rawValue) }

    /// The trailing group, in order, ending the toolbar. All are always
    /// visible (never hidden); search is last.
    static let trailingGroup: [CommandID] = [ShellCommand.inspector, ShellCommand.account, ShellCommand.search]

    /// Navigation items (web Back / Forward / Reload, Calendar week
    /// navigation): `isNavigational`, so AppKit places them in the
    /// leading navigation area before the window title instead of after
    /// it, where the title's width pushed them to the trailing edge in
    /// `.full` layouts. Order among them follows the identifier list.
    static let navigational: Set<CommandID> = [
        AppsCommands.back, AppsCommands.forward, AppsCommands.reload,
        CalendarCommands.previousWeek, CalendarCommands.today, CalendarCommands.nextWeek,
        ShiftsCommands.previousWeek, ShiftsCommands.today, ShiftsCommands.nextWeek,
    ]

    /// Items drawn as a text button, not a glyph: "‹ Today ›" (§6.4,
    /// Calendar.app). The command keeps its symbol for other surfaces.
    static let textItems: Set<CommandID> = [CalendarCommands.today, ShiftsCommands.today]

    /// Item order for `commands` (see header). Every `.trailing` command
    /// outside `trailingGroup` is a hideable section/status item and is
    /// placed after the flexible space, before the trailing group,
    /// connection first.
    static func layout(_ commands: [Command])
        -> (order: [NSToolbarItem.Identifier], commandIDs: [CommandID]) {
        let list = commands.filter { $0.toolbar == .list }.map(\.id)
        let detail = commands.filter { $0.toolbar == .detail }.map(\.id)
        let status: [CommandID] = [ShellCommand.connection]
            + commands.filter { $0.toolbar == .trailing && $0.id != ShellCommand.connection
                && !trailingGroup.contains($0.id) }.map(\.id)
        let order: [NSToolbarItem.Identifier] = [.railListSeparator]
            + list.map(ident)
            + [.listDetailSeparator]
            + detail.map(ident)
            + [.flexibleSpace] + status.map(ident)
            + trailingGroup.map(ident)
        return (order, list + detail + status + trailingGroup)
    }

    var searchItem: NSSearchToolbarItem? {
        items[Self.ident(ShellCommand.search)] as? NSSearchToolbarItem
    }

    /// Flips `isHidden` on the difference (never insert/remove).
    func sync(visible: Set<CommandID>) {
        lastVisible = visible
        for id in commandIDs {
            guard let item = items[Self.ident(id)] else { continue }
            let hidden = !visible.contains(id)
            if item.isHidden != hidden { item.isHidden = hidden }
        }
    }

    func setListSeparatorHidden(_ hidden: Bool) {
        listSeparatorHidden = hidden
        if let item = items[.listDetailSeparator], item.isHidden != hidden { item.isHidden = hidden }
    }

    func isVisible(_ id: CommandID) -> Bool {
        items[Self.ident(id)].map { !$0.isHidden } ?? false
    }

    /// Connection item: one item, relabeled per state (§5.7).
    func setConnection(_ c: ConnectionState) {
        guard let item = items[Self.ident(ShellCommand.connection)] else { return }
        let (label, symbol, tip) = switch c {
        case .offline: ("Offline", "wifi.slash", "Showing saved content")
        case .expired, .online: ("Sign In Again", "exclamationmark.triangle", "Your session expired. Sign in again.")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.image = image
        item.toolTip = tip
        // Icon + text (§5.7): the status reads without the glyph alone,
        // although the toolbar is icon-only.
        if let b = item.view as? NSButton {
            b.title = label
            b.image = image
            b.toolTip = tip
            b.setAccessibilityLabel(label)
        }
    }

    @objc private func connectionClicked(_ sender: Any?) {
        owner?.perform(ShellCommand.connection, arg: nil)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { order }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { order }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier ident: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let existing = items[ident] { return existing }
        let item: NSToolbarItem?
        if ident == .railListSeparator {
            guard let splitView else { return nil }
            item = NSTrackingSeparatorToolbarItem(identifier: ident, splitView: splitView, dividerIndex: 0)
        } else if ident == .listDetailSeparator {
            guard let splitView else { return nil }
            item = NSTrackingSeparatorToolbarItem(identifier: ident, splitView: splitView, dividerIndex: 1)
            item?.isHidden = listSeparatorHidden
        } else if let cmd = CommandCatalog.command(CommandID(ident.rawValue)) {
            item = makeItem(cmd, ident)
            if let v = lastVisible { item?.isHidden = !v.contains(cmd.id) }
        } else {
            item = nil
        }
        items[ident] = item
        return item
    }

    private func makeItem(_ cmd: Command, _ ident: NSToolbarItem.Identifier) -> NSToolbarItem {
        let image = cmd.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: cmd.title) }
        if cmd.id == ShellCommand.search {
            let s = NSSearchToolbarItem(itemIdentifier: ident)
            s.searchField.delegate = self
            s.searchField.focusRingType = .none // §10: no drawn ring
            s.searchField.placeholderString = "Search"
            s.searchField.searchMenuTemplate = Self.recentsMenu()
            // A recent picked from the menu arrives as the field's action
            // (no text-change notification).
            s.searchField.target = self
            s.searchField.action = #selector(searchFieldAction(_:))
            s.preferredWidthForSearchField = 220
            s.label = "Search"
            s.toolTip = "Search (⌥⌘F)"
            return s
        }
        if cmd.isSubmenu {
            let m = ValidatedMenuToolbarItem(itemIdentifier: ident)
            m.controller = owner
            let menu = NSMenu(title: cmd.title)
            let d = DynamicMenuDelegate(cmd.id, controller: owner)
            menuDelegates.append(d)
            menu.delegate = d
            menu.autoenablesItems = false
            m.menu = menu
            m.image = image
            m.label = cmd.title
            m.toolTip = cmd.title
            m.showsIndicator = true
            return m
        }
        let t = NSToolbarItem(itemIdentifier: ident)
        // Call items with their own view: the toolbar call item (duration
        // + menu) and the Devices popover anchor (§8, Call/).
        if let v = CallToolbarViews.view(for: cmd.id, model: owner?.model) {
            t.view = v
            t.label = cmd.title
            t.toolTip = cmd.title
            return t
        }
        if cmd.id == ShellCommand.connection {
            let b = NSButton(title: cmd.title, image: image ?? NSImage(), target: self,
                             action: #selector(connectionClicked(_:)))
            b.bezelStyle = .toolbar
            b.imagePosition = .imageLeading
            b.setButtonType(.momentaryPushIn)
            t.view = b
            t.label = cmd.title
            t.toolTip = cmd.title
            return t
        }
        if Self.textItems.contains(cmd.id) {
            t.title = cmd.title
        } else {
            t.image = image
        }
        t.label = cmd.title
        t.toolTip = cmd.help ?? cmd.title
        t.isBordered = true
        t.isNavigational = Self.navigational.contains(cmd.id)
        if cmd.id == CallCommands.leave {
            // Leave: the one primary action, trailing, red (§8).
            t.style = .prominent
            t.backgroundTintColor = .systemRed
        }
        t.action = #selector(ShellWindowController.performCommand(_:))
        t.target = nil
        return t
    }

    // MARK: search field (§5.5)

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSSearchField else { return }
        textChanged(field.stringValue)
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        textChanged(sender.stringValue)
    }

    private func textChanged(_ text: String) {
        // Find in Page (⌘F in a web app, §5.5): no search mode, no debounce.
        if let host = owner?.model.frameHost, host.findKey != nil {
            host.find(text)
            return
        }
        if text.isEmpty {
            debounce.cancel()
            owner?.navigator.endSearch()
            return
        }
        debounce.schedule { [weak self] in
            guard let owner = self?.owner else { return }
            owner.navigator.beginSearch(query: text, scope: owner.model.nav.search?.scope
                                            ?? Navigator.initialScope(for: owner.model.nav.section))
        }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        debounce.cancel()
        if owner?.model.frameHost.findKey != nil {
            owner?.navigator.endPageFind()
            return
        }
        owner?.navigator.endSearch()
    }

    /// Return opens the selected (else top) result and leaves search;
    /// ↑/↓ move through the results without leaving the field (§5.5).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchItem?.searchField, let m = owner?.model else { return false }
        if m.frameHost.findKey != nil {
            // Return / ⇧Return step through matches; Esc leaves Find in Page.
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                m.frameHost.findAgain(backwards: NSEvent.modifierFlags.contains(.shift))
            case #selector(NSResponder.cancelOperation(_:)):
                owner?.navigator.endPageFind()
            default:
                return false
            }
            return true
        }
        guard m.nav.search != nil else { return false }
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            m.search.activate(m.search.selected)
        case #selector(NSResponder.moveDown(_:)):
            m.search.step(1)
        case #selector(NSResponder.moveUp(_:)):
            m.search.step(-1)
        default:
            return false
        }
        return true
    }

    func controlTextDidBeginEditing(_ note: Notification) {
        guard let field = note.object as? NSSearchField, field === searchItem?.searchField else { return }
        field.recentSearches = owner?.model.app?.searchRecents.recents ?? []
    }

    func clearSearch() {
        debounce.cancel()
        searchItem?.searchField.stringValue = ""
        searchItem?.searchField.placeholderString = "Search"
    }

    /// Shows the active query (a search begun by route or Go To) without
    /// touching a field the person is typing in.
    func showQuery(_ q: String?) {
        guard let q, let field = searchItem?.searchField, field.stringValue.isEmpty,
              field.currentEditor() == nil else { return }
        field.stringValue = q
    }

    /// Recent searches (SearchRecentsStore) as the field's native menu.
    private static func recentsMenu() -> NSMenu {
        let menu = NSMenu(title: "Recent Searches")
        let title = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
        title.tag = NSSearchField.recentsTitleMenuItemTag
        menu.addItem(title)
        let recents = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recents.tag = NSSearchField.recentsMenuItemTag
        menu.addItem(recents)
        let none = NSMenuItem(title: "No Recent Searches", action: nil, keyEquivalent: "")
        none.tag = NSSearchField.noRecentsMenuItemTag
        menu.addItem(none)
        return menu
    }
}

/// Rebuilds a dynamic submenu (Status, Filter) from its owner each time
/// it opens. Shared by the toolbar and the menu bar (R19).
@MainActor
/// A pull-down toolbar item validated like the action items (R19):
/// `NSMenuToolbarItem` has no action, so toolbar autovalidation never
/// asked the responder chain and it stayed enabled with nothing to act
/// on (Activity filter with no items).
final class ValidatedMenuToolbarItem: NSMenuToolbarItem {
    weak var controller: ShellWindowController?

    override func validate() {
        guard let c = controller ?? ShellWindowController.current else { return }
        let on = c.validate(CommandID(itemIdentifier.rawValue)).enabled
        if isEnabled != on { isEnabled = on }
    }
}

final class DynamicMenuDelegate: NSObject, NSMenuDelegate {
    let id: CommandID
    private weak var controller: ShellWindowController?

    init(_ id: CommandID, controller: ShellWindowController?) {
        self.id = id
        self.controller = controller
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let c = controller ?? ShellWindowController.current else { return }
        for sub in c.submenuItems(id) {
            if sub.separatorBefore, !menu.items.isEmpty { menu.addItem(.separator()) }
            let mi = NSMenuItem(title: sub.title, action: #selector(ShellWindowController.performCommand(_:)),
                                keyEquivalent: "")
            mi.target = c
            mi.representedObject = "\(id.rawValue)|\(sub.arg)"
            mi.state = sub.checked ? .on : .off
            mi.isEnabled = sub.enabled
            if let s = sub.symbol { mi.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
            menu.addItem(mi)
        }
    }
}
