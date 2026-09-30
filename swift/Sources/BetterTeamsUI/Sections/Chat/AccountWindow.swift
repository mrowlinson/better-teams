// AccountWindow.swift — REGFIX-C R1: side-by-side windows for two signed-in
// accounts. Account menu ▸ "Open <name> in New Window" (and Settings ▸
// Accounts ▸ Open in New Window) opens one native window per account beside
// the main window: a sidebar list of that account's chats and the open
// conversation, both bound to the account's own graph in core
// (AppState.openAccountWindow / AccountWindowGraph: per-profile list reads,
// stamped conversation, window-local unread). One window per account: a
// second open brings the first forward; closing keeps the graph (selection
// and loaded messages come back on re-open) and folds the window's unread
// into the background roll-up (AppState.closeAccountWindow).
import AppKit
import OstMacCore
import SwiftUI

@MainActor
final class AccountWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: AccountWindowController] = [:]
    private weak var app: AppState?
    let accountID: String

    static let autosaveName = "AccountWindow"

    /// Open (or bring forward) the account's window.
    static func show(_ m: WindowModel, accountID: String) {
        guard let app = m.app, !m.options.demo else { return }
        if let c = open[accountID] { PopOutPresenter.present(c); return }
        guard let id = app.openAccountWindow(accountID: accountID),
              let graph = app.accountWindows.graph(for: id) else { return }
        let c = AccountWindowController(model: m, app: app, graph: graph)
        let prev = open.values.compactMap(\.window).last { $0.isVisible }
        open[id] = c
        if let prev, let w = c.window {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: prev.frame.minX, y: prev.frame.maxY)))
        } else if UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") == nil {
            c.window?.center()
        }
        PopOutPresenter.present(c)
    }

    /// The open window for an account, if any (tests, evidence).
    static func window(for accountID: String) -> NSWindow? { open[accountID]?.window }

    private init(model m: WindowModel, app: AppState, graph: AccountWindowGraph) {
        self.app = app
        accountID = graph.account.id
        let size = NSSize(width: 900, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = graph.account.displayName
        window.subtitle = graph.account.upn ?? ""
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        let host = Hosting.controller(AccountWindowView(graph: graph), role: .pane, model: m)
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = host
        window.setContentSize(size)
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) {
        app?.closeAccountWindow(accountID: accountID)
        if Self.open[accountID] === self { Self.open[accountID] = nil }
    }
}

/// Sidebar (the account's chats) and detail (the open conversation) in the
/// standard two-column split.
struct AccountWindowView: View {
    @ObservedObject var graph: AccountWindowGraph
    @ObservedObject private var chats: ChatListViewModel
    @ObservedObject private var unread: UnreadStore
    @StateObject private var chrome = PopoutChrome()

    init(graph: AccountWindowGraph) {
        self.graph = graph
        _chats = ObservedObject(wrappedValue: graph.chats)
        _unread = ObservedObject(wrappedValue: graph.unread)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .task { if chats.chats.isEmpty { await chats.load() } }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch chats.state {
        case .loading where chats.chats.isEmpty:
            LoadingPane("Loading Chats\u{2026}")
        case .error(let message) where chats.chats.isEmpty:
            ErrorPane(title: "Couldn\u{2019}t Load Chats", message: message) { chats.refresh() }
        case .empty:
            EmptyPane("No Chats", systemImage: "bubble.left", message: "This account has no chats yet.")
        default:
            List(selection: $chats.selectedChatID) {
                ForEach(chats.displayChats) { c in
                    ChatRow(chat: c, unread: unread.isUnread(chatID: c.id), pinned: chats.isPinned(c.id),
                            mentioned: false, presence: nil, conv: graph.conv, now: Date())
                        .tag(c.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = graph.openChatID {
            ChatPopoutView(chats: chats, conv: graph.conv, chrome: chrome, chatID: id)
        } else {
            EmptyPane("No Chat Selected", systemImage: "bubble.left.and.bubble.right",
                      message: "Choose a chat from the list.")
        }
    }
}
