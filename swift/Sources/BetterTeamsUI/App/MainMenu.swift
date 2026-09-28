// MainMenu.swift — the menu bar, generated from CommandCatalog (UI-SPEC
// §9.1, R19). Standard menu order; unavailable items are disabled,
// never hidden; Show/Hide titles come from validation.
import AppKit

@MainActor
enum MainMenu {
    private static var delegates: [DynamicMenuDelegate] = []

    static func build() -> NSMenu {
        let bar = NSMenu(title: "Main")
        for menu in CommandMenu.allCases {
            let cmds = CommandCatalog.all
                .filter { $0.menu?.menu == menu }
                .sorted { ($0.menu!.group, $0.menu!.order) < ($1.menu!.group, $1.menu!.order) }
            let top = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: menu.title)
            top.submenu = sub
            var lastGroup: Int?
            var nested: [String: NSMenu] = [:]
            for c in cmds {
                let g = c.menu!.group
                if menu == .app, g >= 3, (lastGroup ?? 0) < 2 {
                    sub.addItem(.separator())
                    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
                    let sm = NSMenu(title: "Services")
                    services.submenu = sm
                    NSApp.servicesMenu = sm
                    sub.addItem(services)
                    lastGroup = 2
                }
                if let last = lastGroup, last != g { sub.addItem(.separator()) }
                lastGroup = g
                let item = menuItem(c)
                if let title = c.menu!.submenu {
                    if let m = nested[title] {
                        m.addItem(item)
                    } else {
                        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                        let m = NSMenu(title: title)
                        holder.submenu = m
                        m.addItem(item)
                        nested[title] = m
                        sub.addItem(holder)
                    }
                } else {
                    sub.addItem(item)
                }
            }
            switch menu {
            case .window: NSApp.windowsMenu = sub
            case .help: NSApp.helpMenu = sub
            default: break
            }
            bar.addItem(top)
        }
        return bar
    }

    static func menuItem(_ c: Command) -> NSMenuItem {
        if c.isSubmenu {
            let item = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: c.title)
            let d = DynamicMenuDelegate(c.id, controller: nil)
            delegates.append(d)
            m.delegate = d
            m.autoenablesItems = false
            item.submenu = m
            return item
        }
        let item = NSMenuItem(title: c.title, action: c.selector ?? #selector(ShellWindowController.performCommand(_:)),
                              keyEquivalent: c.key)
        item.keyEquivalentModifierMask = c.key.isEmpty ? [] : c.modifiers
        if c.selector == nil { item.representedObject = c.id.rawValue }
        item.toolTip = c.help
        return item
    }

    /// Evidence: the validated menu bar as text (menus can't be
    /// screen-captured without opening them).
    static func dump(_ menu: NSMenu, depth: Int = 0) -> String {
        var out = ""
        menu.update()
        for item in menu.items {
            let pad = String(repeating: "  ", count: depth)
            if item.isSeparatorItem {
                out += "\(pad)---\n"
                continue
            }
            if let sub = item.submenu, sub.delegate != nil {
                sub.delegate?.menuNeedsUpdate?(sub)
            }
            var key = ""
            if !item.keyEquivalent.isEmpty {
                let m = item.keyEquivalentModifierMask
                key = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
                    + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
                    + item.keyEquivalent.uppercased()
            }
            let state = item.state == .on ? " ✓" : ""
            let enabled = item.isEnabled ? "" : " (disabled)"
            out += "\(pad)\(item.title)\(key.isEmpty ? "" : "  \(key)")\(state)\(enabled)\n"
            if let sub = item.submenu, item.title != "Services" {
                out += dump(sub, depth: depth + 1)
            }
        }
        return out
    }
}
