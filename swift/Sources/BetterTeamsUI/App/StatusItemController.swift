// StatusItemController.swift — the menu bar extra (UI-SPEC §9.2):
// Settings ▸ General ▸ "Show in menu bar", off by default. An
// `NSStatusItem` with `bubble.left.and.bubble.right`, plus a dot when a
// chat is unread. It opens an NSMenu, not a popover: Presence ▸, up to
// five unread chats, New Chat, Open Better Teams, Quit. Evidence runs
// never add a status item to the owner's menu bar.
import AppKit
import Combine
import OstMacCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private weak var shell: ShellWindowController?
    private var item: NSStatusItem?
    private var subs: Set<AnyCancellable> = []
    private var queued = false

    init(shell: ShellWindowController) {
        self.shell = shell
        super.init()
        guard !shell.model.options.evidence else { return }
        AppSettings.shared.changes.sink { [weak self] in self?.queueSync() }.store(in: &subs)
        shell.model.graph.unread.objectWillChange.sink { [weak self] _ in self?.queueSync() }.store(in: &subs)
        sync()
    }

    private func queueSync() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.sync()
        }
    }

    private func sync() {
        guard AppSettings.shared.showInMenuBar, let wc = shell else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let it = item ?? {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu(title: "Better Teams")
            menu.delegate = self
            i.menu = menu
            item = i
            return i
        }()
        let unread = wc.model.graph.unread.chatCount > 0
        it.button?.image = Self.image(unread: unread)
        it.button?.setAccessibilityLabel(unread ? "Better Teams, unread messages" : "Better Teams")
    }

    /// Template symbol, with a dot at the top trailing corner when unread.
    static func image(unread: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "bubble.left.and.bubble.right",
                                   accessibilityDescription: "Better Teams") else { return nil }
        guard unread else {
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: symbol.size.width + 3, height: symbol.size.height)
        let img = NSImage(size: size, flipped: false) { r in
            symbol.draw(in: NSRect(x: 0, y: 0, width: symbol.size.width, height: symbol.size.height))
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 6, y: r.maxY - 6, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Contents, in order (§9.2); rebuilt each time the menu opens.
    static func build(_ menu: NSMenu, _ wc: ShellWindowController) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(AppMenuActions.statusItem("Presence", wc))
        AppMenuActions.addUnreadChats(to: menu, wc.model)
        menu.addItem(.separator())
        menu.addItem(AppMenuActions.newChatItem())
        let open = NSMenuItem(title: "Open Better Teams", action: #selector(AppMenuActions.openApp(_:)), keyEquivalent: "")
        open.target = AppMenuActions.shared
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Better Teams", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let wc = shell else { return }
        Self.build(menu, wc)
    }
}
