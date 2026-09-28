// SettingsWindowController.swift — the Settings window (UI-SPEC §9.4):
// an `NSTabViewController` with `tabStyle = .toolbar` (non-customizable
// toolbar of labeled panes), window title follows the pane, last pane
// restored, minimize and zoom disabled. Each pane is a `Hosting`
// controller (R22, role `.settings`) around a grouped `Form`; changes
// apply immediately.
//
// Panes are listed in the spec's order, one file per pane. Panes bind
// to the core stores of the main window's account (`model`, set by the
// app delegate); demo runs bind to the demo stores (in-memory
// defaults), so a demo session never reads or writes real settings.
import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    /// One pane: id (route `settings/<id>`), label, symbol, body.
    struct Pane {
        let id: String
        let label: String
        let symbol: String
        let make: @MainActor () -> NSViewController
    }

    /// The main window whose account the panes edit (weak; set at launch).
    static weak var model: WindowModel?

    static let panes: [Pane] = [
        Pane(id: "general", label: "General", symbol: "gearshape") {
            host(GeneralPane(settings: .shared, login: model?.options.demo == false ? model?.app?.loginItems : nil))
        },
        Pane(id: "accounts", label: "Accounts", symbol: "person.crop.circle") {
            host(AccountsPane.make(model))
        },
        Pane(id: "notifications", label: "Notifications", symbol: "bell.badge") {
            host(NotificationsPane.make(model))
        },
        Pane(id: "chats", label: "Chats", symbol: "bubble.left") {
            host(ChatsPane.make(model))
        },
        Pane(id: "calls", label: "Calls", symbol: "video") {
            host(CallsSettingsPane(settings: .shared, devices: CallsSettingsPane.devices(model), model: model))
        },
        Pane(id: "apps", label: "Apps", symbol: "square.grid.2x2") {
            host(AppsPane.make(model))
        },
        Pane(id: "ai", label: "AI", symbol: "sparkles") {
            host(AIPane.make(model))
        },
        Pane(id: "advanced", label: "Advanced", symbol: "wrench.and.screwdriver") {
            host(AdvancedPane.make(model))
        },
    ]

    private static func host<V: View>(_ v: V) -> NSViewController {
        Hosting.controller(v, role: .settings, model: model)
    }

    /// Evidence: the Settings window if it was ever created (never
    /// creates it).
    private(set) static weak var loaded: SettingsWindowController?

    private static let lastPaneKey = "bt.settings.lastPane"
    private let tabs = SettingsTabs()
    /// Evidence and demo runs never read or write the last-pane
    /// preference. Static so setting it never creates the window: panes
    /// are built on first use, after the app sets `model`.
    static var persists = true
    private var persists: Bool { Self.persists }

    private init() {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for p in Self.panes {
            let vc = p.make()
            vc.title = p.label
            let item = NSTabViewItem(viewController: vc)
            item.identifier = p.id
            item.label = p.label
            item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.label)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .preference
        window.toolbar?.allowsUserCustomization = false
        super.init(window: window)
        window.delegate = self
        tabs.onSelect = { [weak self] in self?.syncTitle() }
        Self.loaded = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Shows Settings on `pane` (else the last pane). Evidence orders the
    /// window in without activating the app or taking key (§11.4).
    public func show(pane: String? = nil, evidence: Bool = false) {
        let saved = persists ? UserDefaults.standard.string(forKey: Self.lastPaneKey) : nil
        let id = pane ?? saved ?? Self.panes.first?.id
        if let i = Self.panes.firstIndex(where: { $0.id == id }) { tabs.selectedTabViewItemIndex = i }
        syncTitle()
        if evidence {
            window?.center()
            window?.orderFrontRegardless()
        } else {
            if window?.isVisible != true { window?.center() }
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func syncTitle() {
        let i = tabs.selectedTabViewItemIndex
        guard Self.panes.indices.contains(i) else { return }
        window?.title = Self.panes[i].label
        if persists { UserDefaults.standard.set(Self.panes[i].id, forKey: Self.lastPaneKey) }
    }
}

/// Title follows the pane (§9.4): the tab controller reports selection.
@MainActor
private final class SettingsTabs: NSTabViewController {
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        onSelect?()
    }
}
