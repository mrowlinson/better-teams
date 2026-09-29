// AccountWindows.swift — gap-g2: side-by-side account windows.
//
// One window per account beside the main window. Each window owns a
// graph (chat list + open conversation + unread + pins/saves) bound
// to its account's profile:
//
//   list    — per-profile fetcher (CoreReads needs no flip)
//   conv    — stamped accountID + the App's flip-flop runner (history,
//             sends, reacts land on the window's account)
//   unread  — window-local counts, NullDockBadge (the dock stays the
//             main window's; close drains counts back into the g1
//             roll-up so a later switch still lands on unread N)
//   pins / saved — per-account persisted namespaces (same keys the
//             main window rebuilds on switch)
//
// Live updates (feed fan-out ×2): the App routes every event to the
// registry beside the main path — live trouter events (nil-stamped =
// active) and background poller arrivals (stamped inactive) alike.
// The graph bumps its list, accrues its own unread, and appends to
// its open conversation; the main selection never moves for window
// traffic. The App already ran the rules decision — the graph never
// re-decides (one ChatFilter claim per event, never double-claimed).
//
// Close loses no state (PopOutStore contract): `close` drops the
// visible flag only — the graph (selection, loaded bubbles, unread,
// pins/saves) stays cached, so re-open restores with no reload.
// `drop` evicts the graph (remove-account).
//
// Out of scope by design: leave/block from the window (the list view
// offers no entry — active-profile FFI), Shared/Notes tabs (window
// instances stay un-opened), typing/presence/call (main-window
// shares), demo mode (the switcher hides in demo, so no entry).
import Combine
import Foundation

/// Per-account window state: list + conversation + unread + pins/saves.
@MainActor
public final class AccountWindowGraph: ObservableObject {
    public let account: AccountRecord
    public let chats: ChatListViewModel
    public let conv = ConversationStore()
    public let unread: UnreadStore
    public let pins: PinnedMessageStore
    public let saved: SavedMessageStore

    @Published public var openChatID: String?

    private var cancellables = Set<AnyCancellable>()

    /// `chats`/`pins`/`saved` default to live per-account instances;
    /// tests inject stubs. `runner` defaults direct (active-profile
    /// graphs); the App injects its flip-flop for every window graph.
    public init(
        account: AccountRecord,
        chats: ChatListViewModel? = nil,
        runner: (any AccountCoreRunner)? = nil,
        pins: PinnedMessageStore? = nil,
        saved: SavedMessageStore? = nil
    ) {
        self.account = account
        self.chats = chats ?? ChatListViewModel(
            fetcher: { try RustCore.chats(limit: $0, profile: account.id) },
            pageFetcher: { try RustCore.chats(limit: 50, profile: account.id, pageLink: $0) },
            blocked: BlockedStore(key: BlockedStore.key(for: account.id)),
            folders: FolderStore(accountID: account.id))
        self.unread = UnreadStore(dock: NullDockBadge())
        self.pins = pins ?? PinnedMessageStore(
            key: PinnedMessages.key(for: account.id))
        self.saved = saved ?? SavedMessageStore(
            key: SavedMessages.key(for: account.id))
        conv.accountID = account.id
        conv.coreRunner = runner ?? DirectAccountCoreRunner()
        conv.historyCache = .disk(for: account.id) // histload
        // Sidebar selection sink (main-window wireChats shape): list
        // picks open here, never in the main window.
        self.chats.$selectedChatID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                Task { @MainActor [weak self] in self?.openSelected(id) }
            }
            .store(in: &cancellables)
    }

    /// Open a chat in this window: selection, read-mark, history load
    /// (flip-flop when the account is inactive). Re-open of the open
    /// chat is a no-op.
    public func open(chatID id: String, chatName: String?) {
        guard id != openChatID else { return }
        openChatID = id
        unread.markRead(chatID: id)
        conv.open(chatID: id, chatName: chatName)
    }

    /// Routed event for THIS account (the registry routes by account;
    /// the App already ran the rules decision): list bump + unread +
    /// open-conv bubble, same shape as the main path.
    public func ingest(
        _ message: RealtimeMessage, decision: ChatFilter.Decision
    ) {
        chats.ingest(realtime: message)
        unread.ingest(
            decision: decision, chatID: message.chatID,
            openChatID: openChatID, messageAt: ChatListFormat.parse(message.time))
        if message.isFor(chatID: openChatID) {
            conv.ingest(realtime: message)
        }
    }

    private func openSelected(_ id: String?) {
        guard let id, !id.isEmpty else { return }
        guard id != openChatID else { return }
        open(chatID: id, chatName: chats.chat(id: id)?.name)
    }
}

/// Open account windows + cached graphs. One window per account (re-open
/// refocuses — the caller skips `openWindow` when `open` returns false).
@MainActor
public final class AccountWindowRegistry: ObservableObject {
    /// Accounts with a visible window.
    @Published public private(set) var openIDs: Set<String> = []
    /// Session graph cache (accountID → graph). Plain (never
    /// @Published): resolved during window-body eval, must not
    /// republish mid-render.
    public private(set) var graphs: [String: AccountWindowGraph] = [:]

    public init() {}

    /// Open a window for an account: true when newly opened, false
    /// when already open (caller focuses) or the id is blank. The
    /// graph is created on first open and cached for the session.
    @discardableResult
    public func open(
        accountID: String, make: () -> AccountWindowGraph
    ) -> Bool {
        let id = accountID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        if graphs[id] == nil { graphs[id] = make() }
        guard !openIDs.contains(id) else { return false }
        openIDs.insert(id)
        return true
    }

    /// True while the account has a visible window.
    public func isOpen(accountID: String) -> Bool {
        openIDs.contains(accountID)
    }

    /// Cached graph for an account (nil until first opened).
    public func graph(for accountID: String) -> AccountWindowGraph? {
        graphs[accountID]
    }

    /// Window closed: the account leaves the visible set while its
    /// graph stays cached — re-open restores selection, bubbles,
    /// unread, and pins with no reload. (The App drains the graph's
    /// unread into the background roll-up first — see
    /// AppState.closeAccountWindow.)
    public func close(accountID: String) {
        openIDs.remove(accountID)
    }

    /// Remove-account: evict the cached graph (visible + cached gone;
    /// a live window renders the removed placeholder).
    public func drop(accountID: String) {
        openIDs.remove(accountID)
        graphs.removeValue(forKey: accountID)
    }

    /// Feed fan-out: route to the owning account's window graph.
    /// `activeID` resolves nil-stamped (live) events. True when a
    /// visible window consumed the event.
    @discardableResult
    public func ingest(
        _ message: RealtimeMessage, decision: ChatFilter.Decision,
        activeID: String?
    ) -> Bool {
        let target = (message.accountID ?? activeID ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, openIDs.contains(target),
              let g = graphs[target]
        else { return false }
        g.ingest(message, decision: decision)
        return true
    }
}
