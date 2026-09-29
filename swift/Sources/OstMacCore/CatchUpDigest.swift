// CatchUpDigest.swift — AICATCH lane: the cross-conversation catch-up
// behind the Catch Up window.
//
// Fed by message arrivals (realtime feed, fetched history, demo seed).
// Mentions of the user / @everyone are flagged the moment a message
// lands (deterministic, from mention entities — never the model) in
// every mode but Off. Summaries:
//   - Off: nothing is kept and nothing runs.
//   - When I click: summaries run only on "Update Now".
//   - Always up to date: a debounced background cycle re-summarizes
//     ONLY conversations whose messages changed since their last
//     summary, newest activity first, at most `maxChatsPerCycle` per
//     cycle, at utility priority; a conversation with a previous
//     summary folds in just its new messages (one small call). Idle =
//     no timer at all. Low Power Mode or thermal state ≥ .serious
//     pause the cycle; it resumes when conditions clear.
// UI stability: entries update in place (same id), the old summary
// stays until its replacement lands, and nothing clears on refresh.
//
// CATCHTABS: period tabs (24 hours / 3 days / 5 days / 2 weeks). Every
// summary and mention is HARD-bounded by message age for its period;
// each period keeps its own summaries, so switching tabs paints from
// cache at once and only the selected period is kept current. Model
// input passes the deterministic noise filter + salience ranking and
// every summary gets the bullet rating pass (CatchUpFilter.swift).
// Nothing older than the longest period is held. Older history for the
// longer periods comes from a bounded, utility-priority backfill.
//
// The leak that put a last-week lunch order into a "current" summary:
// nothing bounded message age. Seeds took each unread chat's newest 60
// messages whatever their age, every fetched history page (including
// scrolling back a week) was ingested and re-summarized, and the
// incremental path folded new messages into the previous summary, so
// content never aged out of it. Now: ingest drops anything older than
// two weeks, input is period-bounded, and the incremental path runs only
// while the oldest message behind the previous summary is still inside
// the period.
import Combine
import Foundation

@MainActor
public final class CatchUpDigestStore: ObservableObject {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let chatID: String
        public var chatName: String
        public var text: String
        public var updatedAt: Date
        /// Newest message timestamp at summary time (sort key).
        public var lastActivity: String
        public var id: String { chatID }
    }

    public enum Pause: Equatable, Sendable {
        case lowPower, thermal
    }

    /// Selected period tab (persisted).
    @Published public private(set) var period: CatchUpPeriod
    /// Mentions section collapsed (persisted).
    @Published public var mentionsCollapsed: Bool {
        didSet { defaults.set(mentionsCollapsed, forKey: Self.collapsedKey) }
    }
    /// Summaries for the selected period, newest activity first.
    @Published public private(set) var entries: [Entry] = []
    /// Flagged mentions inside the selected period, newest first.
    @Published public private(set) var mentions: [CatchUpMention] = []
    /// Conversation being summarized now (nil when idle).
    @Published public private(set) var working: String?
    /// Name of `working` (a first summary streams in before its entry).
    @Published public private(set) var workingName: String?
    /// Streaming text for `working` (cumulative), nil when none.
    @Published public private(set) var streamingText: String?
    /// Conversations with messages newer than their summary (selected period).
    @Published public private(set) var pending = 0
    @Published public private(set) var paused: Pause?
    @Published public private(set) var lastError: String?
    /// Why tag mentions (@tag) can't be sorted right now (the tag read
    /// failed); nil when tags loaded or aren't needed. Shown in the
    /// Catch Up status bar with a Retry (`retryTags`).
    @Published public private(set) var tagsError: String?
    /// Re-run the tag read (set by the app; nil in demo).
    public var retryTags: (() -> Void)?
    /// True once any cycle finished (first-ever load vs refresh).
    @Published public private(set) var hasRunOnce = false
    /// Periods whose summaries have been filled at least once.
    @Published public private(set) var filledPeriods: Set<CatchUpPeriod> = []

    /// The selected period has no summaries yet and is being filled.
    public var isFilling: Bool { working != nil && !filledPeriods.contains(period) }

    /// Coalescing window between an arrival and the cycle it triggers.
    public var debounce: Duration = .seconds(30)
    /// Delay before filling a newly selected tab (Always up to date).
    public var fillDelay: Duration = .seconds(1)
    /// Cap on conversations summarized per background cycle.
    public var maxChatsPerCycle = 3
    /// Cap per user-initiated cycle (Update Now, a tab switch).
    public var maxChatsPerUserCycle = 10
    /// Older-history backfills per cycle (each is ≤ a few pages).
    public var maxBackfillsPerCycle = 3
    public static let maxMessagesPerChat = 400
    public static let maxMentions = 50
    static let collapsedKey = "catchup.mentionsCollapsed"

    /// Completed summaries (measurement + tests).
    public private(set) var summariesRun = 0

    /// Signed-in identity for mention flagging (set by the app).
    public var ownerMRI: () -> String? = { nil }
    public var ownerDisplayName: () -> String = { "" }
    /// Lowercased names of Teams tags that include the user.
    public var ownerTags: () -> Set<String> = { [] }
    /// Clock (demo pins it; tests fix it).
    public var now: () -> Date = { Date() }
    /// Conversations to read when the digest starts empty (the app
    /// supplies unread/recent threads; demo supplies demo threads).
    public var seed: () -> [(chatID: String, chatName: String, messages: [ChatMessage])] = { [] }
    /// Older history for one conversation back to a date (read-only
    /// page fetches, bounded by the app). Nil = no backfill (demo).
    public var backfill: ((_ chatID: String, _ since: Date) async -> [ChatMessage])?
    public let feedback: CatchUpFeedbackStore

    private struct Summarized {
        var key: ThreadSummaryCache.Key
        var firstID: String?
        var lastID: String?
    }

    private struct Thread {
        var name: String
        var messages: [ChatMessage] = []
        var summarized: [CatchUpPeriod: Summarized] = [:]
        /// History is known complete back to this date.
        var coveredSince: Date?
    }

    private var threads: [String: Thread] = [:]
    private var byPeriod: [CatchUpPeriod: [Entry]] = [:]
    private var allMentions: [CatchUpMention] = []
    private var seeded = false
    /// Conversations by latest arrival, newest last.
    private var order: [String] = []
    /// Conversations needing a summary for the selected period.
    private var dirty: Set<String> = []
    private var cycleTask: Task<Void, Never>?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private let transport: any CatchUpTransport
    private let mode: () -> CatchUpMode
    private let conditions: () -> (lowPower: Bool, thermal: ProcessInfo.ThermalState)
    private let defaults: UserDefaults

    public init(
        transport: any CatchUpTransport,
        mode: @escaping () -> CatchUpMode,
        conditions: (() -> (lowPower: Bool, thermal: ProcessInfo.ThermalState))? = nil,
        observeSystem: Bool = true,
        defaults: UserDefaults = .standard,
        feedback: CatchUpFeedbackStore? = nil
    ) {
        self.transport = transport
        self.mode = mode
        self.defaults = defaults
        self.feedback = feedback ?? CatchUpFeedbackStore(defaults: defaults)
        period = defaults.string(forKey: CatchUpPeriod.defaultsKey).flatMap(CatchUpPeriod.init(rawValue:)) ?? .day
        mentionsCollapsed = defaults.bool(forKey: Self.collapsedKey)
        self.conditions = conditions ?? {
            (ProcessInfo.processInfo.isLowPowerModeEnabled, ProcessInfo.processInfo.thermalState)
        }
        if observeSystem {
            let nc = NotificationCenter.default
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                         ProcessInfo.thermalStateDidChangeNotification]
            {
                observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.systemConditionsChanged() }
                })
            }
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        cycleTask?.cancel()
    }

    /// Filter inputs for one conversation (the inspector uses it too).
    public func filterContext(chatID: String?) -> CatchUpFilterContext {
        CatchUpFilterContext(now: now(), chatID: chatID, ownerMRI: ownerMRI(), ownerDisplayName: ownerDisplayName(),
                             ownerTags: ownerTags(), feedback: feedback.value)
    }

    // MARK: - Input

    /// New or fetched messages for one conversation. No-op when Off.
    /// Messages older than the longest period are never held.
    public func ingest(chatID: String, chatName: String, messages: [ChatMessage]) {
        guard mode() != .off else { return }
        let fresh = CatchUpBound.messages(messages, period: .longest, now: now())
        guard !fresh.isEmpty else { return }
        merge(chatID: chatID, chatName: chatName, messages: fresh)
        flagMentions(in: fresh, chatID: chatID, chatName: threads[chatID]?.name ?? chatName)
        order.removeAll { $0 == chatID }
        order.append(chatID)
        let at = now()
        if isDirty(chatID, period, at) { dirty.insert(chatID) } else { dirty.remove(chatID) }
        if dirty.count != pending { pending = dirty.count }
        if mode() == .alwaysUpToDate { schedule(after: debounce) }
    }

    private func merge(chatID: String, chatName: String, messages: [ChatMessage]) {
        var t = threads[chatID] ?? Thread(name: chatName)
        if !chatName.isEmpty { t.name = chatName }
        var byID: [String: Int] = [:]
        for (i, m) in t.messages.enumerated() { byID[m.id] = i }
        for m in messages {
            if let i = byID[m.id] { t.messages[i] = m } else {
                byID[m.id] = t.messages.count
                t.messages.append(m)
            }
        }
        t.messages.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        if t.messages.count > Self.maxMessagesPerChat {
            t.messages.removeFirst(t.messages.count - Self.maxMessagesPerChat)
        }
        threads[chatID] = t
    }

    /// Tab switch: paints the period's cached summaries at once, then
    /// fills what changed in the background (Always up to date), or on
    /// this click (When I click, once the user has caught up before).
    public func select(_ p: CatchUpPeriod) {
        guard p != period else { return }
        period = p
        defaults.set(p.rawValue, forKey: CatchUpPeriod.defaultsKey)
        publishSelected()
        guard !running else { return } // the running cycle re-checks at its end
        switch mode() {
        case .off: break
        case .alwaysUpToDate:
            cycleTask?.cancel()
            cycleTask = nil
            schedule(after: fillDelay)
        case .onClick:
            if hasRunOnce, pending > 0 { Task { await runCycle(userInitiated: true) } }
        }
    }

    /// Setting change: Off drops everything and stops; on-click stops
    /// the background cycle; always-up-to-date seeds (when empty) and
    /// starts one soon.
    public func modeChanged(_ m: CatchUpMode) {
        switch m {
        case .off:
            cycleTask?.cancel()
            cycleTask = nil
            threads = [:]
            byPeriod = [:]
            allMentions = []
            order = []
            dirty = []
            seeded = false
            entries = []
            mentions = []
            filledPeriods = []
            working = nil
            streamingText = nil
            pending = 0
            paused = nil
            lastError = nil
        case .onClick:
            cycleTask?.cancel()
            cycleTask = nil
            seedIfNeeded()
        case .alwaysUpToDate:
            seedIfNeeded()
            schedule(after: .seconds(2))
        }
    }

    func setTagsError(_ message: String?) { tagsError = message }

    /// User-initiated refresh (Catch Up window): runs now, ignoring
    /// the debounce and the power pause (the user asked).
    public func updateNow() {
        guard mode() != .off else { return }
        seedIfNeeded()
        cycleTask?.cancel()
        cycleTask = nil
        Task { await runCycle(userInitiated: true) }
    }

    // MARK: - Selected-period views

    private func bounded(_ t: Thread, _ p: CatchUpPeriod, _ at: Date) -> [ChatMessage] {
        CatchUpBound.messages(t.messages, period: p, now: at)
    }

    private func summaryKey(_ chatID: String, _ p: CatchUpPeriod, _ msgs: [ChatMessage]) -> ThreadSummaryCache.Key {
        ThreadSummaryCache.key(chatID: "\(chatID)|\(p.rawValue)", messages: msgs)
    }

    private func isDirty(_ chatID: String, _ p: CatchUpPeriod, _ at: Date) -> Bool {
        guard let t = threads[chatID] else { return false }
        let b = bounded(t, p, at)
        guard !b.isEmpty else { return false }
        return summaryKey(chatID, p, b) != t.summarized[p]?.key
    }

    /// Full recount for the selected period (tab switch, cycle end);
    /// an arrival updates only its own conversation.
    private func recountPending() {
        let at = now()
        dirty = Set(order.filter { isDirty($0, period, at) })
        if dirty.count != pending { pending = dirty.count }
    }

    /// Entries + mentions for the selected period; entries whose
    /// conversation has no message left inside the period drop.
    private func publishSelected() {
        let at = now()
        var list = byPeriod[period] ?? []
        list.removeAll { e in threads[e.chatID].map { bounded($0, period, at).isEmpty } ?? true }
        byPeriod[period] = list
        if list != entries { entries = list }
        publishMentions(at)
        recountPending()
    }

    private func publishMentions(_ at: Date) {
        let cutoff = period.cutoff(now: at)
        let m = Array(allMentions.filter {
            (TeamsTime.parseISO($0.timestamp.trimmingCharacters(in: .whitespaces)) ?? .distantPast) >= cutoff
        }.prefix(Self.maxMentions))
        if m != mentions { mentions = m }
    }

    // MARK: - Cycle

    /// Seeds once per on-period. Not "when empty": a conversation opened
    /// before the mode switch (its history is ingested) must not stop the
    /// unread conversations from being seeded. Re-ingesting a thread that
    /// is already held only merges by message id.
    private func seedIfNeeded() {
        guard !seeded else { return }
        let picks = seed()
        guard !picks.isEmpty else { return }
        seeded = true
        for s in picks { ingest(chatID: s.chatID, chatName: s.chatName, messages: s.messages) }
    }

    private func schedule(after delay: Duration) {
        guard cycleTask == nil, !running, pending > 0, mode() == .alwaysUpToDate else { return }
        if let p = currentPause() {
            paused = p
            return
        }
        cycleTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.runCycle(userInitiated: false)
        }
    }

    private func currentPause() -> Pause? {
        let c = conditions()
        if c.lowPower { return .lowPower }
        if c.thermal == .serious || c.thermal == .critical { return .thermal }
        return nil
    }

    private func systemConditionsChanged() {
        let p = currentPause()
        guard p != paused else { return }
        paused = p
        if p != nil {
            cycleTask?.cancel()
            cycleTask = nil
        } else {
            schedule(after: .seconds(5))
        }
    }

    /// One cycle over the SELECTED period only: up to the cap of changed
    /// conversations, newest activity first. Test seam (internal).
    func runCycle(userInitiated: Bool) async {
        cycleTask = nil
        guard !running, mode() != .off else { return }
        guard userInitiated || mode() == .alwaysUpToDate else { return }
        if !userInitiated, let p = currentPause() {
            paused = p
            return
        }
        paused = nil
        running = true
        let p = period
        publishSelected()
        let cap = userInitiated ? maxChatsPerUserCycle : maxChatsPerCycle
        let startAt = now()
        let picks = Array(order.reversed().filter { isDirty($0, p, startAt) }.prefix(cap))
        var stop = false
        var backfills = 0
        for chatID in picks {
            guard !stop, !Task.isCancelled, mode() != .off, period == p, threads[chatID] != nil else { break }
            let at = now()
            let cutoff = p.cutoff(now: at)
            working = chatID
            workingName = threads[chatID]?.name
            streamingText = nil
            // Longer periods: fetch older history once per period reach.
            if let backfill, backfills < maxBackfillsPerCycle, let t = threads[chatID],
               t.coveredSince.map({ $0 > cutoff }) ?? true,
               let oldest = t.messages.first.flatMap(CatchUpBound.date), oldest > cutoff
            {
                backfills += 1
                // The app's backfill runs its page reads detached at utility.
                let older = await backfill(chatID, cutoff)
                let kept = CatchUpBound.messages(older, period: .longest, now: at)
                if !kept.isEmpty {
                    merge(chatID: chatID, chatName: "", messages: kept)
                    flagMentions(in: kept, chatID: chatID, chatName: threads[chatID]?.name ?? "")
                }
                threads[chatID]?.coveredSince = cutoff
            }
            guard let t = threads[chatID] else { continue }
            let window = bounded(t, p, at)
            let key = summaryKey(chatID, p, window)
            let ctx = filterContext(chatID: chatID)
            let input = CatchUpPipeline.prepare(t.messages, period: p, ctx)
            guard !input.isEmpty else {
                // Only noise in this period: no summary for it.
                remove(chatID: chatID, from: p)
                threads[chatID]?.summarized[p] = Summarized(key: key, firstID: nil, lastID: nil)
                continue
            }
            // Incremental only while every message behind the previous
            // summary is still inside the period (else old content would
            // never age out of it).
            let previous: OnDeviceCatchUpEngine.Previous? = {
                guard let s = t.summarized[p], let first = s.firstID, let last = s.lastID,
                      input.contains(where: { $0.id == first }),
                      let e = byPeriod[p]?.first(where: { $0.chatID == chatID }) else { return nil }
                return .init(text: e.text, afterMessageID: last)
            }()
            let engine = OnDeviceCatchUpEngine(transport: transport)
            let rater = transport
            do {
                // Utility, not background: the request's QoS carries into
                // the system inference service, and background QoS starved
                // there under load (measured: 3 summaries took 216 s vs
                // ~7–11 s each at default; 0 of 15 arrivals summarized in
                // 404 s). Utility stays energy-efficient and still yields.
                let text = try await Task.blocking(priority: .utility) {
                    let raw = try await engine.summarize(messages: input, previous: previous) { [weak self] snapshot in
                        Task { @MainActor [weak self] in
                            guard let self, self.working == chatID else { return }
                            if let s = self.streamingText, snapshot.count < s.count { return }
                            self.streamingText = snapshot
                        }
                    }
                    return await CatchUpPipeline.refine(raw, ctx, rater: rater)
                }.value
                guard mode() != .off else { break }
                apply(chatID: chatID, name: t.name, text: text, lastActivity: input.last?.timestamp ?? "", period: p)
                summariesRun += 1
                lastError = nil
            } catch is CancellationError {
                break
            } catch let e as CatchUpError {
                lastError = e.message
                // Availability problems stop the cycle (no retry spin);
                // a per-chat failure waits for that chat's next message.
                switch e {
                case .onDeviceFailed, .empty: break
                default: stop = true
                }
            } catch {
                lastError = String(describing: error)
            }
            if !stop {
                threads[chatID]?.summarized[p] = Summarized(key: key, firstID: input.first?.id, lastID: input.last?.id)
            }
        }
        working = nil
        workingName = nil
        streamingText = nil
        if !stop, !picks.isEmpty || byPeriod[p] != nil { filledPeriods.insert(p) }
        hasRunOnce = true
        running = false
        publishSelected()
        guard !stop else { return }
        if period != p {
            // The tab changed mid-cycle: fill the new one now.
            switch mode() {
            case .alwaysUpToDate: schedule(after: fillDelay)
            case .onClick: if pending > 0 { Task { await runCycle(userInitiated: true) } }
            case .off: break
            }
        } else {
            schedule(after: debounce)
        }
    }

    /// In-place update (same id, same slot unless its activity moved).
    private func apply(chatID: String, name: String, text: String, lastActivity: String, period p: CatchUpPeriod) {
        let entry = Entry(chatID: chatID, chatName: name, text: text, updatedAt: Date(), lastActivity: lastActivity)
        var next = byPeriod[p] ?? []
        if let i = next.firstIndex(where: { $0.chatID == chatID }) { next[i] = entry } else { next.append(entry) }
        next.sort { $0.lastActivity > $1.lastActivity }
        byPeriod[p] = next
        if p == period, next != entries { entries = next }
    }

    private func remove(chatID: String, from p: CatchUpPeriod) {
        guard var list = byPeriod[p], list.contains(where: { $0.chatID == chatID }) else { return }
        list.removeAll { $0.chatID == chatID }
        byPeriod[p] = list
        if p == period { entries = list }
    }

    private func flagMentions(in messages: [ChatMessage], chatID: String, chatName: String) {
        let found = CatchUpMentions.flag(messages, chatID: chatID, chatName: chatName,
                                         ownerMRI: ownerMRI(), ownerDisplayName: ownerDisplayName(),
                                         ownerTags: ownerTags())
        guard !found.isEmpty else { return }
        var next = allMentions
        for f in found {
            if let i = next.firstIndex(where: { $0.id == f.id }) { next[i] = f } else { next.append(f) }
        }
        next.sort { ($0.timestamp, $0.id) > ($1.timestamp, $1.id) }
        if next.count > Self.maxMentions * 4 { next.removeLast(next.count - Self.maxMentions * 4) }
        allMentions = next
        publishMentions(now())
    }
}
