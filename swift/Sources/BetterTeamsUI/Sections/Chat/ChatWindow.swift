// ChatWindow.swift — CHATSYNC2b R4: a chat in its own window (chat row
// menu ▸ Pop Out Chat, Teams "Pop out chat"). One window per chat; it
// keeps its own timeline store (pop-out registry) so the main window's
// selection never moves, live messages reach both, and own sends show in
// both (PopOutStore mirroring). The timeline reports the newest message
// to ReadSync only while this window is key (TimelineViewController gate
// + AppState.noteViewingLatest: popped chats count as open).
import AppKit
import OstMacCore
import SwiftUI
import Translation

@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: ChatWindowController] = [:]
    private weak var app: AppState?
    let chatID: String
    /// The window's own tab (the main window's selection never moves).
    let chrome = PopoutChrome()
    /// The window's toolbar delegate (NSToolbar holds it weakly).
    private let toolbarController: PopoutToolbar

    /// Open (or bring forward) the chat's window.
    static func show(_ m: WindowModel, chatID: String) {
        guard let app = m.app else { return }
        if let c = open[chatID] {
            PopOutPresenter.present(c)
            return
        }
        guard let id = app.popOut(chatID: chatID) else { return }
        app.openPopout(chatID: id)
        let c = ChatWindowController(model: m, app: app, chatID: id)
        // Another chat window open: cascade from it (the saved frame
        // belongs to one window at a time).
        let prev = open.values.compactMap(\.window).last { $0.isVisible }
        open[id] = c
        if let prev, let w = c.window {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: prev.frame.minX, y: prev.frame.maxY)))
        } else if UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") == nil {
            c.window?.center()
        }
        PopOutPresenter.present(c)
    }

    static let autosaveName = "ChatPopoutWindow"

    /// The open chat window for a chat, if any (tests, evidence).
    static func window(for chatID: String) -> NSWindow? { open[chatID]?.window }

    private init(model m: WindowModel, app: AppState, chatID: String) {
        self.app = app
        self.chatID = chatID
        toolbarController = PopoutToolbar(model: m, chatID: chatID, chrome: chrome)
        // The window exists at its size before the content arrives, so the
        // timeline never lays rows out at a transient fitting width
        // (NSWindow(contentViewController:) sizes to the content first).
        let size = NSSize(width: 640, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = app.popoutName(for: chatID)
        // CHATSYNC3 R2: a native unified toolbar with the Chat | Shared
        // segmented control and the call buttons; the chat's identity
        // (avatar, name, status) sits at the leading edge as plain title
        // content (a titlebar accessory, no glass: it is not a control),
        // like Mail's title. The window title stays set for the Window menu.
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.toolbar = toolbarController.makeToolbar()
        window.addTitlebarAccessoryViewController(toolbarController.makeIdentityAccessory())
        // Wide enough for the content-fitted identity, a meeting chat's four
        // tabs and the call buttons side by side; narrower, the tab control collapses
        // to a pop-up button as AppKit does, then items overflow to ».
        window.contentMinSize = NSSize(width: 440, height: 360)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        let root = ChatPopoutView(chats: app.chats, conv: app.popouts.store(for: chatID), chrome: chrome, chatID: chatID)
        let host = Hosting.controller(root, role: .pane, model: m)
        host.view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        window.contentViewController = host
        window.setContentSize(size)
        // CHATSYNC3 R2: new name, so earlier 520 pt saved frames give way
        // to the toolbar's width.
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) {
        app?.popouts.close(chatID: chatID)
        if Self.open[chatID] === self { Self.open[chatID] = nil }
    }
}

/// A popped-out chat's native toolbar (CHATSYNC3 R2): the chat's identity
/// at the leading edge where a window title sits (titlebar accessory), the Chat | Shared
/// segmented control centered (Notes/Recap too where the chat kind has
/// them, as in the main window), and the call buttons as standard toolbar
/// items at the trailing edge, enabled by the same rule as the main
/// window's header.
@MainActor
final class PopoutToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    static let tabsItem = NSToolbarItem.Identifier("chat.popout.tabs")
    static let videoItem = NSToolbarItem.Identifier(ChatCommands.videoCall.rawValue)
    static let audioItem = NSToolbarItem.Identifier(ChatCommands.audioCall.rawValue)

    let chatID: String
    let chrome: PopoutChrome
    /// Built-in tabs for this chat's kind, in segment order.
    let tabs: [ConversationTab]
    private weak var model: WindowModel?

    init(model: WindowModel, chatID: String, chrome: PopoutChrome) {
        self.model = model
        self.chatID = chatID
        self.chrome = chrome
        let isGroup = model.app?.chats.chat(id: chatID)?.is_group ?? false
        tabs = ChatTabCatalog.builtins(for: ChatKind.of(chatID: chatID, isGroup: isGroup))
            .compactMap(ConversationTab.init(rawValue:))
    }

    /// The chat's identity at the toolbar's leading edge, right of the
    /// window buttons: plain title content (avatar, name, status), not a
    /// glass toolbar control, since clicking it does nothing (Mail's title).
    func makeIdentityAccessory() -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        if let model, let app = model.app {
            let refit = IdentityRefit()
            let host = Hosting.view(PopoutContactView(chats: app.chats, chatID: chatID,
                                                      onWidth: { [weak refit] in refit?.host.map(Self.fit) }),
                                    role: .cell, model: model)
            refit.host = host
            identityBox = refit
            // Fitted to its content (a short name leaves the tabs room to
            // center); a later name or status change re-fits, and a long
            // one truncates inside PopoutContactView.size.width.
            Self.fit(host)
            accessory.view = host
        } else {
            accessory.view = NSView(frame: .zero)
        }
        return accessory
    }

    /// Keeps the identity's host reachable from its own width report
    /// (name, presence or member count changed after opening).
    @MainActor final class IdentityRefit { weak var host: NSView? }
    private var identityBox: IdentityRefit?

    /// Sizes the identity accessory to its content, capped at
    /// `PopoutContactView.size.width`.
    static func fit(_ host: NSView) {
        let w = min(max(host.fittingSize.width, 60), PopoutContactView.size.width)
        let size = NSSize(width: w.rounded(.up), height: PopoutContactView.size.height)
        if host.frame.size != size { host.setFrameSize(size) }
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "chat.popout")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.tabsItem]
        return toolbar
    }

    private var identifiers: [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.tabsItem, .flexibleSpace, Self.videoItem, Self.audioItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier ident: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch ident {
        case Self.tabsItem:
            let titles = tabs.map(\.title)
            let group = NSToolbarItemGroup(itemIdentifier: ident, titles: titles, selectionMode: .selectOne,
                                           labels: titles, target: self, action: #selector(pickTab(_:)))
            group.label = "Tabs"
            group.toolTip = "Show " + ListFormatter.localizedString(byJoining: titles).replacingOccurrences(of: " and ", with: " or ")
            group.selectedIndex = tabs.firstIndex(of: chrome.tab) ?? 0
            return group
        case Self.videoItem, Self.audioItem:
            let video = ident == Self.videoItem
            let cmd = CommandCatalog.command(video ? ChatCommands.videoCall : ChatCommands.audioCall)
            let item = NSToolbarItem(itemIdentifier: ident)
            item.label = cmd?.title ?? (video ? "Start Video Call" : "Start Audio Call")
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: video ? "video" : "phone", accessibilityDescription: item.label)
            item.isBordered = true
            item.visibilityPriority = .high // the last to overflow
            item.target = self
            item.action = video ? #selector(startVideoCall(_:)) : #selector(startAudioCall(_:))
            return item
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard item.itemIdentifier == Self.videoItem || item.itemIdentifier == Self.audioItem, let model else { return true }
        return ConversationToolbar.canStartCall(model, for: chatID)
    }

    @objc func pickTab(_ sender: NSToolbarItemGroup) {
        guard tabs.indices.contains(sender.selectedIndex) else { return }
        chrome.tab = tabs[sender.selectedIndex]
    }

    @objc private func startVideoCall(_ sender: Any?) {
        guard let model else { return }
        ConversationToolbar.startVideoCall(model, for: chatID)
    }

    @objc private func startAudioCall(_ sender: Any?) {
        guard let model else { return }
        ConversationToolbar.startAudioCall(model, for: chatID)
    }
}

/// A popped-out chat's selected tab (toolbar segmented control -> content).
@MainActor
final class PopoutChrome: ObservableObject {
    @Published var tab: ConversationTab = .chat
}

/// The toolbar's identity item: avatar, name, and the main header's
/// status line (presence for 1:1 chats, member count for groups).
struct PopoutContactView: View {
    /// The accessory's largest size: 24 pt avatar + up to 120 pt of text (a 4-tab chat still fits its tabs and calls at 640 pt).
    static let size = NSSize(width: 164, height: 36)
    @ObservedObject var chats: ChatListViewModel
    let chatID: String
    var onWidth: () -> Void = {}
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let row = chats.chat(id: chatID)
            let name = row?.name ?? model.app?.popoutName(for: chatID) ?? "Chat"
            let isGroup = row?.is_group ?? false
            RosterBound(chatID: chatID, roster: model.app?.chatRoster, loads: true) { count in
                let subtitle = isGroup
                    ? ConversationDetail.subtitle(isGroup: true, messages: [], rosterCount: count)
                    : PresenceLine(presence: model.app?.presence, chatID: chatID).text
                HStack(spacing: 8) {
                    Avatar(name: name, isGroup: isGroup, diameter: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).font(.headline).lineLimit(1).truncationMode(.tail)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    // Long names end in "…", never clipped.
                    .frame(maxWidth: 120, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: Self.size.height, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in onWidth() }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The window's content under the toolbar: the selected tab (Chat =
/// timeline + composer; Shared, Notes, Recap as in the main window).
struct ChatPopoutView: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var conv: ConversationStore
    @ObservedObject var chrome: PopoutChrome
    let chatID: String
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let row = chats.chat(id: chatID)
            let name = row?.name ?? (conv.chatID == chatID ? conv.headerTitle : model.app?.popoutName(for: chatID) ?? "Chat")
            ChatTabBody(selected: .builtin(chrome.tab), chatID: chatID, name: name, pinned: [], app: model.app) {
                content(name: name, model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: name) { _, new in
                ChatWindowController.window(for: chatID)?.title = new
            }
        }
    }

    @ViewBuilder
    private func content(name: String, _ m: WindowModel) -> some View {
        let services = ConversationServices.of(m)
        if conv.chatID != chatID || (conv.loading && conv.messages.isEmpty) {
            LoadingPane("Loading Messages\u{2026}")
        } else if let err = conv.error, conv.messages.isEmpty {
            ErrorPane(title: m.connection == .offline ? "You're Offline" : "Couldn't Load Messages",
                      message: err) { conv.retryOpen() }
        } else {
            VStack(spacing: 0) {
                if conv.messages.isEmpty {
                    EmptyPane("No Messages Yet", systemImage: "bubble.left",
                              message: "Send a message to start the conversation.")
                } else {
                    TimelineRepresentable(conv: conv)
                        .refreshStatus(conv.refreshing, failure: conv.refreshError,
                                       label: "Updating Messages", retry: { conv.refresh() })
                        .refreshStatus(conv.loadingMore, label: "Loading Earlier Messages", alignment: .top)
                }
                Divider()
                Composer(chatID: chatID, chatName: name, placeholder: "Message \(name)", conv: conv,
                         composer: services.composer, attachments: services.attachments, services: services)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                services.attachments.stage(urls: files)
                return true
            }
            .translationTask(TranslationSession.Configuration(target: services.translation.sessionTarget)) { session in
                services.translation.attached(session)
            }
        }
    }
}
