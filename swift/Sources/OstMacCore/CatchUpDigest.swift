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

    /// Summaries, newest activity first.
    @Published public private(set) var entries: [Entry] = []
    /// Flagged mentions, newest first.
    @Published public private(set) var mentions: [CatchUpMention] = []
    /// Conversation being summarized now (nil when idle).
    @Published public private(set) var working: String?
    /// Name of `working` (a first summary streams in before its entry).
    @Published public private(set) var workingName: String?
    /// Streaming text for `working` (cumulative), nil when none.
    @Published public private(set) var streamingText: String?
    /// Conversations with messages newer than their summary.
    @Published public private(set) var pending = 0
    @Published public private(set) var paused: Pause?
    @Published public private(set) var lastError: String?
    /// True once any cycle finished (first-ever load vs refresh).
    @Published public private(set) var hasRunOnce = false

    /// Coalescing window between an arrival and the cycle it triggers.
    public var debounce: Duration = .seconds(30)
    /// Cap on conversations summarized per cycle.
    public var maxChatsPerCycle = 3
    public static let maxMessagesPerChat = 120
    public static let maxMentions = 50

    /// Completed summaries (measurement + tests).
    public private(set) var summariesRun = 0

    /// Signed-in identity for mention flagging (set by the app).
    public var ownerMRI: () -> String? = { nil }
    public var ownerDisplayName: () -> String = { "" }
    /// Conversations to read when the digest starts empty (the app
    /// supplies unread/recent threads; demo supplies demo threads).
    public var seed: () -> [(chatID: String, chatName: String, messages: [ChatMessage])] = { [] }

    private struct Thread {
        var name: String
        var messages: [ChatMessage] = []
        var summarizedKey: ThreadSummaryCache.Key?
        var lastSummarizedID: String?
    }

    private var threads: [String: Thread] = [:]
    private var seeded = false
    /// Ordered, newest activity last.
    private var dirty: [String] = []
    private var cycleTask: Task<Void, Never>?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private let transport: any CatchUpTransport
    private let mode: () -> CatchUpMode
    private let conditions: () -> (lowPower: Bool, thermal: ProcessInfo.ThermalState)

    public init(
        transport: any CatchUpTransport,
        mode: @escaping () -> CatchUpMode,
        conditions: (() -> (lowPower: Bool, thermal: ProcessInfo.ThermalState))? = nil,
        observeSystem: Bool = true
    ) {
        self.transport = transport
        self.mode = mode
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

    // MARK: - Input

    /// New or fetched messages for one conversation. No-op when Off.
    public func ingest(chatID: String, chatName: String, messages: [ChatMessage]) {
        guard mode() != .off, !messages.isEmpty else { return }
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
        flagMentions(in: messages, chatID: chatID, chatName: t.name)
        if ThreadSummaryCache.key(chatID: chatID, messages: t.messages) != t.summarizedKey {
            dirty.removeAll { $0 == chatID }
            dirty.append(chatID)
            pending = dirty.count
        }
        if mode() == .alwaysUpToDate { schedule(after: debounce) }
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
            seeded = false
            dirty = []
            entries = []
            mentions = []
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

    /// User-initiated refresh (Catch Up window): runs now, ignoring
    /// the debounce and the power pause (the user asked).
    public func updateNow() {
        guard mode() != .off else { return }
        seedIfNeeded()
        cycleTask?.cancel()
        cycleTask = nil
        Task { await runCycle(userInitiated: true) }
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
        guard cycleTask == nil, !running, !dirty.isEmpty, mode() == .alwaysUpToDate else { return }
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

    /// One cycle: up to `maxChatsPerCycle` changed conversations,
    /// newest activity first. Test seam (internal).
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
        var stop = false
        for chatID in dirty.suffix(maxChatsPerCycle).reversed() {
            guard !stop, !Task.isCancelled, mode() != .off, let t = threads[chatID] else { break }
            let key = ThreadSummaryCache.key(chatID: chatID, messages: t.messages)
            let msgs = t.messages
            let previous: OnDeviceCatchUpEngine.Previous? = {
                guard let after = t.lastSummarizedID, let e = entries.first(where: { $0.chatID == chatID }) else { return nil }
                return .init(text: e.text, afterMessageID: after)
            }()
            working = chatID
            workingName = t.name
            streamingText = nil
            let engine = OnDeviceCatchUpEngine(transport: transport)
            do {
                // Utility, not background: the request's QoS carries into
                // the system inference service, and background QoS starved
                // there under load (measured: 3 summaries took 216 s vs
                // ~7–11 s each at default; 0 of 15 arrivals summarized in
                // 404 s). Utility stays energy-efficient and still yields.
                let text = try await Task.detached(priority: .utility) {
                    try await engine.summarize(messages: msgs, previous: previous) { [weak self] snapshot in
                        Task { @MainActor [weak self] in
                            guard let self, self.working == chatID else { return }
                            if let s = self.streamingText, snapshot.count < s.count { return }
                            self.streamingText = snapshot
                        }
                    }
                }.value
                guard mode() != .off else { break }
                apply(chatID: chatID, name: t.name, text: text, lastActivity: msgs.last?.timestamp ?? "")
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
            if !stop, var cur = threads[chatID] {
                cur.summarizedKey = key
                cur.lastSummarizedID = msgs.last?.id
                threads[chatID] = cur
                if ThreadSummaryCache.key(chatID: chatID, messages: cur.messages) == key {
                    dirty.removeAll { $0 == chatID }
                }
            }
        }
        working = nil
        workingName = nil
        streamingText = nil
        pending = dirty.count
        hasRunOnce = true
        running = false
        if !stop { schedule(after: debounce) }
    }

    /// In-place update (same id, same slot unless its activity moved).
    private func apply(chatID: String, name: String, text: String, lastActivity: String) {
        let entry = Entry(chatID: chatID, chatName: name, text: text, updatedAt: Date(), lastActivity: lastActivity)
        var next = entries
        if let i = next.firstIndex(where: { $0.chatID == chatID }) { next[i] = entry } else { next.append(entry) }
        next.sort { $0.lastActivity > $1.lastActivity }
        entries = next
    }

    private func flagMentions(in messages: [ChatMessage], chatID: String, chatName: String) {
        let found = CatchUpMentions.flag(messages, chatID: chatID, chatName: chatName,
                                         ownerMRI: ownerMRI(), ownerDisplayName: ownerDisplayName())
        guard !found.isEmpty else { return }
        var next = mentions
        for f in found {
            if let i = next.firstIndex(where: { $0.id == f.id }) { next[i] = f } else { next.append(f) }
        }
        next.sort { ($0.timestamp, $0.id) > ($1.timestamp, $1.id) }
        if next.count > Self.maxMentions { next.removeLast(next.count - Self.maxMentions) }
        if next != mentions { mentions = next }
    }
}
