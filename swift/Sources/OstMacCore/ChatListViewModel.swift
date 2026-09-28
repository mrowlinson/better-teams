// ChatListViewModel.swift — loads chats via ostmac-core, owns sidebar state.
import Combine
import Foundation

/// Sidebar content state.
public enum ChatListState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty list in `chats`.
    case loaded
    /// Fetch succeeded with zero chats.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads the chat list off the main thread and publishes rows + selection.
///
/// Default fetcher calls `RustCore.chats` (blocking network) on a
/// detached task. Tests inject a mock fetcher. Conforms to ``ChatSelection``
/// so the conversation lane can share this instance as its selection source.
/// Also owns the leave/block flows (om-leave-block): leaving calls core
/// and drops the row locally on success; blocking records the user and
/// drops the row immediately. Neither path ever refetches the list.
@MainActor
public final class ChatListViewModel: ObservableObject, ChatSelection {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Fetcher = @Sendable (Int32) throws -> ChatsResponse
    /// Sync leave call (runs off-main). Throws `CoreCallError` on failure.
    public typealias Leaver = @Sendable (String) throws -> LeaveResponse

    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    /// Every write rebuilds `chatByID` (first id wins, `.first` parity).
    @Published public private(set) var chats: [ChatItem] = [] {
        didSet { rebuildChatIndex() }
    }

    /// O(1) row lookup by chat id (om-s6-renderparse). Rebuilt on every
    /// `chats` write; reads (realtime path, selection) never scan.
    private var chatByID: [String: ChatItem] = [:]

    private func rebuildChatIndex() {
        var next: [String: ChatItem] = [:]
        next.reserveCapacity(chats.count)
        for c in chats where next[c.id] == nil {
            next[c.id] = c
        }
        chatByID = next
    }

    /// Row for one chat id (nil when unknown). Same answer as a linear
    /// `.first` scan, O(1).
    public func chat(id: String) -> ChatItem? {
        chatByID[id]
    }
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: ChatListState = .loading
    /// Sidebar selection (see ``ChatSelection``).
    @Published public var selectedChatID: String?
    /// Leave calls in flight (sidebar disables + spins these rows).
    @Published public private(set) var leavingIDs: Set<String> = []
    /// Last leave failure (sidebar error alert; nil when clear).
    @Published public private(set) var leaveError: String?
    /// Successful leaves this session (Diagnostics only).
    @Published public private(set) var leavesCompleted = 0
    /// Failed leave calls this session (Diagnostics only).
    @Published public private(set) var leaveFailures = 0

    public var selectedChat: ChatItem? {
        selectedChatID.flatMap { chatByID[$0] }
    }

    /// Sidebar order: user pins (pin-time order), then recency. Pure
    /// projection over `chats` (which stays recency-ordered) plus the
    /// persisted pin list; every ingest/filter/restart path re-derives
    /// it, so the pin invariant holds without a stored copy that
    /// could drift. Nothing is injected — `displayChats` ids are
    /// always a subset of `chats` ids.
    public var displayChats: [ChatItem] {
        PinnedChats.sorted(chats, pins: pins.orderedIDs)
    }

    /// User-pinned chats (persisted; the sidebar's Pin/Unpin context
    /// menu acts through `pin(_:)`/`unpin(_:)` below).
    public let pins: UserPinStore

    /// User chat folders + auto-rules (persisted; the sidebar's folder
    /// picker and Move-to-folder menu read this same instance).
    /// Membership is a pure render-time projection (`displayChats`
    /// order is untouched; the sidebar applies the folder filter
    /// stage), so ingest/load never migrate anything.
    public let folders: FolderStore

    /// Shared blocked-user list (Settings + Diagnostics read this same
    /// instance; the app passes its persistent one). Default is
    /// memory-only so tests and previews never touch real defaults.
    public let blocked: BlockedStore

    /// Fired with the chat id after a row leaves locally (leave success
    /// or block). The app clears per-chat satellite state here (unread,
    /// mention flags) — never a list refresh.
    public var onLocalRemove: ((String) -> Void)?

    private let fetcher: Fetcher
    private let leaver: Leaver
    private var cancellables = Set<AnyCancellable>()

    public init(
        fetcher: @escaping Fetcher = { try RustCore.chats(limit: $0) },
        pins: UserPinStore? = nil,
        leaver: @escaping Leaver = { try RustCore.leaveChat(chatID: $0) },
        blocked: BlockedStore? = nil,
        folders: FolderStore? = nil
    ) {
        // Store defaults built here: default arguments are nonisolated
        // and cannot call the stores' main-actor inits.
        self.fetcher = fetcher
        self.leaver = leaver
        self.blocked = blocked ?? BlockedStore(defaults: nil)
        self.pins = pins ?? UserPinStore()
        self.folders = folders ?? FolderStore()
        self.pins.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.folders.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// True when the chat is user-pinned (context-menu state).
    public func isPinned(_ id: String) -> Bool {
        pins.isPinned(id)
    }

    /// Pin a chat (no-op for blank/duplicate ids — the store
    /// refuses them; the list is never refetched here).
    public func pin(_ id: String) {
        pins.pin(id)
    }

    /// Unpin a chat (unknown ids are a no-op; the row returns to
    /// recency order on the next `displayChats` read).
    public func unpin(_ id: String) {
        pins.unpin(id)
    }

    /// BUILDFIX: last-good chat list snapshot (nil = memory only / demo).
    /// Rows only (ids, titles, last-message preview/time/sender) — no
    /// message bodies; timelines live in MessageHistoryCache.
    public var snapshots: SectionCache?
    static let snapshotKey = "chats"

    /// Paint the last good list (launch / account switch) before any
    /// fetch; the next load revalidates behind the rows. Blocks made
    /// since the snapshot still apply. No-op when rows are already up.
    @discardableResult
    public func restoreSnapshot() -> Bool {
        guard chats.isEmpty,
              let cached = snapshots?.load([ChatItem].self, key: Self.snapshotKey)
        else { return false }
        let visible = blocked.filtered(cached)
        guard !visible.isEmpty else { return false }
        chats = visible
        state = .loaded
        return true
    }

    /// Publish a fetched list: rows only when they changed (a cached
    /// paint that matches the server republishes nothing), then save
    /// the snapshot. Drops the selection when its chat is gone.
    private func apply(_ response: ChatsResponse) {
        let visible = Self.recencyOrdered(blocked.filtered(response.chats))
        if visible != chats { chats = visible }
        state = visible.isEmpty ? .empty : .loaded
        if let sel = selectedChatID, chatByID[sel] == nil {
            selectedChatID = nil
        }
        snapshots?.save(visible, key: Self.snapshotKey)
    }

    /// Fetch the list. Drops the selection when its chat is gone.
    /// Blocked threads are filtered before publish (they never render).
    public func load(limit: Int32 = 50) async {
        state = .loading
        let fetcher = fetcher
        do {
            let response = try await Task.detached {
                try fetcher(limit)
            }.value
            apply(response)
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Leave one group chat: call core, then drop the row locally and
    /// migrate the selection (see ``LeaveSelection``). No refetch —
    /// the server row simply stops arriving. Unknown, blank, or
    /// already-leaving ids are a no-op. Failure keeps the row and
    /// publishes `leaveError` (sidebar alert offers Retry).
    public func leave(chatID: String) async {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard chatByID[id] != nil else { return }
        guard !leavingIDs.contains(id) else { return }
        leavingIDs.insert(id)
        leaveError = nil
        let leaver = leaver
        do {
            _ = try await Task.detached { try leaver(id) }.value
            leavingIDs.remove(id)
            leavesCompleted += 1
            removeLocally(chatID: id)
        } catch {
            leavingIDs.remove(id)
            leaveFailures += 1
            leaveError = Self.message(for: error)
        }
    }

    /// Block one 1:1 thread's user: record the block, then drop the row
    /// locally and migrate the selection. Synchronous and local-only
    /// (Teams exposes no block endpoint — enforcement is the hidden row
    /// plus the app's notify/unread/mention gates). Unknown or blank
    /// ids are a no-op.
    public func block(chatID: String) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard let row = chatByID[id] else { return }
        blocked.block(chatID: id, name: row.name)
        removeLocally(chatID: id)
    }

    /// Dismiss the leave error (sidebar alert Cancel).
    public func clearLeaveError() {
        leaveError = nil
    }

    /// Drop one row without refetching; migrate a stranded selection to
    /// its neighbor (never the dead thread, never a blind first-row
    /// jump for untouched selections). Unknown ids are a no-op.
    public func removeLocally(chatID: String) {
        guard chatByID[chatID] != nil else { return }
        let next = LeaveSelection.fallback(
            removedID: chatID, chats: chats, selectedID: selectedChatID)
        chats.removeAll { $0.id == chatID }
        selectedChatID = next
        snapshots?.save(chats, key: Self.snapshotKey) // left row never repaints
        onLocalRemove?(chatID)
    }

    /// Demo/evidence: add one row locally (no core call); a row already
    /// present is left alone. A dated row takes its recency place; an
    /// undated one is a chat created just now (no messages yet), so its
    /// creation is the newest activity and it leads Recent (§6.2).
    public func insertLocally(_ chat: ChatItem) {
        guard chatByID[chat.id] == nil else { return }
        if chat.last_message_time.flatMap(ChatListFormat.parse) == nil {
            chats = [chat] + chats
        } else {
            chats = Self.recencyOrdered(chats + [chat])
        }
    }

    /// Fire-and-forget reload (error-state Retry, resync, sign-in).
    public func refresh(limit: Int32 = 50) {
        Task { await load(limit: limit) }
    }

    /// Account switch (d1-accounts): drop every row (zero old-account
    /// rows visible) + selection + transient state. Lands on `.empty`
    /// (static, no spinner); the caller follows with `loadQuietly`.
    public func resetForAccount() {
        chats = []
        selectedChatID = nil
        leavingIDs = []
        leaveError = nil
        state = .empty
    }

    /// Fetch without the `.loading` spinner (account-switch follow-up
    /// to `resetForAccount`): state only moves when results land.
    public func loadQuietly(limit: Int32 = 50) async {
        let fetcher = fetcher
        do {
            let response = try await Task.detached {
                try fetcher(limit)
            }.value
            apply(response)
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Realtime feed: only user text bubbles a row to the top. Beacons,
    /// blobs, cards, and reaction-only patches are a no-op (no reorder,
    /// no publish); bots, system notices, edits, and meeting cards update
    /// the preview in place. Unknown chat ids are a no-op (a resync
    /// refetch picks up new chats).
    public func ingest(realtime message: RealtimeMessage) {
        let next = Self.ingested(message, into: chats)
        guard next != chats else { return }
        chats = next
    }

    /// Burst ingest: fold a poll burst with ONE publish. Chats touched
    /// only by skips keep their exact rows (stable identity, no List diff).
    public func ingest(batch: [RealtimeMessage]) {
        let next = Self.ingested(batch, into: chats)
        guard next != chats else { return }
        chats = next
    }

    /// Load-time "Recent" order (UI-SPEC §6.2): last activity newest
    /// first; rows without a parseable time sink to the end; ties break
    /// by id so the order is stable across loads. Ingest keeps its own
    /// bubble/in-place policy on top of this.
    public nonisolated static func recencyOrdered(_ list: [ChatItem]) -> [ChatItem] {
        let keyed = list.map { ($0, $0.last_message_time.flatMap(ChatListFormat.parse)) }
        return keyed.sorted { a, b in
            switch (a.1, b.1) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0.id < b.0.id
            }
        }.map(\.0)
    }

    /// Pure ingest: user text bubbles to top; bots/system/edits/cards stay
    /// in place; beacons/blobs/unknown ids leave the list unchanged.
    public nonisolated static func ingested(_ message: RealtimeMessage, into list: [ChatItem]) -> [ChatItem] {
        guard let i = list.firstIndex(where: { $0.id == message.chatID }) else { return list }
        guard let (updated, outcome) = updatedRow(old: list[i], message: message) else { return list }
        if outcome == .refresh {
            var out = list
            out[i] = updated
            return out
        }
        var out = list
        out.remove(at: i)
        out.insert(updated, at: 0)
        return out
    }

    /// Pure batch fold: sequential ingest, order resolved once by the final
    /// fold (the last user-active chat ends on top). One O(n) index for
    /// the burst instead of a scan per event (same fold, same result).
    public nonisolated static func ingested(_ messages: [RealtimeMessage], into list: [ChatItem]) -> [ChatItem] {
        guard !messages.isEmpty else { return list }
        // Duplicate ids take the legacy fold (dict order can't model two
        // rows sharing one id — same result, no new semantics).
        var seen = Set<String>()
        for c in list {
            if !seen.insert(c.id).inserted {
                return messages.reduce(list) { Self.ingested($1, into: $0) }
            }
        }
        var order = list.map(\.id)
        var rows: [String: ChatItem] = [:]
        rows.reserveCapacity(list.count)
        for c in list { rows[c.id] = c }
        for m in messages {
            guard let old = rows[m.chatID] else { continue }
            guard let (updated, outcome) = updatedRow(old: old, message: m) else { continue }
            rows[m.chatID] = updated
            if outcome == .bubble {
                order.removeAll { $0 == m.chatID }
                order.insert(m.chatID, at: 0)
            }
        }
        return order.compactMap { rows[$0] }
    }

    /// One event's row update: nil for skips and unchanged rows (beacons,
    /// blobs, meeting cards with nothing human), else the new row plus
    /// its placement (refresh in place, bubble to top).
    nonisolated static func updatedRow(
        old: ChatItem, message: RealtimeMessage
    ) -> (ChatItem, SidebarIngest.Outcome)? {
        let outcome = SidebarIngest.decide(message: message, chatName: old.name)
        guard outcome != .skip else { return nil }
        let isMeeting = MeetingSignal.isMeetingThread(old.chatId)
        // Meeting previews are last user text: mine the human card lines;
        // nothing human → keep the row. Image-only keeps its sender line.
        let preview: String
        if isMeeting, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let human = SidebarIngest.humanLines(message.text) else { return nil }
            preview = human
        } else {
            preview = message.text
        }
        // In-place rows with no attributable author (system notices,
        // mined meeting cards) show the bare text, never a "?:" prefix.
        let sender: String?
        if outcome == .refresh,
           (SidebarIngest.isSystem(message)
               || (isMeeting && SidebarIngest.isMixedCard(message.text))),
           MeetingSignal.isUnknownSender(message.sender)
        {
            sender = nil
        } else {
            sender = message.sender
        }
        let updated = ChatItem(
            chatId: old.chatId, name: old.name, is_group: old.is_group,
            last_message_time: message.time,
            last_message_sender: sender,
            last_message_preview: preview)
        return (updated, outcome)
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
