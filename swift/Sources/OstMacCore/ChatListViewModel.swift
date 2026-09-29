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
    /// Sync next-page fetch by the previous page's `next_link` (off-main).
    public typealias PageFetcher = @Sendable (String) throws -> ChatsResponse

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
    /// CHATSYNC S1: chats being deleted (menu disables Delete) and the
    /// last delete failure (quiet note under the list; row kept).
    @Published public private(set) var deletingIDs: Set<String> = []
    @Published public private(set) var deleteError: String?
    /// Last refused Mark as read/unread (AppState sets it).
    @Published public var readStateError: String?
    /// Delete chat for the owner (chat id, newest message ms); nil = no
    /// server delete (demo removes locally).
    public var deleter: (@MainActor (String, Int64?) async throws -> Void)?
    /// When the newest list fetch started (read-state seeds use it to
    /// ignore answers older than a local change).
    public private(set) var lastFetchStartedAt: Date = .distantPast
    /// Successful leaves this session (Diagnostics only).
    @Published public private(set) var leavesCompleted = 0
    /// Failed leave calls this session (Diagnostics only).
    @Published public private(set) var leaveFailures = 0
    /// An older page is being fetched (the sidebar's bottom spinner).
    @Published public private(set) var isLoadingMore = false
    /// FIXPACK F9: the last older-page read timed out or failed. The footer
    /// shows a Try Again button instead of a spinner; nothing pages again
    /// until the user retries (or a reload resets it).
    @Published public private(set) var loadMoreFailed = false
    /// Deadline for one older-page read (seconds). Tests shorten it.
    public var pageTimeout: TimeInterval = 10
    /// Link to the next older page; nil = the whole list is loaded.
    @Published public private(set) var nextPageLink: String?
    /// Pages fetched so far; a refresh re-reads this many (min 1).
    public private(set) var loadedPages = 0
    /// More (older) chats exist on the server.
    public var hasMore: Bool { nextPageLink != nil }

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
    private let pageFetcher: PageFetcher
    private let leaver: Leaver
    /// Bumped by each full load, so a page landing after a reload or an
    /// account switch is dropped instead of mixing into the new list.
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    public init(
        fetcher: @escaping Fetcher = { try RustCore.chats(limit: $0) },
        pageFetcher: @escaping PageFetcher = { try RustCore.chats(limit: 50, pageLink: $0) },
        pins: UserPinStore? = nil,
        leaver: @escaping Leaver = { try RustCore.leaveChat(chatID: $0) },
        blocked: BlockedStore? = nil,
        folders: FolderStore? = nil
    ) {
        // Store defaults built here: default arguments are nonisolated
        // and cannot call the stores' main-actor inits.
        self.fetcher = fetcher
        self.pageFetcher = pageFetcher
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
    private func apply(_ response: ChatsResponse, complete: Bool = true) {
        let visible = Self.merged(
            existing: chats, fetched: blocked.filtered(response.chats), complete: complete)
        if visible != chats { chats = visible }
        state = visible.isEmpty ? .empty : .loaded
        if let sel = selectedChatID, chatByID[sel] == nil {
            selectedChatID = nil
        }
        snapshots?.save(visible, key: Self.snapshotKey)
        onFetched?(response.chats)
    }

    /// Every fetched list (the app adopts the Teams mute state).
    public var onFetched: (([ChatItem]) -> Void)?
    /// Teams folders read, run after each fetch; nil = none (demo seeds
    /// FolderStore directly). A failed read keeps the last folders.
    public var folderReader: (@Sendable () throws -> ChatFoldersResponse)?

    /// Activity-feed chat mentions, read after each fetch (Mentions
    /// filter seed); nil = none (demo). A failed read changes nothing.
    public var mentionReader: (@Sendable () throws -> [MentionActivity])?
    /// Every successful mention read (the app seeds MentionStore).
    public var onMentionActivity: (([MentionActivity]) -> Void)?

    private func readMentions(generation gen: Int) async {
        guard let reader = mentionReader,
              let list = try? await Self.offPool({ try reader() }),
              gen == generation
        else { return }
        onMentionActivity?(list)
    }

    private func readFolders() async {
        guard let reader = folderReader else { return }
        if let resp = try? await Task.blocking(operation: { try reader() }).value, resp.ok {
            folders.applyServer(resp.folders)
        }
    }

    /// Fetch the list. Drops the selection when its chat is gone.
    /// Blocked threads are filtered before publish (they never render).
    public func load(limit: Int32 = 50) async {
        state = .loading
        await fetchWindow(limit: limit)
    }

    /// Once-only gate: the first of the read and the timer resumes.
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Thrown when an older-page read outlives its deadline.
    struct PageTimeout: Error {}

    /// [`offPool`] with a deadline: the read keeps running on the blocking
    /// executor (a blocking core call cannot be cancelled) but its late
    /// answer is dropped. The timer only sleeps, so it holds no thread.
    nonisolated static func offPool<T: Sendable>(
        timeout: TimeInterval, _ op: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let gate = OnceGate()
            Task.blocking(priority: .userInitiated) {
                let r = Result { try op() }
                if gate.claim() { cont.resume(with: r) }
            }
            Task(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if gate.claim() { cont.resume(throwing: PageTimeout()) }
            }
        }
    }

    /// Run a blocking core call on the shared blocking executor, not the
    /// cooperative pool: at launch many stores park threads in blocking
    /// calls, and a list fetch queued behind them could not even start.
    nonisolated static func offPool<T: Sendable>(
        _ op: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await BlockingExecutor.run(priority: .userInitiated, op)
    }

    /// Re-read every page loaded so far (first page alone on the first
    /// load) and publish once, merged into the rows on screen: a reload
    /// never shrinks a scrolled-out list back to one page.
    private func fetchWindow(limit: Int32) async {
        lastFetchStartedAt = Date()
        generation += 1
        loadMoreFailed = false
        let gen = generation
        let fetcher = fetcher
        let pageFetcher = pageFetcher
        let pages = max(1, loadedPages)
        do {
            let result = try await Self.offPool { () -> (ChatsResponse, Int) in
                var page = try fetcher(limit)
                var rows = page.chats
                var read = 1
                while read < pages, let link = page.next_link {
                    page = try pageFetcher(link)
                    rows += page.chats
                    read += 1
                }
                return (ChatsResponse(ok: true, chats: rows, next_link: page.next_link), read)
            }
            guard gen == generation else { return }
            let (response, read) = result
            loadedPages = read
            nextPageLink = response.next_link
            apply(response, complete: response.next_link == nil)
            await readFolders()
            await readMentions(generation: gen)
        } catch {
            guard gen == generation else { return }
            state = .error(Self.message(for: error))
        }
    }

    /// Fetch the next older page and merge it in (sidebar scroll or the
    /// viewport not yet full). No-op while one is in flight or when the
    /// list is complete. A failure keeps the link for the next try.
    public func loadMore() async {
        guard let link = nextPageLink, !isLoadingMore, !loadMoreFailed else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let gen = generation
        let pageFetcher = pageFetcher
        let start = DispatchTime.now().uptimeNanoseconds
        let page: ChatsResponse
        do {
            page = try await Self.offPool(timeout: pageTimeout) { try pageFetcher(link) }
        } catch {
            guard gen == generation else { return }
            // FIXPACK F9: a timeout/failure is shown (Try Again), never an
            // endless spinner, and does not auto-retry in a loop.
            let why = error is PageTimeout ? "timed out" : "failed"
            Log.store.error("chat list page \(self.loadedPages + 1, privacy: .public) \(why, privacy: .public) after \(Log.ms(since: start), privacy: .public)ms")
            loadMoreFailed = true
            return
        }
        guard gen == generation else {
            Log.store.info("chat list page \(self.loadedPages + 1, privacy: .public) dropped \(Log.ms(since: start), privacy: .public)ms")
            return
        }
        loadMoreFailed = false
        loadedPages += 1
        Log.store.info("chat list page \(self.loadedPages, privacy: .public) rows=\(page.chats.count, privacy: .public) more=\(page.next_link != nil, privacy: .public) \(Log.ms(since: start), privacy: .public)ms")
        nextPageLink = page.next_link
        let visible = Self.merged(
            existing: chats, fetched: blocked.filtered(page.chats), complete: false,
            dropNewerAbsent: false)
        if visible != chats { chats = visible }
        state = visible.isEmpty ? .empty : .loaded
        snapshots?.save(visible, key: Self.snapshotKey)
        onFetched?(page.chats)
    }

    /// The footer's Try Again: clear the failed state and page again.
    public func retryLoadMore() async {
        guard loadMoreFailed else { return }
        loadMoreFailed = false
        await loadMore()
    }

    /// Row-appear hook: prefetch the next page once the row is within
    /// `buffer` rows of the end of `rows` (the order the sidebar shows).
    public func loadMoreIfNeeded(currentID: String, in rows: [ChatItem], buffer: Int = 12) {
        guard hasMore, !isLoadingMore, !loadMoreFailed else { return }
        guard let i = rows.lastIndex(where: { $0.id == currentID }),
              i >= rows.count - buffer
        else { return }
        Task { await loadMore() }
    }

    /// Pure list merge, recency-ordered. `complete` (the fetch reached the
    /// last page) replaces the rows outright. Otherwise fetched rows are
    /// upserted; an absent row is kept when it is older than the oldest
    /// fetched row (it lives on a page not re-read), and dropped when
    /// newer (it would have been in the window: left, hidden, or now
    /// filtered) unless `dropNewerAbsent` is false (a single older page).
    public nonisolated static func merged(
        existing: [ChatItem], fetched: [ChatItem], complete: Bool,
        dropNewerAbsent: Bool = true
    ) -> [ChatItem] {
        if complete { return recencyOrdered(fetched) }
        var seen = Set<String>()
        var out: [ChatItem] = []
        out.reserveCapacity(existing.count + fetched.count)
        for c in fetched where seen.insert(c.id).inserted { out.append(c) }
        let oldest = fetched.compactMap { $0.last_message_time.flatMap(ChatListFormat.parse) }.min()
        for c in existing where !seen.contains(c.id) {
            if dropNewerAbsent {
                guard let oldest,
                      let t = c.last_message_time.flatMap(ChatListFormat.parse),
                      t < oldest
                else { continue }
            }
            seen.insert(c.id)
            out.append(c)
        }
        return recencyOrdered(out)
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
            _ = try await Task.blocking { try leaver(id) }.value
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
        deleteError = nil
        readStateError = nil
    }

    /// Delete a chat for the owner (Teams "Delete chat"): the row leaves
    /// the list (a diff) only once Teams accepted it; a failure keeps
    /// the row and says so.
    public func delete(chatID: String) async {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let row = chatByID[id], !deletingIDs.contains(id) else { return }
        deletingIDs.insert(id)
        deleteError = nil
        defer { deletingIDs.remove(id) }
        do {
            if let deleter {
                try await deleter(id, CoreReads.arrivalMs(id: nil, time: row.last_message_time))
            }
            removeLocally(chatID: id)
        } catch {
            deleteError = Self.message(for: error)
        }
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
        generation += 1
        nextPageLink = nil
        loadedPages = 0
        isLoadingMore = false
        loadMoreFailed = false
        chats = []
        selectedChatID = nil
        leavingIDs = []
        leaveError = nil
        state = .empty
    }

    /// Fetch without the `.loading` spinner (account-switch follow-up
    /// to `resetForAccount`): state only moves when results land.
    public func loadQuietly(limit: Int32 = 50) async {
        await fetchWindow(limit: limit)
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
