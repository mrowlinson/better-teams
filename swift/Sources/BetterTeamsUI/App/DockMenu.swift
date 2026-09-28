// DockMenu.swift — the Dock menu (UI-SPEC §9.2, `applicationDockMenu`):
// New Chat, Set Status ▸, up to five unread chats. The menu bar extra
// (StatusItemController.swift) shares the unread-chat items and the
// actions.
import AppKit
import OstMacCore

@MainActor
enum DockMenu {
    /// Most recent unread chats, at most `limit` (§9.2: five).
    static func unreadChats(_ m: WindowModel, limit: Int = 5) -> [(id: String, name: String)] {
        let unread = m.graph.unread
        return m.graph.chats.chats.lazy
            .filter { unread.isUnread(chatID: $0.id) }
            .prefix(limit)
            .map { (id: $0.id, name: $0.name.isEmpty ? "Conversation" : $0.name) }
    }

    static func build(_ wc: ShellWindowController) -> NSMenu {
        let menu = NSMenu(title: "Dock")
        menu.autoenablesItems = false
        menu.addItem(AppMenuActions.newChatItem())
        menu.addItem(AppMenuActions.statusItem("Set Status", wc))
        AppMenuActions.addUnreadChats(to: menu, wc.model)
        return menu
    }
}

/// Targets for the Dock menu and the menu bar extra: they act on the
/// main window through `Navigator` (R21), bringing it forward.
@MainActor
final class AppMenuActions: NSObject {
    static let shared = AppMenuActions()

    static func newChatItem() -> NSMenuItem {
        let item = NSMenuItem(title: "New Chat", action: #selector(newChat(_:)), keyEquivalent: "")
        item.target = shared
        return item
    }

    /// Presence submenu: the account menu's items (§9.1 Status ▸).
    static func statusItem(_ title: String, _ wc: ShellWindowController) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        let d = DynamicMenuDelegate(ShellCommand.account, controller: wc)
        shared.trimDelegates(keep: 3)
        shared.delegates.append(d)
        sub.delegate = d
        sub.autoenablesItems = false
        item.submenu = sub
        return item
    }

    static func addUnreadChats(to menu: NSMenu, _ m: WindowModel) {
        let chats = DockMenu.unreadChats(m)
        guard !chats.isEmpty else { return }
        menu.addItem(.separator())
        for c in chats {
            let item = NSMenuItem(title: c.name, action: #selector(openChat(_:)), keyEquivalent: "")
            item.target = shared
            item.representedObject = c.id
            menu.addItem(item)
        }
    }

    /// Submenu delegates stay alive while their menus can open (menus
    /// hold delegates weakly); rebuilt menus replace them.
    private var delegates: [DynamicMenuDelegate] = []

    private var shell: ShellWindowController? { ShellWindowController.current }

    @objc func newChat(_ sender: Any?) {
        guard let wc = shell else { return }
        bringForward(wc)
        wc.navigator.select(section: .chat)
        wc.model.presentSheet(SheetRequest(ChatCommands.newChatSheet, in: .chat))
    }

    @objc func openChat(_ sender: Any?) {
        guard let wc = shell, let id = (sender as? NSMenuItem)?.representedObject as? String else { return }
        bringForward(wc)
        wc.navigator.apply(Route(path: ["chat", id]))
    }

    @objc func openApp(_ sender: Any?) {
        guard let wc = shell else { return }
        bringForward(wc)
    }

    private func bringForward(_ wc: ShellWindowController) {
        NSApp.activate()
        wc.window?.makeKeyAndOrderFront(nil)
    }

    /// Menus are rebuilt on each open; drop delegates of closed menus.
    func trimDelegates(keep: Int) {
        if delegates.count > keep { delegates.removeFirst(delegates.count - keep) }
    }
}
