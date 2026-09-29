// ConversationStore.swift — om-conv lane: state for one open chat.
//
// INPUT API (what the chat-list and realtime lanes drive):
//   store.open(chatID:chatName:) — load last-few-days window via core (replaces messages)
//   store.ingest(_ message:)      — upsert one realtime ChatMessage by id:
//                                  new id appends, known id updates content
//                                  in place (edit). THE realtime feed point.
//   store.ingestEdited(id:content:) — edit event carrying only new text
//   store.send(text:)             — post via core, optimistic own-bubble
//   store.toggleReaction(messageID:emoji:) — picker tap: add/remove one
//                                  emoji, optimistic, reverts on failure
//   store.applyReactions(id:reactions:) — realtime counts patch (no-op
//                                  on unknown ids, never appends)
//   store.edit(messageID:text:)   — edit own bubble via core (optimistic)
//   store.deleteMessage(id:)      — delete own bubble via core (optimistic tombstone)
//   store.ingestDeleted(id:)       — peer delete: tombstone (group) / drop (1:1)
// Shared model: ChatMessage (Models.swift) — history, send-echo, and
// realtime all use it; `id` is the match key for edits.
import Foundation

@MainActor
public final class ConversationStore: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var loading = false
    @Published public private(set) var loadingMore = false
    @Published public private(set) var error: String?
    @Published public private(set) var didLoad = false
    @Published public private(set) var failedIDs: Set<String> = []
    /// A background `refresh()` is running behind the bubbles on screen.
    @Published public private(set) var refreshing = false
    /// The last background refresh failed (bubbles stay; quiet notice).
    @Published public private(set) var refreshError: String?
    /// Armed quote-reply target (om-replies): set by the bubble Reply
    /// action, cleared by send/cancel/chat-switch. `send(text:)` posts
    /// through the reply path while set.
    @Published public private(set) var replyTarget: ChatMessage?
    /// Armed jump target (om-ja-search): the timeline scrolls to this
    /// bubble id, then consumes it via `clearJumpTarget`. Set by
    /// `open(seekMessageID:)` / `seek(messageID:)` once the id is
    /// loaded; cleared by open/close/chat-switch.
    @Published public private(set) var jumpTargetID: String?
    /// Armed jump miss (gap-g9): the id a seek could not find after
    /// exhausting its page budget (or with no cursor left). The
    /// timeline banners "message no longer available" until dismissed
    /// via `clearJumpMissed`; cleared by open/close/seek/chat-switch.
    @Published public private(set) var jumpMissedID: String?
    /// Last missed seek id this session (Diagnostics; survives the
    /// banner dismiss, cleared on account switch only).
    @Published public private(set) var lastMissedID: String?
    /// Session seek counters (Diagnostics jump-rate source). Every
    /// valid-id seek that runs to a verdict counts one attempt; page
    /// errors count as attempts with neither landed nor missed (a
    /// network failure is not an id mismatch).
    @Published public private(set) var seekAttempts = 0
    @Published public private(set) var seekLanded = 0
    @Published public private(set) var seekMissed = 0
    public private(set) var chatID: String?
    public private(set) var chatName: String?
    /// Header title: the resolved chat name, else the generic label —
    /// never the raw chat id (om-chatnames).
    public var headerTitle: String {
        if let n = chatName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return "Conversation"
    }
    public private(set) var isDemo = false
    /// Own sender name (whoami display_name); nil until resolved or in demo.
    /// Stamps `isOwn` on history, pages, and realtime ingests.
    public private(set) var ownDisplayName: String?
    /// Local-send tap (e1-popout): fired with the appended bubble on
    /// every `send` (demo + live optimistic paths). The pop-out registry
    /// mirrors through it so an own-bubble appears in both windows.
    public var onLocalSend: ((ChatMessage) -> Void)?
    /// History tap (gap-g6g7): fired with each stamped batch that lands
    /// from a fetch (`open` pages, `seek` pages, `loadMore` pages,
    /// `showDemo`). AppState indexes batches into the offline search
    /// store. Fires on the caller's context; hop actors as needed.
    public var onHistory: ((String, [ChatMessage]) -> Void)?
    /// Delete tap (gap-g6g7): fired with (chatID, messageID) once a
    /// delete lands (demo path + confirmed core deletes; optimistic
    /// removals that restore never fire). AppState drops the offline
    /// index doc.
    public var onDelete: ((String, String) -> Void)?
    /// Owning account profile (gap-g2): nil = the active profile
    /// (every core call runs direct, unchanged). Account-window graphs
    /// stamp their account + inject the App's flip-flop runner, so
    /// history/sends/reacts land on the window's account.
    public var accountID: String?
    /// Profile-aware core-call wrapper (gap-g2). Default runs direct.
    public var coreRunner: any AccountCoreRunner = DirectAccountCoreRunner()
    private var openGeneration = 0
    /// Bumped when an open's fresh page replaces a stale snapshot (and
    /// its cursor): an older page requested from the snapshot cursor
    /// before that would land in front of the fresh page with a gap, so
    /// `loadMore` drops it.
    private var historyEpoch = 0

    /// Sendable hop for detached core calls: the runner + account
    /// travel as values (self is MainActor-bound, the calls run
    /// off-main). Capture once per func, wrap every `RustCore.*` site.
    private struct CoreHop: Sendable {
        let runner: any AccountCoreRunner
        let accountID: String?
        func run<T>(_ op: () throws -> T) throws -> T {
            try runner.run(op, accountID: accountID)
        }
    }

    private var coreHop: CoreHop {
        CoreHop(runner: coreRunner, accountID: accountID)
    }

    /// Opaque cursor for the next older page; nil = end of history.
    public private(set) var pageToken: String?
    /// Fresh-page cursor kept behind a cached snapshot cursor: a stale
    /// snapshot cursor that fails once falls back to it (histload).
    private var fallbackToken: String?
    /// Per-chat snapshot store (histload): nil = no caching (tests,
    /// pop-outs); AppState / account windows inject the account's.
    public var historyCache: MessageHistoryCache?

    public init() {}

    // MARK: - History window (om-history)

    /// Initial load covers the last few days: `open` pages back until
    /// the oldest message is older than the window (or the page cap /
    /// end of history hits). The server ignores `startTime=`
    /// (OSTMAC-PATCHES #7), so the window is enforced client-side over
    /// the page_token chain — no core time params needed.
    public nonisolated static let historyWindowHours: Double = 72
    /// Fetch bounds: one open / day-load never fires more page fetches
    /// than this, so long threads can't churn the view unboundedly.
    /// Open stays small (newest slice, fast land); older history pages
    /// back on scroll.
    public nonisolated static let openMaxPages = 2
    public nonisolated static let dayLoadMaxPages = 4
    /// Seek bound (om-ja-search): a jump-to-message never pages back
    /// more than this looking for its bubble (open-chain extra +
    /// already-open `seek` share the cap).
    public nonisolated static let seekMaxPages = 8

    /// Shared stamp parsers (om-s6-renderparse): one static set replaces
    /// the per-call allocs (same options, same results).
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFallback: DateFormatter = {
        let g = DateFormatter()
        g.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        g.timeZone = TimeZone(secondsFromGMT: 0)
        g.locale = Locale(identifier: "en_US_POSIX")
        return g
    }()

    /// Tolerant ISO8601 parse for server stamps (fractional
    /// "…T12:53:06.9690000Z" and plain "…T12:53:06Z"). Nil for
    /// garbage/empty (callers stop paging — never spin on it).
    public static func messageDate(_ iso: String) -> Date? {
        let t = iso.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let d = isoFrac.date(from: t) { return d }
        if let d = isoPlain.date(from: t) { return d }
        // Last resort: "yyyy-MM-dd'T'HH:mm:ss" prefix in UTC.
        guard t.count >= 19 else { return nil }
        return isoFallback.date(from: String(t.prefix(19)))
    }

    /// True once the loaded slice reaches past the window: oldest
    /// message older than `hours`, or its stamp unparseable (can't
    /// window garbage — stop after the current page). Empty keeps
    /// paging (blank pages cover nothing).
    public static func windowCovered(
        _ messages: [ChatMessage], now: Date = Date(), hours: Double = historyWindowHours
    ) -> Bool {
        guard let oldest = messages.first else { return false }
        guard let d = messageDate(oldest.timestamp) else { return true }
        return d <= now.addingTimeInterval(-hours * 3600)
    }

    /// True once a day-load chunk crossed into an earlier calendar day
    /// than it started on (`startDayKey` = dayKey of the oldest message
    /// before the chunk). Empty never counts as crossed.
    public static func dayChunkDone(startDayKey: String, messages: [ChatMessage]) -> Bool {
        guard let oldest = messages.first else { return false }
        return MessageRender.dayKey(oldest.timestamp) != startDayKey
    }

    /// Open a chat (histload): a cached snapshot (`historyCache`) paints
    /// instantly with no loading pane, then only the newest page is
    /// fetched and merged in by id behind the bubbles (`refreshing`).
    /// Without a snapshot: newest page (published immediately), then
    /// older pages until the window is covered (bounded by
    /// `openMaxPages`), replacing messages. Stale completions are
    /// dropped, so fast chat-switching always lands on the newest
    /// selection. An uncached open clears the previous thread up front:
    /// a failed open shows the error with retry, never stale bubbles
    /// under a new name. `seekMessageID` (om-ja-search) pages back past
    /// the window until that bubble loads (bounded by `seekMaxPages`),
    /// then arms `jumpTargetID` so the timeline lands on it.
    public func open(chatID: String, chatName: String? = nil, limit: Int32 = 50, seekMessageID: String? = nil) {
        persistHistory() // the chat being left (keeps realtime rows)
        self.chatID = chatID
        if let n = chatName { self.chatName = n }
        pageToken = nil
        fallbackToken = nil
        loadingMore = false
        refreshError = nil
        error = nil
        replyTarget = nil
        jumpTargetID = nil
        jumpMissedID = nil
        openGeneration += 1
        let gen = openGeneration
        var seek: String? = {
            let t = (seekMessageID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }()
        let cached = isDemo ? nil : historyCache?.load(chatID: chatID)
        if let cached {
            // Stored rows carry their own isOwn; restamp only with a
            // known name (a nil name would flip every own bubble).
            messages = ownDisplayName.map { Self.stampOwnership(cached.messages, ownName: $0) } ?? cached.messages
            pageToken = cached.pageToken
            loading = false
            didLoad = true
            refreshing = true
            if let s = seek, messages.contains(where: { $0.id == s }) {
                seekAttempts += 1
                seekLanded += 1
                jumpTargetID = s
                seek = nil
            }
        } else {
            messages = []
            loading = true
            refreshing = false
        }
        let seekID = seek
        let hop = coreHop
        Task {
            // Best-effort identity (core-cached after first call); a stale
            // stored name still stamps when refresh fails.
            let own: String? = try? await Task.blocking(priority: .userInitiated) {
                try hop.run { try RustCore.whoami().display_name }
            }.value
            guard gen == self.openGeneration else { return } // superseded
            if let own { self.ownDisplayName = own }
            do {
                let resp = try await Task.blocking(priority: .userInitiated) {
                    try hop.run { try RustCore.messages(chatID: chatID, limit: limit) }
                }.value
                guard gen == self.openGeneration else { return }
                let stamped = Self.stampOwnership(resp.messages, ownName: self.ownDisplayName)
                var chainWindow = true
                if let cached {
                    let restamped = self.ownDisplayName == nil
                        ? self.messages : Self.stampOwnership(self.messages, ownName: self.ownDisplayName)
                    let fresh = Self.mergedFresh(stamped, into: restamped, keeping: self.unseenSentIDs)
                    self.noteSeen(stamped)
                    if fresh.messages != self.messages { self.messages = fresh.messages }
                    if fresh.contiguous {
                        // Snapshot cursor stays (it continues before the
                        // cached oldest); the fresh one is its fallback.
                        chainWindow = false
                        self.fallbackToken = resp.page_token
                        if self.pageToken == nil, !cached.endOfHistory { self.pageToken = resp.page_token }
                    } else {
                        // Gap wider than one page: the snapshot is stale.
                        self.pageToken = resp.page_token
                        self.historyEpoch += 1 // drop older pages from the snapshot cursor
                    }
                    self.refreshing = false
                    if chainWindow { self.loadingMore = true }
                } else {
                    self.messages = stamped
                    self.pageToken = resp.page_token
                }
                self.onHistory?(chatID, stamped)
                self.didLoad = true
                // Chain older pages until the window is covered.
                var pages = 1
                while chainWindow,
                      gen == self.openGeneration,
                      self.pageToken != nil,
                      !Self.windowCovered(self.messages),
                      pages < Self.openMaxPages
                {
                    guard let tok = self.pageToken else { break }
                    do {
                        let next = try await Task.blocking(priority: .userInitiated) {
                            try hop.run { try RustCore.messagesPage(chatID: chatID, pageToken: tok, limit: limit) }
                        }.value
                        guard gen == self.openGeneration else { return }
                        let stamped = Self.stampOwnership(next.messages, ownName: self.ownDisplayName)
                        self.messages = Self.prepend(stamped, to: self.messages)
                        self.onHistory?(chatID, stamped)
                        self.pageToken = next.page_token
                        pages += 1
                    } catch {
                        guard gen == self.openGeneration else { return }
                        self.error = String(describing: error)
                        break
                    }
                }
                // Seek-to-message (om-ja-search; gap-g9 verdict): page
                // back past the window until the target bubble loads
                // (bounded). Unfound targets arm the miss notice (never
                // a silent plain open); page errors surface `error`
                // with no miss (network failure ≠ id mismatch).
                var seekFound = false
                var seekPageError = false
                if let seek = seekID, gen == self.openGeneration {
                    var extra = 0
                    while gen == self.openGeneration,
                          !self.messages.contains(where: { $0.id == seek }),
                          self.pageToken != nil,
                          extra < Self.seekMaxPages
                    {
                        guard let tok = self.pageToken else { break }
                        do {
                            let next = try await Task.blocking(priority: .userInitiated) {
                                try hop.run { try RustCore.messagesPage(chatID: chatID, pageToken: tok, limit: limit) }
                            }.value
                            guard gen == self.openGeneration else { return }
                            let stamped = Self.stampOwnership(next.messages, ownName: self.ownDisplayName)
                            self.messages = Self.prepend(stamped, to: self.messages)
                            self.onHistory?(chatID, stamped)
                            self.pageToken = next.page_token
                            extra += 1
                        } catch {
                            guard gen == self.openGeneration else { return }
                            self.error = String(describing: error)
                            seekPageError = true
                            break
                        }
                    }
                    seekFound = gen == self.openGeneration
                        && self.messages.contains(where: { $0.id == seek })
                }
                guard gen == self.openGeneration else { return }
                self.loading = false
                self.loadingMore = false
                self.persistHistory()
                // Arm after the loading flip: the loading-change tail
                // land runs first, then the jump owns the viewport (its
                // onChange cancels the settle + scrolls to the bubble).
                if let seek = seekID {
                    self.seekAttempts += 1
                    if seekFound {
                        self.seekLanded += 1
                        self.jumpTargetID = seek
                    } else if !seekPageError {
                        self.seekMissed += 1
                        self.jumpMissedID = seek
                        self.lastMissedID = seek
                    }
                }
            } catch {
                guard gen == self.openGeneration else { return }
                if cached != nil {
                    // Snapshot stays on screen; quiet refresh notice.
                    self.refreshing = false
                    self.refreshError = String(describing: error)
                } else {
                    self.loading = false
                    self.didLoad = true
                    self.error = String(describing: error)
                }
            }
        }
    }

    /// Pure open merge (histload): the fresh newest page over a cached
    /// snapshot. Contiguous (the page's oldest id is cached, or the page
    /// is empty) = `mergedNewest` (edits/deletes inside the page land,
    /// older cached rows and the snapshot cursor stay). Otherwise the
    /// gap is wider than one page: the page replaces the snapshot (plus
    /// local pending rows) and paging restarts from the fresh cursor.
    public static func mergedFresh(
        _ page: [ChatMessage], into cached: [ChatMessage], keeping unseen: Set<String> = []
    ) -> (messages: [ChatMessage], contiguous: Bool) {
        guard let first = page.first else { return (cached, true) }
        if cached.contains(where: { $0.id == first.id }) {
            return (mergedNewest(page, into: cached, keeping: unseen), true)
        }
        return (page + localTail(cached[...], notIn: page, keeping: unseen), false)
    }

    /// §106: own-send rows the page can't replace yet — local rows
    /// (`pending-`/`sent-`) and confirmed sends not yet seen in a page
    /// (`unseen`: a GET that left before the POST landed must not drop
    /// the just-sent bubble). A row whose id OR client message id is in
    /// the page is the page's (settled): dropped here, the page row wins.
    static func localTail(
        _ rows: ArraySlice<ChatMessage>, notIn page: [ChatMessage], keeping unseen: Set<String>
    ) -> [ChatMessage] {
        let pageIDs = Set(page.map(\.id))
        let pageCmids = Set(page.compactMap(\.clientMessageID))
        // Server rows newer than the page's newest (chat-service ids are
        // arrival ms) arrived after the GET was served — a live push or an
        // echo racing a poll. They stay; the page can't have known them.
        let pageNewest = page.compactMap { Int64($0.id) }.max()
        return rows.filter { m in
            let newer = pageNewest.map { newest in Int64(m.id).map { $0 > newest } ?? false } ?? false
            guard SendReconcile.isLocalRow(m) || unseen.contains(m.id) || newer else { return false }
            if pageIDs.contains(m.id) { return false }
            if let c = m.clientMessageID, pageCmids.contains(c) { return false }
            return true
        }
    }

    /// Snapshot the open chat into `historyCache` (server rows only).
    private func persistHistory() {
        guard !isDemo, didLoad, let cache = historyCache, let id = chatID else { return }
        let rows = messages.filter { !SendReconcile.isLocalRow($0) }
        cache.store(chatID: id, messages: rows, pageToken: pageToken)
    }

    /// Re-fetch the open chat's newest page behind the bubbles on screen
    /// (push resync, reconnect): merged in place, nothing cleared, so
    /// the timeline keeps its rows, scroll and older pages. A failure
    /// keeps the bubbles (`refreshError`, quiet). Nothing on screen yet
    /// falls back to `open`; an open already running is left to land.
    public func refresh(limit: Int32 = 50, quiet: Bool = false) {
        guard !isDemo, let id = chatID else { return }
        guard !messages.isEmpty else {
            if !loading, !quiet { open(chatID: id, limit: limit) }
            return
        }
        let gen = openGeneration
        // §106: `quiet` = the open-chat fallback poll. It never publishes
        // `refreshing` (no spinner every few seconds), never shows a
        // failure, never supersedes a loud refresh, and runs one at a time.
        var rgen = 0
        if quiet {
            guard !pollInFlight else { return }
            pollInFlight = true
        } else {
            refreshGeneration += 1
            rgen = refreshGeneration
            refreshing = true
        }
        let hop = coreHop
        Task {
            defer { if quiet { self.pollInFlight = false } }
            do {
                let resp = try await Task.blocking(priority: .userInitiated) {
                    try hop.run { try RustCore.messages(chatID: id, limit: limit) }
                }.value
                guard gen == self.openGeneration, quiet || rgen == self.refreshGeneration else { return }
                let stamped = Self.stampOwnership(resp.messages, ownName: self.ownDisplayName)
                let before = Set(self.messages.map(\.id))
                let next = Self.mergedNewest(stamped, into: self.messages, keeping: self.unseenSentIDs)
                self.noteSeen(stamped)
                let changed = next != self.messages
                if changed { self.messages = next }
                let arrived = stamped.filter { !before.contains($0.id) }
                if !arrived.isEmpty {
                    Log.send.info("open chat rows arrived n=\(arrived.count, privacy: .public) via=\(quiet ? "poll" : "refresh", privacy: .public)")
                    self.onNewRows?(id, arrived)
                }
                if !quiet || changed { self.onHistory?(id, stamped) }
                if self.refreshError != nil { self.refreshError = nil }
                if !quiet || changed { self.persistHistory() }
            } catch {
                guard !quiet, gen == self.openGeneration, rgen == self.refreshGeneration else { return }
                self.refreshError = String(describing: error)
            }
            if !quiet { self.refreshing = false }
        }
    }

    /// §106: a quiet poll is in flight (one at a time).
    private var pollInFlight = false
    /// §106: rows a refresh/poll brought that weren't on screen (new
    /// arrivals, settled own sends). AppState updates the chat list row
    /// (preview/order) from them.
    public var onNewRows: ((String, [ChatMessage]) -> Void)?

    private var refreshGeneration = 0

    /// Pure refresh merge: the newest page replaces its own window of
    /// the list (edits and deletes inside it land), rows older than the
    /// page stay, and local rows the server can't know yet (pending
    /// sends) stay at the end. Without overlap (a gap wider than one
    /// page) the loaded rows stay ahead of the page. Empty page = no-op.
    public static func mergedNewest(
        _ page: [ChatMessage], into list: [ChatMessage], keeping unseen: Set<String> = []
    ) -> [ChatMessage] {
        guard let first = page.first else { return list }
        guard let i = list.firstIndex(where: { $0.id == first.id }) else {
            // §106: a local row the page already carries (by client id)
            // must not survive beside its server copy.
            let cmids = Set(page.compactMap(\.clientMessageID))
            let kept = list.filter { !(SendReconcile.isLocalRow($0) && $0.clientMessageID.map(cmids.contains) == true) }
            return prepend(kept, to: page)
        }
        return Array(list[..<i]) + page + localTail(list[i...], notIn: page, keeping: unseen)
    }

    /// Re-run `open` for the current chat (empty-state Try Again).
    /// No-op without a chat, or in demo mode (demo never hits core).
    public func retryOpen(limit: Int32 = 50) {
        guard !isDemo, let id = chatID else { return }
        open(chatID: id, limit: limit)
    }

    /// Close the thread (selection cleared, chat left): drop the id,
    /// bubbles, and pending state. The generation bump cancels in-flight
    /// opens, so stale completions can't repopulate a dead thread.
    public func close() {
        persistHistory()
        openGeneration += 1
        chatID = nil
        chatName = nil
        messages = []
        pageToken = nil
        loading = false
        loadingMore = false
        refreshing = false
        refreshError = nil
        error = nil
        didLoad = false
        failedIDs = []
        outgoing = [:]
        unseenSentIDs = []
        replyTarget = nil
        jumpTargetID = nil
        jumpMissedID = nil
    }

    /// Jump to one bubble in the OPEN chat (om-ja-search; gap-g9
    /// verdict): when the id is already loaded, arm the timeline jump
    /// immediately; otherwise page back (bounded by `seekMaxPages`)
    /// until it loads. Unfound ids arm the miss notice (never a silent
    /// no-op); blank ids and no open chat stay a no-op with no count.
    /// A mid-seek failure surfaces `error` like `loadMore`.
    public func seek(messageID: String, limit: Int32 = 50) {
        let id = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Every seek supersedes the armed miss (even a blank no-op).
        jumpMissedID = nil
        guard !id.isEmpty, chatID != nil else { return }
        if messages.contains(where: { $0.id == id }) {
            seekAttempts += 1
            seekLanded += 1
            jumpTargetID = id
            return
        }
        guard canLoadMore, let chat = chatID else {
            // Definitive miss: id absent with no older page left.
            seekAttempts += 1
            seekMissed += 1
            jumpMissedID = id
            lastMissedID = id
            return
        }
        loadingMore = true
        error = nil
        let gen = openGeneration
        let hop = coreHop
        Task {
            var pages = 0
            var lastError: Error?
            while pages < Self.seekMaxPages, self.pageToken != nil {
                guard let tok = self.pageToken else { break }
                do {
                    let resp = try await Task.blocking(priority: .userInitiated) {
                        try hop.run { try RustCore.messagesPage(chatID: chat, pageToken: tok, limit: limit) }
                    }.value
                    guard gen == self.openGeneration else { return } // superseded
                    let stamped = Self.stampOwnership(resp.messages, ownName: self.ownDisplayName)
                    self.messages = Self.prepend(stamped, to: self.messages)
                    if let chat = self.chatID { self.onHistory?(chat, stamped) }
                    self.pageToken = resp.page_token
                    pages += 1
                    if self.messages.contains(where: { $0.id == id }) { break }
                } catch {
                    guard gen == self.openGeneration else { return } // superseded
                    lastError = error
                    break
                }
            }
            guard gen == self.openGeneration else { return } // superseded
            self.loadingMore = false
            self.persistHistory()
            self.seekAttempts += 1
            if let e = lastError {
                self.error = String(describing: e)
            } else if self.messages.contains(where: { $0.id == id }) {
                self.seekLanded += 1
                self.jumpTargetID = id
            } else {
                self.seekMissed += 1
                self.jumpMissedID = id
                self.lastMissedID = id
            }
        }
    }

    /// Consume the armed jump (the timeline calls this after scrolling).
    public func clearJumpTarget() {
        jumpTargetID = nil
    }

    /// Dismiss the armed miss notice (the banner ✕ calls this).
    /// Counters and `lastMissedID` keep the session record.
    public func clearJumpMissed() {
        jumpMissedID = nil
    }

    /// Shot hook: surface a canned fetch error in demo mode only.
    /// Live stores ignore it (real errors come from core).
    public func seedDemoError(_ message: String) {
        guard isDemo else { return }
        error = message
    }

    /// Adopt an identity without core (tests, sign-in completion).
    public func adoptIdentity(displayName: String) {
        ownDisplayName = displayName
        messages = Self.stampOwnership(messages, ownName: ownDisplayName)
    }

    /// Drop identity after sign-out; existing bubbles keep their flags.
    public func clearIdentity() {
        ownDisplayName = nil
    }

    /// Account switch (d1-accounts): drop every row (zero old-account
    /// rows visible), clear paging + transient state, and re-stamp
    /// identity for the new account (empty list stays empty; the next
    /// open stamps with the new name). Cached-first: the caller
    /// re-opens the conversation, which renders the new account's
    /// snapshot without spinners.
    public func resetForAccount(displayName: String?) {
        persistHistory() // into the outgoing account's cache
        openGeneration += 1
        messages = []
        loading = false
        loadingMore = false
        refreshing = false
        refreshError = nil
        error = nil
        didLoad = false
        failedIDs = []
        outgoing = [:]
        unseenSentIDs = []
        replyTarget = nil
        jumpTargetID = nil
        jumpMissedID = nil
        lastMissedID = nil
        chatID = nil
        chatName = nil
        pageToken = nil
        ownDisplayName = displayName
    }

    /// Pure ownership stamp: `isOwn` iff `sender` equals the own name.
    /// Nil name leaves every flag false (matches core's unsigned state).
    public static func stampOwnership(_ list: [ChatMessage], ownName: String?) -> [ChatMessage] {
        guard let own = ownName else {
            return list.map { var m = $0; m.isOwn = false; return m }
        }
        return list.map { var m = $0; m.isOwn = (m.sender == own); return m }
    }

    /// True while an older page exists and no load is in flight.
    public var canLoadMore: Bool {
        !isDemo && !loading && !loadingMore && pageToken != nil
    }

    /// Prepend one lazy day-chunk of older history (scroll-top load).
    /// Pages until the oldest message crosses into an earlier calendar
    /// day than the chunk started on (or the cap / end hits); at least
    /// one page is always fetched. Each page applies as it arrives, so
    /// a mid-chunk failure keeps partial progress with the error
    /// surfaced and the token still on the next page — tapping again
    /// retries. No-op without a page token or while a load is in
    /// flight. Explicit taps only: the view no longer auto-fires (the
    /// old onAppear chained the whole thread, because the spinner /
    /// button swap re-triggers it after every page).
    public func loadMore(limit: Int32 = 50) {
        guard canLoadMore, let id = chatID else { return }
        loadingMore = true
        error = nil
        let gen = openGeneration
        let epoch = historyEpoch
        let hop = coreHop
        let startDay = MessageRender.dayKey(messages.first?.timestamp ?? "")
        Task {
            var pages = 0
            var lastError: Error?
            // Superseded: another chat opened, or the open's fresh page
            // replaced the snapshot this page continues (histload race).
            var current: Bool { gen == self.openGeneration && epoch == self.historyEpoch }
            while pages < Self.dayLoadMaxPages, let tok = self.pageToken {
                do {
                    let resp = try await Task.blocking(priority: .userInitiated) {
                        try hop.run { try RustCore.messagesPage(chatID: id, pageToken: tok, limit: limit) }
                    }.value
                    guard current else { return } // superseded
                    let stamped = Self.stampOwnership(resp.messages, ownName: self.ownDisplayName)
                    self.messages = Self.prepend(stamped, to: self.messages)
                    self.onHistory?(id, stamped)
                    self.pageToken = resp.page_token
                    self.fallbackToken = nil
                    pages += 1
                    if Self.dayChunkDone(startDayKey: startDay, messages: self.messages) { break }
                } catch {
                    guard current else { return } // superseded
                    // A stale snapshot cursor retries once from the
                    // fresh-page cursor (dedupe drops the overlap).
                    if let fb = self.fallbackToken, fb != tok {
                        self.fallbackToken = nil
                        self.pageToken = fb
                        continue
                    }
                    lastError = error
                    break
                }
            }
            guard current else { return } // superseded
            self.loadingMore = false
            if let e = lastError { self.error = String(describing: e) }
            self.persistHistory()
        }
    }

    /// Pure prepend: older page first, existing ids win on overlap.
    public static func prepend(_ older: [ChatMessage], to list: [ChatMessage]) -> [ChatMessage] {
        let known = Set(list.map(\.id))
        return older.filter { !known.contains($0.id) } + list
    }

    /// View helper: open once when the host set chatID but never loaded.
    public func openIfNeeded(limit: Int32 = 50) {
        guard !isDemo, !loading, !didLoad, let id = chatID else { return }
        open(chatID: id, limit: limit)
    }

    /// Realtime feed: upsert by id (new appends, known edits in place).
    /// Stamps `isOwn` against the known identity first, unless
    /// `keepOwnership` preserves the sender's stamp (e1-popout send
    /// mirroring — the other window may not know our identity yet).
    public func ingest(_ message: ChatMessage, keepOwnership: Bool = false) {
        var m = message
        if !keepOwnership {
            m.isOwn = ownDisplayName.map { m.sender == $0 } ?? false
        }
        messages = Self.upsert(m, into: messages)
    }

    /// Realtime edit carrying only new text; unknown id is a no-op.
    /// Marks the bubble edited.
    public func ingestEdited(id: String, content: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        guard messages[i].content != content else { return }
        messages[i].content = content
        messages[i].edited = true
    }

    /// Realtime feed: typed event → upsert by id (edits collapse onto
    /// the edited id, so bubbles update in place; unknown edit ids
    /// append, so nothing is lost). Callers filter by chat first via
    /// `RealtimeMessage.isFor(chatID:)`. Counts ride along: events
    /// carrying `reactions` patch the bubble's counts; reaction-only
    /// events (empty text) patch counts without touching the bubble.
    public func ingest(realtime message: RealtimeMessage) {
        let targetID: String
        if message.isEdit, let edited = message.editedID {
            targetID = edited
        } else {
            targetID = message.msgId
        }
        if message.text.isEmpty, let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
            return
        }
        if !message.isEdit {
            var echo = message.asChatMessage
            echo.isOwn = ownDisplayName.map { echo.sender == $0 } ?? false
            if reconcileEcho(echo) {
                if let r = message.reactions { applyReactions(id: targetID, reactions: r) }
                return
            }
        }
        ingest(message.asChatMessage)
        if let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
        }
    }

    /// Demo mode: show canned messages for a chat (offline, no core).
    /// `failed` pre-marks bubbles failed (rich demo's failed own send).
    public func showDemo(
        chatID: String, chatName: String, messages: [ChatMessage],
        failed: Set<String> = []
    ) {
        self.chatID = chatID
        self.chatName = chatName
        self.messages = messages
        failedIDs = failed
        replyTarget = nil
        jumpTargetID = nil
        jumpMissedID = nil
        isDemo = true
        loading = false
        error = nil
        didLoad = true
        onHistory?(chatID, messages)
    }

    /// Arm a quote reply to `message` (bubble Reply action / shot hook).
    /// Unknown ids still arm (the quote block carries the attribution),
    /// but the bubble quote preview needs the parent in `messages`.
    public func beginReply(to message: ChatMessage) {
        replyTarget = message
    }

    /// Disarm the pending reply (chip ✕ / after send / chat switch).
    public func cancelReply() {
        replyTarget = nil
    }

    /// Parent bubble for a reply's `reply_to` id, if still in history.
    /// Nil id or evicted parent → nil (caller shows the fallback quote).
    public func quotedParent(for message: ChatMessage) -> ChatMessage? {
        guard let parentID = message.reply_to else { return nil }
        return messages.first(where: { $0.id == parentID })
    }

    /// Indexed quote lookup (om-s6-renderparse): same answer as the
    /// linear scan, O(1) against a body-eval `MessageIndex`.
    public func quotedParent(for message: ChatMessage, in index: MessageIndex) -> ChatMessage? {
        guard let parentID = message.reply_to else { return nil }
        return index.byID[parentID]
    }

    /// Resolvable quote-link target (om-lt2-quotelink): the parent id
    /// when it is still in history, else nil (plain bubbles, blank
    /// ids, and evicted parents never link; the bubble fallback covers
    /// the last case).
    public func quoteJumpID(for message: ChatMessage, in index: MessageIndex) -> String? {
        guard let parentID = message.reply_to?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentID.isEmpty, index.byID[parentID] != nil
        else { return nil }
        return parentID
    }

    /// One-line quote preview: collapsed whitespace, 120 chars + `…`.
    /// Pure so the bubble, chip, and tests share it.
    public static func quotePreview(_ text: String, max: Int = 120) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > max else { return oneLine }
        let end = oneLine.index(oneLine.startIndex, offsetBy: max)
        return "\(oneLine[..<end])…"
    }

    /// Post via core; appends an optimistic own-bubble immediately.
    /// Demo mode appends locally without touching core.
    /// With `replyTarget` armed, posts through the reply path (quote
    /// block) and disarms; the optimistic bubble already shows the quote.
    /// Core failure marks the bubble failed (per-message state + retry).
    public func send(text: String) {
        // Top10-code: line endings normalized, interior bytes (indent)
        // verbatim — pasted code survives the send path exactly.
        let body = CodeBlocks.sendBody(for: text)
        guard !body.isEmpty else { return }
        let parent = replyTarget
        replyTarget = nil
        // core-a: channel replies join the thread chain (reply_to = the
        // root, matching the wire parent core mines on read); chats keep
        // the quote-reply path (reply_to = the quoted bubble).
        let route = parent.map { Self.replyRoute(chatID: chatID, parent: $0) }
        let replyTo = route?.linkID
        if isDemo {
            let bubble = ChatMessage(
                id: "demo-local-\(messages.count + 1)",
                sender: "Me", timestamp: Self.nowISO(), content: body, isOwn: true,
                reply_to: replyTo)
            messages.append(bubble)
            onLocalSend?(bubble)
            return
        }
        guard let id = chatID else { return }
        // §106: the client message id is the idempotency key for this
        // logical send (every retry reuses it; the echo carries it).
        let cmid = SendReconcile.newClientMessageID()
        let pendingID = SendReconcile.pendingID(for: cmid)
        let bubble = ChatMessage(
            id: pendingID,
            sender: "Me", timestamp: Self.nowISO(), content: body, isOwn: true,
            reply_to: replyTo, clientMessageID: cmid)
        messages.append(bubble)
        onLocalSend?(bubble)
        let wireRoute: OutgoingSend.Route
        switch route {
        case .thread(let rootID)?:
            wireRoute = .thread(rootID: rootID)
        default:
            if let p = parent {
                wireRoute = .reply(parentID: p.id, parentSender: p.sender, parentText: p.content)
            } else {
                wireRoute = .plain
            }
        }
        let request = OutgoingSend(chatID: id, text: body, route: wireRoute, clientMessageID: cmid)
        outgoing[pendingID] = request
        deliver(localID: pendingID, request: request, verifyFirst: false)
    }

    // MARK: - Send reconcile (§106)

    /// Send wire (tests inject a fake; `--send-timeout-shim` wraps it).
    public var sendTransport: SendTransport = .live
    /// In-flight or failed own sends by local row id (Retry re-uses the
    /// request, so the client message id never changes).
    private var outgoing: [String: OutgoingSend] = [:]
    /// Server ids of confirmed own sends no page has carried yet: page
    /// merges keep them (a GET that left before the POST landed must not
    /// drop the bubble). Cleared as pages/echoes carry them.
    private(set) var unseenSentIDs: Set<String> = []
    /// Settle tap: (chatID, settled row, via) once an own send settles.
    /// AppState refreshes the chat list preview/order from it.
    public var onSendSettled: ((String, ChatMessage) -> Void)?

    /// Run one delivery attempt off-main and settle the bubble on-main.
    private func deliver(localID: String, request: OutgoingSend, verifyFirst: Bool) {
        let hop = coreHop
        let transport = sendTransport
        let started = DispatchTime.now().uptimeNanoseconds
        Log.send.info("send start retry=\(verifyFirst, privacy: .public)")
        Task {
            let outcome = await Task.blocking {
                SendPipeline.run(
                    request,
                    transport: SendTransport(
                        post: { r in try hop.run { try transport.post(r) } },
                        find: { c, m in try hop.run { try transport.find(c, m) } }),
                    verifyFirst: verifyFirst)
            }.value
            self.settle(localID: localID, request: request, outcome: outcome, started: started)
        }
    }

    private func settle(localID: String, request: OutgoingSend, outcome: SendOutcome, started: UInt64) {
        let ms = Log.ms(since: started)
        switch outcome {
        case .sent(let serverID, let row, let via):
            outgoing.removeValue(forKey: localID)
            failedIDs.remove(localID)
            Log.send.info("send settled via=\(via.rawValue, privacy: .public) ms=\(ms, privacy: .public) named=\(serverID != nil, privacy: .public)")
            confirmSent(localID: localID, cmid: request.clientMessageID, serverID: serverID, row: row)
        case .failed(let err):
            Log.send.error("send failed after verify ms=\(ms, privacy: .public)")
            // An echo may have settled the row meanwhile — only a row
            // still local can fail.
            guard messages.contains(where: { $0.id == localID }) else {
                outgoing.removeValue(forKey: localID)
                return
            }
            noteSendFailed(id: localID)
            error = "send failed: \(err)"
        }
    }

    /// The local row becomes the server message (in place). No-op when
    /// an echo/page already settled it.
    private func confirmSent(localID: String, cmid: String, serverID: String?, row: ChatMessage?) {
        guard let local = messages.first(where: { $0.id == localID }) else { return }
        var settled: ChatMessage
        if var r = row {
            r.isOwn = true
            settled = r
        } else {
            settled = ChatMessage(
                id: serverID ?? SendReconcile.settledID(for: cmid),
                sender: ownDisplayName ?? local.sender, timestamp: local.timestamp,
                content: local.content, isOwn: true, raw: local.raw,
                reactions: local.reactions, reply_to: local.reply_to,
                clientMessageID: cmid)
        }
        if settled.clientMessageID == nil { settled.clientMessageID = cmid }
        if !SendReconcile.isLocalRow(settled) { unseenSentIDs.insert(settled.id) }
        let next = SendReconcile.replacing(localID, with: settled, in: messages)
        if next != messages { messages = next }
        if let chat = chatID { onSendSettled?(chat, settled) }
    }

    /// Pages that carry confirmed sends end their `unseen` hold.
    private func noteSeen(_ page: [ChatMessage]) {
        guard !unseenSentIDs.isEmpty else { return }
        unseenSentIDs.subtract(page.map(\.id))
    }

    /// §106 echo: a pushed/polled server row carrying the client id of a
    /// row on screen (pending, failed, `sent-`, or confirmed) settles that
    /// row in place — never a second bubble, never an "edited" mark.
    /// Returns false when no row carries the id (normal upsert path).
    @discardableResult
    func reconcileEcho(_ incoming: ChatMessage) -> Bool {
        guard let cmid = incoming.clientMessageID, !cmid.isEmpty,
              let local = messages.first(where: { $0.clientMessageID == cmid })
        else { return false }
        var row = incoming
        row.isOwn = local.isOwn || row.isOwn
        row.reactions = row.reactions.isEmpty ? local.reactions : row.reactions
        if local.id == row.id {
            // Already settled with this id: refresh content quietly.
            guard let i = messages.firstIndex(where: { $0.id == row.id }) else { return true }
            row.edited = messages[i].edited
            if messages[i] != row { messages[i] = row }
        } else {
            let next = SendReconcile.replacing(local.id, with: row, in: messages)
            if next != messages { messages = next }
        }
        if outgoing.removeValue(forKey: local.id) != nil || failedIDs.contains(local.id) {
            Log.send.info("send settled via=echo")
        }
        failedIDs.remove(local.id)
        unseenSentIDs.remove(row.id)
        return true
    }

    /// Last forward from this store (om-msgactions). Set in demo mode
    /// synchronously; in live mode on send success. Powers tests + shots.
    @Published public private(set) var lastForward: MessageActions.ForwardRecord?
    /// Destination chat of the last forward (demo preview + tests).
    @Published public private(set) var lastForwardDestName: String?

    /// Forward one bubble's text to another chat (om-msgactions,
    /// om-copyforward). Reuses the plain send path (no new FFI): the
    /// posted body carries a forwarded-attribution header naming the
    /// original sender, and the destination bubble stamps its own
    /// sender/time. Demo mode records without touching core. Empty
    /// destination or empty payload text is a no-op.
    public func forward(_ message: ChatMessage, toChatID destChatID: String, destName: String? = nil) {
        let dest = destChatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        // Guard on the payload text, not the attributed body: the
        // header alone must never send (image-only bubbles stay a no-op).
        let text = MessageActions.copyText(for: message)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let body = MessageActions.forwardBody(for: message)
        if isDemo {
            lastForward = MessageActions.ForwardRecord(messageID: message.id, destChatID: dest, body: body)
            lastForwardDestName = destName
            return
        }
        let hop = coreHop
        Task {
            do {
                _ = try await Task.blocking {
                    // §106: idempotent + verified (a lost answer never
                    // turns into a second forwarded copy).
                    try hop.run { try SendPipeline.postVerified(chatID: dest, text: body) }
                }.value
                self.lastForward = MessageActions.ForwardRecord(messageID: message.id, destChatID: dest, body: body)
                self.lastForwardDestName = destName
            } catch {
                self.error = "forward failed: \(error)"
            }
        }
    }

    /// Test seam (§106): a live-mode store on `chatID` with rows already
    /// on screen — no core call (tests inject `sendTransport`).
    func attachLiveForTesting(chatID: String, messages: [ChatMessage] = [], ownName: String? = nil) {
        self.chatID = chatID
        self.messages = messages
        ownDisplayName = ownName
        isDemo = false
        didLoad = true
        loading = false
    }

    /// Record a failed optimistic send (test seam + retry bookkeeping).
    func noteSendFailed(id: String) {
        failedIDs.insert(id)
    }

    /// Drop a failed own send locally (it never reached the server):
    /// the bubble and its failed flag go; no core call. Other ids are a
    /// no-op. Returns the dropped bubble's text (Retry re-sends it).
    @discardableResult
    public func discardFailed(id: String) -> String? {
        guard failedIDs.contains(id), let i = messages.firstIndex(where: { $0.id == id }) else { return nil }
        let text = messages[i].content
        failedIDs.remove(id)
        outgoing.removeValue(forKey: id)
        messages.remove(at: i)
        return text
    }

    /// Retry a failed send: clears the flag, re-posts the bubble's text.
    /// No-op for unknown ids. Returns the text re-sent, if any.
    @discardableResult
    public func retry(id: String) -> String? {
        guard failedIDs.contains(id),
              let msg = messages.first(where: { $0.id == id })
        else { return nil }
        failedIDs.remove(id)
        // §106: same bubble, same client message id; verify first (a copy
        // that landed late settles without a second post).
        if let request = outgoing[id] {
            deliver(localID: id, request: request, verifyFirst: true)
            return msg.content
        }
        // No request on record (demo / restored row): plain re-send.
        messages.removeAll { $0.id == id }
        send(text: msg.content)
        return msg.content
    }

    // MARK: - Reactions (om-reactions, extended om-react-polish)

    /// Quick-reaction emoji in canonical order (mirrors core
    /// REACTION_EMOJI): the six with a verified Teams reaction type.
    /// The more-picker's extended catalog ALSO sends live now
    /// (fid-lists D20): the client never pre-judges — the core/server
    /// verdict lands via the normal failure path (revert + verbatim
    /// "react failed" detail), never a made-up "isn't a Teams
    /// reaction" refusal.
    public nonisolated static let reactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "😠"]

    /// UI acceptance: any single grapheme cluster (covers the catalog,
    /// flags, and modifier sequences, which all count as one Character).
    /// Empty and multi-character strings are rejected.
    public static func isReactable(_ emoji: String) -> Bool {
        emoji.count == 1
    }

    /// Toggle one emoji on a bubble: present → remove, absent → add.
    /// Optimistic (counts move now); demo mode stays local; live mode
    /// reverts on core failure. Unknown ids and non-emoji are a no-op.
    public func toggleReaction(messageID: String, emoji: String) {
        guard messages.contains(where: { $0.id == messageID }) else { return }
        guard Self.isReactable(emoji) else { return }
        let present = messages.first(where: { $0.id == messageID })?
            .reactions.contains(where: { $0.emoji == emoji }) ?? false
        if present {
            removeReaction(messageID: messageID, emoji: emoji)
        } else {
            react(messageID: messageID, emoji: emoji)
        }
    }

    /// Add one emoji reaction (optimistic). Unknown ids and non-emoji
    /// are a no-op. ANY single-grapheme emoji attempts the live send
    /// (fid-lists D20: Teams supports 800+); the client no longer
    /// pre-refuses extended emoji. A core/server rejection reverts the
    /// optimistic add and surfaces the verdict verbatim ("react
    /// failed: …") — server-truthful, never a client-invented limit.
    public func react(messageID: String, emoji: String) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard Self.isReactable(emoji) else { return }
        messages[i].reactions = Self.withReactionAdded(messages[i].reactions, emoji: emoji)
        ReactionRecents.record(emoji)
        if isDemo { return }
        guard let id = chatID else { return }
        let hop = coreHop
        Task {
            do {
                _ = try await Task.blocking {
                    try hop.run { try RustCore.react(chatID: id, messageID: messageID, emoji: emoji) }
                }.value
            } catch {
                self.revertReaction(messageID: messageID, emoji: emoji, added: true)
                self.error = "react failed: \(error)"
            }
        }
    }

    /// Edit an own bubble via core; optimistic in-place update, rollback on
    /// failure. Demo mode edits locally. Unknown id / empty text are no-ops.
    public func edit(messageID: String, text: String) {
        let body = CodeBlocks.sendBody(for: text)
        guard !body.isEmpty else { return }
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard messages[i].content != body else { return }
        if isDemo {
            messages = Self.applyingEdit(id: messageID, content: body, to: messages)
            return
        }
        guard let id = chatID else { return }
        let old = messages[i].content
        let wasEdited = messages[i].edited
        messages = Self.applyingEdit(id: messageID, content: body, to: messages)
        let hop = coreHop
        Task {
            do {
                _ = try await Task.blocking {
                    try hop.run { try RustCore.edit(chatID: id, messageID: messageID, text: body) }
                }.value
            } catch {
                // Roll back to the pre-edit text.
                if let j = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[j].content = old
                    self.messages[j].edited = wasEdited
                }
                self.error = "edit failed: \(error)"
            }
        }
    }

    /// Remove one emoji reaction (optimistic). Unknown ids and
    /// emoji with no local bucket are a no-op (nothing held, nothing
    /// to remove — and no doomed core call whose failure-revert would
    /// conjure a phantom bucket). Present buckets of ANY emoji attempt
    /// the live remove (fid-lists D20: the server may hold extended
    /// reactions now); failures revert + surface verbatim.
    public func removeReaction(messageID: String, emoji: String) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard messages[i].reactions.contains(where: { $0.emoji == emoji }) else { return }
        messages[i].reactions = Self.withReactionRemoved(messages[i].reactions, emoji: emoji)
        if isDemo { return }
        guard let id = chatID else { return }
        let hop = coreHop
        Task {
            do {
                _ = try await Task.blocking {
                    try hop.run { try RustCore.removeReaction(chatID: id, messageID: messageID, emoji: emoji) }
                }.value
            } catch {
                self.revertReaction(messageID: messageID, emoji: emoji, added: false)
                self.error = "react failed: \(error)"
            }
        }
    }

    /// Undo one optimistic reaction change after a core failure.
    private func revertReaction(messageID: String, emoji: String, added: Bool) {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[i].reactions = added
            ? Self.withReactionRemoved(messages[i].reactions, emoji: emoji)
            : Self.withReactionAdded(messages[i].reactions, emoji: emoji)
    }

    /// Replace one bubble's counts (realtime patch, server truth).
    /// Unknown ids are a no-op — counts never conjure a bubble.
    public func applyReactions(id: String, reactions: [ReactionCount]) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].reactions = reactions
    }

    /// Pure add: bump the emoji bucket, or append it (picker order kept).
    public static func withReactionAdded(_ list: [ReactionCount], emoji: String) -> [ReactionCount] {
        var out = list
        if let i = out.firstIndex(where: { $0.emoji == emoji }) {
            out[i] = ReactionCount(emoji: emoji, count: out[i].count + 1, reactors: out[i].reactors)
        } else {
            out.append(ReactionCount(emoji: emoji, count: 1))
            let order = reactionEmojis
            out.sort { (order.firstIndex(of: $0.emoji) ?? Int.max) < (order.firstIndex(of: $1.emoji) ?? Int.max) }
        }
        return out
    }

    /// Pure remove: decrement the emoji bucket; drop it at zero.
    /// Missing emoji leaves the list untouched.
    public static func withReactionRemoved(_ list: [ReactionCount], emoji: String) -> [ReactionCount] {
        var out = list
        guard let i = out.firstIndex(where: { $0.emoji == emoji }) else { return out }
        if out[i].count > 1 {
            out[i] = ReactionCount(emoji: emoji, count: out[i].count - 1, reactors: out[i].reactors)
        } else {
            out.remove(at: i)
        }
        return out
    }

    /// Seconds an own 1:1 tombstone lingers before fading (fid-msgs
    /// D12): real Teams shows the deleter-only tombstone for a few
    /// minutes, then drops the row. Group/channel tombstones persist.
    public static let tombstoneFadeSeconds: UInt64 = 5 * 60

    /// Record a peer delete (fid-msgs D12): group/channel chats keep a
    /// tombstone bubble; 1:1 drops the row (real Teams shows the
    /// tombstone to the deleter only, so a peer delete is invisible to
    /// us). Unknown id is a no-op. Callers pass the open chat's shape;
    /// core surfaces no wire delete event yet, so sync call sites feed
    /// this when a delete is observed out-of-band.
    public func ingestDeleted(id: String, isOneToOne: Bool = false) {
        guard messages.contains(where: { $0.id == id }) else { return }
        if isOneToOne {
            messages = Self.removing(id: id, from: messages)
        } else {
            messages = Self.applyingDelete(id: id, to: messages)
        }
    }

    /// Delete an own bubble via core; optimistic tombstone, unmarked on
    /// failure. Demo mode tombstones locally. Unknown id is a no-op.
    /// 1:1 tombstones fade after `tombstoneFadeSeconds` (Teams parity).
    public func deleteMessage(id: String, isOneToOne: Bool = false) {
        guard messages.contains(where: { $0.id == id }) else { return }
        if isDemo {
            messages = Self.applyingDelete(id: id, to: messages)
            if let chat = chatID { onDelete?(chat, id) }
            if isOneToOne { scheduleTombstoneFade(id: id) }
            return
        }
        guard let chat = chatID,
              let before = messages.first(where: { $0.id == id })
        else { return }
        messages = Self.applyingDelete(id: id, to: messages)
        failedIDs.remove(id)
        if isOneToOne { scheduleTombstoneFade(id: id) }
        let hop = coreHop
        Task {
            do {
                _ = try await Task.blocking {
                    try hop.run { try RustCore.deleteMessage(chatID: chat, messageID: id) }
                }.value
                self.onDelete?(chat, id)
            } catch {
                // Unmark the tombstone (same row, original bubble back).
                if let j = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[j] = before
                }
                self.error = "delete failed: \(error)"
            }
        }
    }

    /// Drop a 1:1 tombstone after the fade interval. No-op when the row
    /// is gone or was unmarked (delete failure rolled back).
    private func scheduleTombstoneFade(id: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.tombstoneFadeSeconds * 1_000_000_000)
            guard let self else { return }
            guard self.messages.contains(where: { $0.id == id && $0.deleted }) else { return }
            self.messages = Self.removing(id: id, from: self.messages)
        }
    }

    /// Pure edit: rewrite content in place + mark edited; unknown id unchanged.
    public static func applyingEdit(id: String, content: String, to list: [ChatMessage]) -> [ChatMessage] {
        var out = list
        guard let i = out.firstIndex(where: { $0.id == id }) else { return out }
        out[i].content = content
        out[i].edited = true
        return out
    }

    /// Pure delete: drop the bubble; unknown id unchanged. Kept for
    /// 1:1 peer deletes (deleter-only tombstones) + tombstone fades.
    public static func removing(id: String, from list: [ChatMessage]) -> [ChatMessage] {
        list.filter { $0.id != id }
    }

    /// Pure tombstone (fid-msgs D12): mark deleted in place (row stays);
    /// content/raw/reactions clear so the tombstone leaks no old text
    /// to Copy, previews, or search. Unknown id unchanged.
    public static func applyingDelete(id: String, to list: [ChatMessage]) -> [ChatMessage] {
        var out = list
        guard let i = out.firstIndex(where: { $0.id == id }) else { return out }
        out[i].content = ""
        out[i].raw = nil
        out[i].reactions = []
        out[i].edited = false
        out[i].deleted = true
        return out
    }

    /// Pure upsert: new id appends; known id rewrites content in place and
    /// marks the bubble edited.
    public static func upsert(_ message: ChatMessage, into list: [ChatMessage]) -> [ChatMessage] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == message.id }) {
            // Same-content redelivery is not an edit: no marker.
            if out[i].content != message.content {
                out[i].content = message.content
                out[i].edited = true
            }
        } else {
            out.append(message)
        }
        return out
    }

    static func nowISO() -> String {
        isoPlain.string(from: Date())
    }

    // MARK: - Demo mode (canned messages for offline shots)

    public static func demo() -> ConversationStore {
        let s = ConversationStore()
        s.isDemo = true
        s.chatID = "demo"
        s.chatName = "Design Sync"
        s.messages = demoMessages
        s.didLoad = true
        return s
    }

    public nonisolated static let demoMessages: [ChatMessage] = [
        ChatMessage(
            id: "demo-1", sender: "Megan Harper",
            timestamp: "2026-09-22T09:02:11Z",
            content: "Morning! Design sync in 10. Today: onboarding flow + empty states."),
        ChatMessage(
            id: "demo-2", sender: "Tom Becker",
            timestamp: "2026-09-22T09:04:47Z",
            content: "Pushed new mocks for the chat window last night — bubbles, timestamps, the works."),
        ChatMessage(
            id: "demo-3", sender: "Megan Harper",
            timestamp: "2026-09-22T09:06:02Z",
            content: "Love the bubble alignment. Can we keep edited messages in place instead of re-sorting?"),
        ChatMessage(
            id: "demo-4", sender: "Me",
            timestamp: "2026-09-22T09:07:30Z",
            content: "Yes — an edited message stays right where it was.", isOwn: true),
        ChatMessage(
            id: "demo-5", sender: "Tom Becker",
            timestamp: "2026-09-22T09:09:15Z",
            content: "And sending holds up on a flaky connection? No lost drafts?"),
        ChatMessage(
            id: "demo-6", sender: "Me",
            timestamp: "2026-09-22T09:10:41Z",
            content: "It shows up right away and confirms once it's delivered. If it fails, you can retry.", isOwn: true),
        ChatMessage(
            id: "demo-7", sender: "Megan Harper",
            timestamp: "2026-09-22T09:12:05Z",
            content: "Ship it. I'll take screenshots for the review deck."),
    ]

    // MARK: - Rich demo (om-convrich: mentions, code, edits, failure, 2 days)

    /// Canned store exercising every rich state: day separators (yesterday +
    /// today), @mentions, code blocks, backticks, a link, an edited bubble,
    /// and one failed own send with retry. Timestamps float off now so the
    /// separators always read Yesterday/Today. Offline, no sign-in.
    public static func demoRich() -> ConversationStore {
        let s = ConversationStore()
        s.isDemo = true
        s.chatID = "demo-rich"
        s.chatName = "Q3 Review Deck"
        s.messages = richDemoMessages()
        s.didLoad = true
        s.failedIDs = ["rich-fail"]
        return s
    }

    public nonisolated static func richDemoMessages(now: Date = DemoClock.now) -> [ChatMessage] {
        func iso(_ d: Date) -> String {
            d.ISO8601Format() // == isoPlain output; nonisolated-safe
        }
        func at(dayOffset: Int, h: Int, m: Int) -> Date {
            var cal = Calendar.current
            cal.timeZone = TimeZone.current
            let base = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: base) ?? base
        }
        return [
            ChatMessage(
                id: "rich-1", sender: "Megan Harper",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 2)),
                content: "Kicking off the review deck. @Tom Becker can you take the code samples?",
                raw: "<p>Kicking off the review deck. <at id=\"8:t\">@Tom Becker</at> can you take the code samples?</p>"),
            ChatMessage(
                id: "rich-2", sender: "Tom Becker",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 5)),
                content: "On it. Last night's release notes are here: https://example.com/deploys/42",
                raw: "<p>On it. Last night's release notes are here: <a href=\"https://example.com/deploys/42\">https://example.com/deploys/42</a></p>"),
            ChatMessage(
                id: "rich-3", sender: "Tom Becker",
                timestamp: iso(at(dayOffset: -1, h: 16, m: 7)),
                content: "Here's the header fix — run `git pull` first, then:\nlet height = row.measure(width) // once per width",
                raw: "<p>Here's the header fix — run `git pull` first, then:</p><pre>let height = row.measure(width) // once per width</pre>"),
            ChatMessage(
                id: "rich-4", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 1)),
                content: "Morning — the Q3 numbers are in the shared folder.",
                isOwn: true),
            ChatMessage(
                id: "rich-5", sender: "Megan Harper",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 4)),
                content: "Thanks. @Jordan Fox can you check the timeline slide before 10?",
                raw: "<p>Thanks. <at id=\"8:me\">@Jordan Fox</at> can you check the timeline slide before 10?</p>",
                edited: true),
            ChatMessage(
                id: "rich-6", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 6)),
                content: "Checked — it reads well. I tightened the `Q3 targets` table.",
                isOwn: true),
            ChatMessage(
                id: "rich-fail", sender: "Me",
                timestamp: iso(at(dayOffset: 0, h: 9, m: 8)),
                content: "Sending the final deck to the client now.",
                isOwn: true),
        ]
    }

    // MARK: - Pure conversation helpers (moved verbatim from
    // ConversationView.swift in the scratch-ui rebuild; the view was
    // deleted, the helpers stay on the store).

    /// Prefetch gate (om-fix-tabs): Shared loads on every chat change,
    /// whatever tab is showing — by the time the user taps Shared the
    /// rows are cached and the switch is instant (native, no wait, no
    /// custom transition). Pure, testable.
    public nonisolated static func shouldPrefetchShared(sharedChatID: String?, chatID: String?) -> Bool {
        guard let chatID else { return false }
        return sharedChatID != chatID
    }

    nonisolated static func appendGIF(_ url: String, to draft: String) -> String {
        draft.isEmpty ? url : "\(draft) \(url)"
    }

    /// Shot-hook parse (om-history): `--scroll-to <message-id>` lands the
    /// initial scroll on that bubble. Pure, testable.
    nonisolated static func scrollTarget(args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--scroll-to"), i + 1 < args.count else { return nil }
        let id = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// How a reply is posted (core-a). Channels: into the thread chain
    /// under the root post (`<channel>;messageid=<root>`), never a new
    /// top-level quoted post. Chats: a quote reply to the bubble.
    public enum ReplyRoute: Equatable, Sendable {
        case thread(rootID: String)
        case quote(parentID: String)

        /// Id the optimistic bubble links to (`reply_to`).
        public var linkID: String {
            switch self {
            case .thread(let root): root
            case .quote(let parent): parent
            }
        }
    }

    /// True for channel conversations: live `19:…@thread.tacv2` /
    /// legacy `@thread.skype` (ost `is_channel_conversation_id`), plus
    /// demo channel ids (`demo-chan-…`).
    nonisolated public static func isChannelConversation(_ chatID: String?) -> Bool {
        let t = (chatID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("demo-chan-") { return true }
        return t.hasPrefix("19:") && (t.hasSuffix("@thread.tacv2") || t.hasSuffix("@thread.skype"))
    }

    /// Pure reply routing. A channel reply's root is the parent's own
    /// root (`reply_to`, i.e. replying to a reply stays in its chain),
    /// else the parent itself (it is a root post).
    nonisolated public static func replyRoute(chatID: String?, parent: ChatMessage) -> ReplyRoute {
        guard isChannelConversation(chatID) else { return .quote(parentID: parent.id) }
        let root = parent.reply_to?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .thread(rootID: root.isEmpty ? parent.id : root)
    }

    /// Composer placeholder per surface (fid-msgs D14): channel
    /// threads say "Reply", plain chats say "Type a message...".
    nonisolated static func composerPlaceholder(chatID: String?) -> String {
        ChannelTabsStore.isChannelID(chatID ?? "") ? "Reply" : "Type a message..."
    }

    /// Shot-hook arming gate (F5): the catch-up popover auto-opens
    /// only with explicit intent, unarmed, and a non-empty thread.
    public nonisolated static func shouldArmCatchUpShot(
        autoOpen: Bool, armed: Bool, messageCount: Int
    ) -> Bool {
        autoOpen && !armed && messageCount > 0
    }
}
