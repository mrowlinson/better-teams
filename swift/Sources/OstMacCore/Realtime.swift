// Realtime.swift — live Trouter event feed for the conversation view.
//
// RealtimeFeed polls the typed poll endpoint, dedupes by message id,
// reconnects with backoff, and dispatches to subscribers:
//
//   let feed = RealtimeFeed()
//   feed.subscribe { msg in view.apply(msg) }   // typed message/edit
//   feed.onResync { view.refetchVisibleChats() } // message_loss gap
//   feed.start()
//
// message_loss behavior: the server emits trouter.message_loss when it drops
// queued indicators (backpressure, reconnect gap, stale etag). The Rust core
// surfaces this as RealtimePoll.resync; the feed forwards it to resync
// handlers. The socket itself is healthy, so the feed does NOT reconnect on
// resync — the UI re-fetches visible conversations via the chat API instead.
// Resync may repeat with identical etags; that is server steady-state.
//
// Threading: polling runs on a private queue; subscriber/resync handlers are
// invoked on that queue — hop to MainActor in UI code. All state is locked.
import Foundation

/// One chat message (or edit) from the live feed. Decodes the Rust core's
/// typed poll envelope; field names are the core's JSON keys.
public struct RealtimeMessage: Decodable, Sendable, Identifiable {
    public var id: String { msgId }
    public let chatID: String
    public let msgId: String
    public let sender: String
    /// Raw sender MRI (`8:orgid:…`) when the event carried one; nil on
    /// old core builds and non-MRI senders. Presence resolves it for
    /// live chatmate dots.
    public let senderID: String?
    public let text: String
    public let time: String
    public let isEdit: Bool
    public let editedID: String?
    /// Unstripped server HTML (om-richmedia: streaming `<img>` mining).
    /// Nil on old core builds — treat as text-only.
    public let raw: String?
    /// Grouped reaction counts (om-reactions). Nil on old core builds
    /// and on events without counts — leave the bubble's counts alone.
    public let reactions: [ReactionCount]?
    /// Raw `messagetype` (e.g. `Text`, `RichText/Html`). Nil on old core
    /// builds — the rules filter treats that as unclassifiable (the type
    /// gate passes) rather than skipping.
    public let messageType: String?
    /// Owning account profile id (gap-g1: the feed's profile concept).
    /// Stamped host-side by the producer (live feed = active account,
    /// background poller = the polled account). Nil = active account
    /// (back-compat: old payloads and live events omit it). Never
    /// trusted from the wire alone — the poller stamps what it polled.
    public let accountID: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case msgId = "id"
        case sender, senderID = "sender_id", text, time
        case isEdit = "is_edit"
        case editedID = "edited_id"
        case raw, reactions
        case messageType = "message_type"
        case accountID = "account_id"
    }

    /// Host-side construction (tests, mock feeds). `senderID`/`raw`/
    /// `reactions`/`messageType`/`accountID` default to nil (old core builds
    /// omit them); wire decoding untouched.
    public init(
        chatID: String, msgId: String, sender: String,
        senderID: String? = nil, text: String, time: String,
        isEdit: Bool, editedID: String? = nil, raw: String? = nil,
        reactions: [ReactionCount]? = nil,
        messageType: String? = nil,
        accountID: String? = nil
    ) {
        self.chatID = chatID
        self.msgId = msgId
        self.sender = sender
        self.senderID = senderID
        self.text = text
        self.time = time
        self.isEdit = isEdit
        self.editedID = editedID
        self.raw = raw
        self.reactions = reactions
        self.messageType = messageType
        self.accountID = accountID
    }

    /// Copy stamped with the owning account (producers tag what they
    /// polled; nil clears back to active-account).
    public func stamped(accountID: String?) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: msgId, sender: sender,
            senderID: senderID, text: text, time: time,
            isEdit: isEdit, editedID: editedID, raw: raw,
            reactions: reactions, messageType: messageType,
            accountID: accountID)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try c.decode(String.self, forKey: .chatID)
        msgId = try c.decode(String.self, forKey: .msgId)
        sender = try c.decode(String.self, forKey: .sender)
        senderID = try c.decodeIfPresent(String.self, forKey: .senderID)
        text = try c.decode(String.self, forKey: .text)
        time = try c.decode(String.self, forKey: .time)
        isEdit = try c.decode(Bool.self, forKey: .isEdit)
        editedID = try c.decodeIfPresent(String.self, forKey: .editedID)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        reactions = try c.decodeIfPresent([ReactionCount].self, forKey: .reactions)
        messageType = try c.decodeIfPresent(String.self, forKey: .messageType)
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
    }

    /// True when this event belongs to the given open chat.
    /// Nil (nothing open) never matches.
    public func isFor(chatID id: String?) -> Bool {
        id.map { $0 == chatID } ?? false
    }

    /// Host model: edits collapse onto the edited id so
    /// `ConversationStore.ingest` updates the bubble in place.
    /// `raw` rides along so streaming image bubbles render (same key as
    /// history, so the cache never refetches on resync). `reactions`
    /// ride along too (empty when the event carried none).
    public var asChatMessage: ChatMessage {
        let r = reactions ?? []
        if isEdit, let edited = editedID {
            return ChatMessage(id: edited, sender: sender, timestamp: time, content: text, raw: raw, reactions: r)
        }
        return ChatMessage(id: msgId, sender: sender, timestamp: time, content: text, raw: raw, reactions: r)
    }
}

/// One typing indicator from the live feed (om-typing). Decodes the Rust
/// core's typed poll envelope (`Control/Typing` frames, never bubbles).
public struct TypingEvent: Decodable, Sendable, Equatable {
    public let chatID: String
    public let sender: String
    /// Raw sender MRI (`8:orgid:…`) when the event carried one; nil on
    /// old core builds and non-MRI senders.
    public let senderID: String?
    public let time: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case sender, senderID = "sender_id", time
    }

    /// Host-side construction (tests, mock feeds).
    public init(chatID: String, sender: String, senderID: String? = nil, time: String = "") {
        self.chatID = chatID
        self.sender = sender
        self.senderID = senderID
        self.time = time
    }

    /// True when this event belongs to the given open chat.
    /// Nil (nothing open) never matches.
    public func isFor(chatID id: String?) -> Bool {
        id.map { $0 == chatID } ?? false
    }
}

/// Typed poll envelope from ostmac_trouter_poll_typed.
/// `calls` is nil on old core builds (pre om-signal) — treat as no events.
/// `typing` is nil on old core builds (pre om-typing) — same rule.
/// `roster` is nil on old core builds (pre om-meet-chat) — same rule.
public struct RealtimePoll: Decodable, Sendable {
    public let ok: Bool
    public let messages: [RealtimeMessage]
    public let resync: Bool
    public let skipped: Int
    public let calls: [CallEvent]?
    public let typing: [TypingEvent]?
    public let roster: [MeetingRosterEvent]?

    public init(ok: Bool, messages: [RealtimeMessage], resync: Bool, skipped: Int, calls: [CallEvent]? = nil, typing: [TypingEvent]? = nil, roster: [MeetingRosterEvent]? = nil) {
        self.ok = ok
        self.messages = messages
        self.resync = resync
        self.skipped = skipped
        self.calls = calls
        self.typing = typing
        self.roster = roster
    }
}

/// Pure reconnect backoff: 1,2,4,8,16,30,30,… seconds. Deterministic
/// (no jitter) so retries are testable and log-readable.
public enum RealtimeBackoff {
    public static let cap: Double = 30

    public static func delay(forAttempt attempt: Int) -> Double {
        guard attempt > 0 else { return 1 }
        return min(cap, pow(2.0, Double(min(attempt, 10) - 1)))
    }

    /// Map a trouter_start return code to feed action.
    /// 0/-1 = live (started / already running); anything else = retry.
    public static func shouldRetry(startCode rc: Int32) -> Bool {
        rc != 0 && rc != -1
    }
}

public final class RealtimeFeed: @unchecked Sendable {
    public enum State: Sendable, Equatable { case stopped, live, retryWait }

    /// Max seen ids kept for dedupe; oldest evicted first.
    public static let dedupeCap = 2048

    private let lock = NSLock()
    private var state: State = .stopped
    private var generation = 0 // invalidates timers/retries on stop
    private var timer: DispatchSourceTimer?
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var subs: [UUID: @Sendable (RealtimeMessage) -> Void] = [:]
    private var resyncSubs: [UUID: @Sendable () -> Void] = [:]
    private var callSubs: [UUID: @Sendable (CallEvent) -> Void] = [:]
    private var typingSubs: [UUID: @Sendable (TypingEvent) -> Void] = [:]
    private var rosterSubs: [UUID: @Sendable (MeetingRosterEvent) -> Void] = [:]
    private var attempt = 0
    private var pollCountValue = 0
    private var lastErrorValue: String?

    private let pollFn: @Sendable () throws -> RealtimePoll
    private let pollWaitFn: @Sendable (UInt64) throws -> RealtimePoll
    private let startFn: @Sendable () -> Int32
    private let stopFn: @Sendable () -> Int32
    private let queue: DispatchQueue
    public var pollInterval: TimeInterval = 1.0
    /// Blocking-wait timeout per wait iteration. The live loop sleeps in
    /// the core instead of waking on `pollInterval`; the 1s timer stays as
    /// the fallback when a wait throws.
    public var pollWaitTimeoutMs: UInt64 = 25_000

    public init(
        poll: @escaping @Sendable () throws -> RealtimePoll = { try RustCore.trouterPollTyped() },
        pollWait: @escaping @Sendable (UInt64) throws -> RealtimePoll = { try RustCore.trouterPollTypedWait(timeoutMs: $0) },
        start: @escaping @Sendable () -> Int32 = { RustCore.trouterStart() },
        stop: @escaping @Sendable () -> Int32 = { RustCore.trouterStop() }
    ) {
        self.pollFn = poll
        self.pollWaitFn = pollWait
        self.startFn = start
        self.stopFn = stop
        self.queue = DispatchQueue(label: "RealtimeFeed", qos: .utility)
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// Completed typed polls since init (includes the start drain).
    /// The UI reads this to prove the poll loop is alive.
    public var pollCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pollCountValue
    }

    /// Last poll failure, cleared on the next success. Nil when healthy.
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastErrorValue
    }

    /// Subscribe to typed message/edit events. Returns a token for unsubscribe.
    @discardableResult
    public func subscribe(_ h: @escaping @Sendable (RealtimeMessage) -> Void) -> UUID {
        let t = UUID()
        lock.lock(); subs[t] = h; lock.unlock()
        return t
    }

    public func unsubscribe(_ t: UUID) {
        lock.lock(); subs.removeValue(forKey: t); lock.unlock()
    }

    /// Subscribe to resync signals (message_loss gap — re-fetch chats).
    @discardableResult
    public func onResync(_ h: @escaping @Sendable () -> Void) -> UUID {
        let t = UUID()
        lock.lock(); resyncSubs[t] = h; lock.unlock()
        return t
    }

    /// Subscribe to call events (incoming invitation / remote end).
    /// The core already recorded them in the call slot; the handler
    /// just refreshes UI state.
    @discardableResult
    public func onCall(_ h: @escaping @Sendable (CallEvent) -> Void) -> UUID {
        let t = UUID()
        lock.lock(); callSubs[t] = h; lock.unlock()
        return t
    }

    /// Subscribe to typing indicators. Every event refreshes that
    /// sender's per-thread timeout (no dedupe — repeats are the
    /// keepalive); the TypingStore owns expiry.
    @discardableResult
    public func onTyping(_ h: @escaping @Sendable (TypingEvent) -> Void) -> UUID {
        let t = UUID()
        lock.lock(); typingSubs[t] = h; lock.unlock()
        return t
    }

    /// Subscribe to meeting-roster snapshots. Every event upserts one
    /// row in place (no dedupe — repeats are state refreshes); the
    /// MeetingRosterStore owns the rows. Never touches the chat list.
    @discardableResult
    public func onRoster(_ h: @escaping @Sendable (MeetingRosterEvent) -> Void) -> UUID {
        let t = UUID()
        lock.lock(); rosterSubs[t] = h; lock.unlock()
        return t
    }

    public func start() {
        lock.lock()
        guard state == .stopped else { lock.unlock(); return }
        generation += 1
        let gen = generation
        attempt = 0
        lock.unlock()
        attemptStart(gen: gen)
    }

    public func stop() {
        lock.lock()
        generation += 1
        state = .stopped
        timer?.cancel(); timer = nil
        lock.unlock()
        _ = stopFn()
    }

    /// One start attempt; on failure schedules a backoff retry.
    private func attemptStart(gen: Int) {
        let rc = startFn()
        lock.lock()
        guard gen == generation else { lock.unlock(); return } // stopped meanwhile
        if !RealtimeBackoff.shouldRetry(startCode: rc) {
            state = .live
            attempt = 0
            lock.unlock()
            // Drain stale backlog without notifying, then go live on the
            // blocking-wait loop (1s timer stays as the wait-failure fallback).
            _ = try? pollDeduped(notify: false)
            scheduleWait(gen: gen)
            return
        }
        state = .retryWait
        attempt += 1
        let wait = RealtimeBackoff.delay(forAttempt: attempt)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.attemptStart(gen: gen)
        }
    }

    private func scheduleTimer(gen: Int) {
        lock.lock()
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick(gen: gen) }
        timer = t
        lock.unlock()
        t.resume()
    }

    private func tick(gen: Int) {
        lock.lock()
        guard gen == generation, state == .live else { lock.unlock(); return }
        lock.unlock()
        _ = try? pollOnce()
    }

    /// One blocking-wait iteration: sleeps in the core until an event or
    /// the timeout, dispatches, then chains the next wait. A wait failure
    /// arms the 1s timer fallback (stays on the timer until restart).
    /// `stop()` does not interrupt a blocked wait; the chain exits when
    /// the wait returns (at most `pollWaitTimeoutMs` later).
    private func scheduleWait(gen: Int) {
        lock.lock()
        timer?.cancel(); timer = nil
        lock.unlock()
        queue.async { [weak self] in self?.waitTick(gen: gen) }
    }

    private func waitTick(gen: Int) {
        lock.lock()
        guard gen == generation, state == .live else { lock.unlock(); return }
        lock.unlock()
        do {
            let p = try pollWaitFn(pollWaitTimeoutMs)
            lock.lock()
            guard gen == generation, state == .live else { lock.unlock(); return }
            lastErrorValue = nil
            lock.unlock()
            _ = dispatch(p, notify: true)
            queue.async { [weak self] in self?.waitTick(gen: gen) }
        } catch {
            lock.lock()
            let alive = (gen == generation && state == .live)
            if alive { lastErrorValue = String(describing: error) }
            lock.unlock()
            if alive { scheduleTimer(gen: gen) }
        }
    }

    /// Single poll: dedupe + dispatch. Returns (new messages, resync).
    /// Public so the UI (and tests) can drive polling manually.
    @discardableResult
    public func pollOnce() throws -> (messages: Int, resync: Bool) {
        do {
            let r = try pollDeduped(notify: true)
            lock.lock(); lastErrorValue = nil; lock.unlock()
            return r
        } catch {
            lock.lock(); lastErrorValue = String(describing: error); lock.unlock()
            throw error
        }
    }

    /// Single blocking wait: sleeps up to `timeoutMs` (nil = the feed's
    /// `pollWaitTimeoutMs`), then dedupes + dispatches like `pollOnce`.
    @discardableResult
    public func pollWaitOnce(timeoutMs: UInt64? = nil) throws -> (messages: Int, resync: Bool) {
        do {
            let r = dispatch(try pollWaitFn(timeoutMs ?? pollWaitTimeoutMs), notify: true)
            lock.lock(); lastErrorValue = nil; lock.unlock()
            return r
        } catch {
            lock.lock(); lastErrorValue = String(describing: error); lock.unlock()
            throw error
        }
    }

    private func pollDeduped(notify: Bool) throws -> (messages: Int, resync: Bool) {
        dispatch(try pollFn(), notify: notify)
    }

    private func dispatch(_ p: RealtimePoll, notify: Bool) -> (messages: Int, resync: Bool) {
        lock.lock(); pollCountValue += 1; lock.unlock()
        var fresh: [RealtimeMessage] = []
        lock.lock()
        for m in p.messages where !seen.contains(m.msgId) {
            seen.insert(m.msgId)
            seenOrder.append(m.msgId)
            if seenOrder.count > Self.dedupeCap {
                seen.remove(seenOrder.removeFirst())
            }
            fresh.append(m)
        }
        let msgHandlers = Array(subs.values)
        let rsHandlers = p.resync ? Array(resyncSubs.values) : []
        let callHandlers = Array(callSubs.values)
        let callEvents = p.calls ?? []
        let typingHandlers = Array(typingSubs.values)
        let typingEvents = p.typing ?? []
        let rosterHandlers = Array(rosterSubs.values)
        let rosterEvents = p.roster ?? []
        lock.unlock()
        if notify {
            for m in fresh { for h in msgHandlers { h(m) } }
            for h in rsHandlers { h() }
            for e in callEvents { for h in callHandlers { h(e) } }
            for e in typingEvents { for h in typingHandlers { h(e) } }
            for e in rosterEvents { for h in rosterHandlers { h(e) } }
        }
        return (fresh.count, p.resync)
    }
}
