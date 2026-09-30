// ReadSync.swift — CHATSYNC: the owner's read state on the Teams chat
// service, written the way the Teams web client writes it.
//
// Teams keeps one read position per chat and user as conversation
// properties on the chat service (PUT
// `/v1/users/ME/conversations/{id}/properties?name=<name>`, body
// `{"<name>": <value>}`), all three read from the Teams web worker:
//
// - `consumptionhorizon` = "<originalArrivalTime>;<nowMs>;<clientMessageId>"
//   of the newest message the owner has seen (viewing a chat, Mark as read).
// - `consumptionHorizonBookmark` = "<arrival-1>;<nowMs>;<clientMessageId>"
//   of the newest message: Mark as unread. Mark as read clears it with
//   "0;<nowMs>;0".
// - `clearHistoryTime` = newest message time + 1 (ms): Delete chat — the
//   chat and its history leave the owner's list only, until a newer
//   message arrives.
//
// Viewing sends only from an on-screen timeline (`viewed`, gated by
// `shouldMarkViewed`): the chat is open or popped out, its window is
// the active one, and the newest message is in view. Background loads,
// prefetches and previews never reach this store. Ghost mode suppresses
// the view send (not the explicit menu actions, which the owner asked
// for).
//
//   let sync = ReadSync(writer: { chat, name, body in ... })
//   sync.viewed(chatID: id, messages: msgs, gate: gate)
//   try await sync.markUnread(chatID: id, lastMessageMs: ms)
//
// Threading: @MainActor; writes run on BlockingExecutor (blocking transport).
import Foundation

/// Where the timeline stands when it reports the newest message.
public struct ReadViewGate: Sendable, Equatable {
    /// The chat is the main window's open chat or a popped-out chat.
    public var isOpen: Bool
    /// Its window is key and the app is frontmost.
    public var windowActive: Bool
    /// The newest message is inside the viewport.
    public var atLatest: Bool
    /// The first page has landed (nothing half-loaded).
    public var loaded: Bool

    public init(isOpen: Bool, windowActive: Bool, atLatest: Bool, loaded: Bool) {
        self.isOpen = isOpen
        self.windowActive = windowActive
        self.atLatest = atLatest
        self.loaded = loaded
    }
}

@MainActor
public final class ReadSync: ObservableObject {
    /// Writes one conversation property: (chatID, name, JSON body).
    public typealias Writer = @Sendable (String, String, Data) throws -> Void

    /// Newest arrival time (ms) each chat is known read through: our own
    /// sends plus the horizons the chat list carried. A view at or behind
    /// it sends nothing (Teams skips the same way).
    public private(set) var readThrough: [String: Int64] = [:]
    /// Chats whose Teams bookmark says "marked unread" (server seed or
    /// our own Mark as unread): the next read clears the bookmark too.
    public private(set) var bookmarked: Set<String> = []
    /// Property writes sent (Diagnostics).
    @Published public private(set) var writes = 0
    /// Automatic resends after a failed horizon write (Diagnostics, R6).
    @Published public private(set) var retries = 0
    /// Last write failure (Diagnostics; menu actions also throw).
    @Published public private(set) var lastError: String?

    /// Ghost mode: suppresses view-driven horizon sends.
    public var ghost: GhostStore?

    /// R5: highest horizon (arrival ms) per chat that Teams acked, the
    /// highest one queued, and each chat's serial write chain. A horizon
    /// older than either is never sent.
    private var horizonSent: [String: Int64] = [:]
    private var horizonQueued: [String: Int64] = [:]
    private var chains: [String: Task<Void, Never>] = [:]
    /// Identity of each chat's newest chain link: the link that finishes
    /// last drops the chain (an idle chat keeps no task; CHATSYNC2b R6).
    private var chainTokens: [String: UUID] = [:]

    /// One horizon write: the position and how it was reached.
    struct HorizonWrite: Equatable {
        var arrival: Int64
        var clientID: String?
        var clearBookmark: Bool
    }
    /// CHATSYNC2b R6: newest view-driven position per chat not yet acked.
    /// A failed horizon write resends it after `retryDelayNs` (up to
    /// `maxRetries`), so a newer position is never silently lost until
    /// the next view.
    private var desiredView: [String: HorizonWrite] = [:]
    private var retryAttempts: [String: Int] = [:]
    public nonisolated static let maxRetries = 2
    public var retryDelayNs: UInt64 = 3_000_000_000

    /// CHATSYNC2b R5: chats marked unread while open, with the newest
    /// message they were marked at. Like Teams, the open chat is not
    /// marked read again until a newer message arrives or the owner
    /// leaves it (`releaseHolds`).
    public private(set) var holds: [String: Int64] = [:]

    private let writer: Writer
    private let now: @Sendable () -> Int64

    public nonisolated init(writer: Writer? = nil, now: (@Sendable () -> Int64)? = nil) {
        self.writer = writer ?? { chat, name, body in try ReadSync.livePut(chatID: chat, name: name, body: body) }
        self.now = now ?? { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
    }

    // MARK: pure rules

    /// View gate: every condition must hold (never for background loads,
    /// hidden windows, scrolled-up readers or half-loaded pages).
    public nonisolated static func shouldMarkViewed(_ g: ReadViewGate) -> Bool {
        g.isOpen && g.windowActive && g.atLatest && g.loaded
    }

    /// Server arrival time (ms) of a message: the chat service message id
    /// is its arrival time; ids that are not (pending local sends) have
    /// none.
    public nonisolated static func arrivalMs(_ m: ChatMessage) -> Int64? {
        let id = m.id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.allSatisfy(\.isNumber), let v = Int64(id), v > 0 else { return nil }
        return v
    }

    /// Newest message that has reached the server.
    public nonisolated static func latest(_ messages: [ChatMessage]) -> ChatMessage? {
        messages.max { (arrivalMs($0) ?? .min) < (arrivalMs($1) ?? .min) }
            .flatMap { arrivalMs($0) == nil ? nil : $0 }
    }

    public nonisolated static func horizonValue(arrivalMs: Int64, nowMs: Int64, clientMessageID: String?) -> String {
        "\(arrivalMs);\(nowMs);\(clientID(clientMessageID))"
    }

    public nonisolated static func bookmarkValue(arrivalMs: Int64, nowMs: Int64, clientMessageID: String?) -> String {
        "\(max(0, arrivalMs - 1));\(nowMs);\(clientID(clientMessageID))"
    }

    public nonisolated static func clearedBookmark(nowMs: Int64) -> String { "0;\(nowMs);0" }

    nonisolated static func clientID(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "0" : t
    }

    nonisolated static func body(_ name: String, _ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: [name: value], options: [.sortedKeys])) ?? Data()
    }

    // MARK: server state in

    /// Adopt what a fetched chat list says: horizons (read-through) and
    /// Teams "marked unread" bookmarks.
    public func adopt(horizons: [String: String], markedUnread: Set<String>, listed: Set<String>) {
        for (id, raw) in horizons {
            guard let h = ChatListSeed.horizon(raw), h.readMs > 0 else { continue }
            readThrough[id] = max(readThrough[id] ?? 0, h.readMs)
        }
        bookmarked.subtract(listed.subtracting(markedUnread))
        bookmarked.formUnion(markedUnread)
    }

    // MARK: writes

    /// The on-screen timeline shows the newest message: move the Teams
    /// read position there (once per new newest message).
    @discardableResult
    public func viewed(chatID: String, messages: [ChatMessage], gate: ReadViewGate) -> Task<Void, Never>? {
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chat.isEmpty, Self.shouldMarkViewed(gate),
              let last = Self.latest(messages), let at = Self.arrivalMs(last) else { return nil }
        if let hold = holds[chat] {
            guard at > hold else { return nil }
            holds[chat] = nil
        }
        let clearBookmark = bookmarked.contains(chat)
        guard clearBookmark || at > (readThrough[chat] ?? 0) else { return nil }
        if let ghost, ghost.shouldSuppressReceipts {
            ghost.noteSuppressedReceipt()
            return nil
        }
        return send(chat, arrival: at, clientID: last.clientMessageID, clearBookmark: clearBookmark)
    }

    /// Mark as read from the menu (no message list at hand): the row's
    /// newest message time.
    public func markRead(chatID: String, lastMessageMs: Int64?) async throws {
        let at = lastMessageMs ?? now()
        try await sendThrowing(chatID, arrival: at, clientID: nil, clearBookmark: true)
    }

    /// Mark as unread: the Teams bookmark just behind the newest message.
    /// `holdWhileOpen`: the chat is on screen; keep it unread there (R5).
    public func markUnread(chatID: String, lastMessageMs: Int64?, clientMessageID: String? = nil,
                           holdWhileOpen: Bool = false) async throws {
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chat.isEmpty else { return }
        let at = lastMessageMs ?? now()
        let value = Self.bookmarkValue(arrivalMs: at, nowMs: now(), clientMessageID: clientMessageID)
        // Held before the write: a view reported while it is in flight
        // must not undo it.
        let heldBefore = holds[chat]
        if holdWhileOpen { holds[chat] = max(heldBefore ?? 0, at) }
        // The owner's newer intent: a pending resend of an older view
        // (which would clear this bookmark) is dropped.
        desiredView[chat] = nil
        retryAttempts[chat] = nil
        do {
            try await write(chat, [("consumptionHorizonBookmark", Self.body("consumptionHorizonBookmark", value))])
        } catch {
            if holdWhileOpen { holds[chat] = heldBefore }
            throw error
        }
        bookmarked.insert(chat)
        if !holdWhileOpen { holds[chat] = nil }
    }

    /// The owner left these chats (none of `openIDs` any more): views of
    /// them move the read position again.
    public func releaseHolds(keeping openIDs: Set<String>) {
        for id in holds.keys where !openIDs.contains(id) { holds[id] = nil }
    }

    /// Delete chat (for the owner only), as Teams does: history cleared
    /// through the newest message.
    public func deleteChat(chatID: String, lastMessageMs: Int64?) async throws {
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chat.isEmpty else { return }
        let at = lastMessageMs.map { $0 + 1 } ?? now()
        try await write(chat, [("clearHistoryTime", Self.body("clearHistoryTime", at))])
    }

    private func pairs(arrival: Int64, clientID: String?, clearBookmark: Bool) -> [(String, Data)] {
        let t = now()
        var out = [("consumptionhorizon", Self.body("consumptionhorizon",
            Self.horizonValue(arrivalMs: arrival, nowMs: t, clientMessageID: clientID)))]
        if clearBookmark {
            out.append(("consumptionHorizonBookmark", Self.body("consumptionHorizonBookmark", Self.clearedBookmark(nowMs: t))))
        }
        return out
    }

    private func send(_ chat: String, arrival: Int64, clientID: String?, clearBookmark: Bool) -> Task<Void, Never> {
        // Claimed before the write: a second report while it is in
        // flight sends nothing. A failure releases the claim (and the
        // newest view position is resent, R6).
        let before = readThrough[chat]
        readThrough[chat] = max(before ?? 0, arrival)
        let wasBookmarked = bookmarked.remove(chat) != nil
        let hw = HorizonWrite(arrival: arrival, clientID: clientID, clearBookmark: clearBookmark)
        if arrival >= (desiredView[chat]?.arrival ?? 0) {
            // A newer position gets its own retry budget.
            if desiredView[chat] != hw { retryAttempts[chat] = nil }
            desiredView[chat] = hw
        }
        let list = pairs(arrival: arrival, clientID: clientID, clearBookmark: clearBookmark)
        return Task {
            do {
                try await self.write(chat, list, horizon: arrival)
            } catch {
                // A resend (R6) that already landed keeps its claim.
                guard (self.horizonSent[chat] ?? 0) < arrival else { return }
                if self.readThrough[chat] == arrival { self.readThrough[chat] = before }
                if wasBookmarked { self.bookmarked.insert(chat) }
            }
        }
    }

    private func sendThrowing(_ chat: String, arrival: Int64, clientID: String?, clearBookmark: Bool) async throws {
        let c = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        try await write(c, pairs(arrival: arrival, clientID: clientID, clearBookmark: clearBookmark), horizon: arrival)
        readThrough[c] = max(readThrough[c] ?? 0, arrival)
        bookmarked.remove(c)
        holds[c] = nil
    }

    /// One serial chain per chat. A horizon write (`horizon` = its arrival
    /// ms) is dropped when Teams already has, or a newer one is queued
    /// behind, a later position: positions only move forward.
    private func write(_ chat: String, _ list: [(String, Data)], horizon: Int64? = nil) async throws {
        if let h = horizon { horizonQueued[chat] = max(horizonQueued[chat] ?? 0, h) }
        let prev = chains[chat]
        let job = Task<Result<Void, Error>, Never> { [self] in
            await prev?.value
            return await perform(chat, list, horizon: horizon)
        }
        let token = UUID()
        chainTokens[chat] = token
        chains[chat] = Task { [self] in
            _ = await job.value
            // R6: the newest link, finished: the chat's chain is idle.
            if chainTokens[chat] == token {
                chains[chat] = nil
                chainTokens[chat] = nil
            }
        }
        try await job.value.get()
    }

    private func perform(_ chat: String, _ list: [(String, Data)], horizon: Int64?) async -> Result<Void, Error> {
        let w = writer
        do {
            for (name, body) in list {
                if name == "consumptionhorizon", let h = horizon,
                   h < (horizonSent[chat] ?? 0) || h < (horizonQueued[chat] ?? 0) { continue }
                try await Task.blocking { try w(chat, name, body) }.value
                writes += 1
                if name == "consumptionhorizon", let h = horizon {
                    horizonSent[chat] = max(horizonSent[chat] ?? 0, h)
                    if let d = desiredView[chat], d.arrival <= h {
                        desiredView[chat] = nil
                        retryAttempts[chat] = nil
                    }
                }
            }
            lastError = nil
            return .success(())
        } catch {
            if let h = horizon, horizonQueued[chat] == h { horizonQueued[chat] = horizonSent[chat] ?? 0 }
            lastError = "read state: \(error)"
            if horizon != nil { scheduleRetry(chat) }
            return .failure(error)
        }
    }

    /// R6: after a failed horizon write, resend the newest view position
    /// Teams has not acked, unless a write at or past it is queued (that
    /// one carries it). Bounded by `maxRetries` per position.
    private func scheduleRetry(_ chat: String) {
        guard let d = desiredView[chat], d.arrival > (horizonSent[chat] ?? 0) else { return }
        let attempt = (retryAttempts[chat] ?? 0) + 1
        guard attempt <= Self.maxRetries else {
            desiredView[chat] = nil
            retryAttempts[chat] = nil
            return
        }
        retryAttempts[chat] = attempt
        let delay = retryDelayNs
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            await self?.retry(chat, d)
        }
    }

    private func retry(_ chat: String, _ d: HorizonWrite) async {
        guard desiredView[chat] == d, d.arrival > (horizonSent[chat] ?? 0),
              (horizonQueued[chat] ?? 0) < d.arrival, holds[chat] == nil else { return }
        retries += 1
        do {
            try await write(chat, pairs(arrival: d.arrival, clientID: d.clientID, clearBookmark: d.clearBookmark),
                            horizon: d.arrival)
            readThrough[chat] = max(readThrough[chat] ?? 0, d.arrival)
            if d.clearBookmark { bookmarked.remove(chat) }
        } catch {
            // perform() scheduled the next attempt (or gave up).
        }
    }

    /// Test/Diagnostics: chats with a write chain still alive.
    var activeChains: Int { chains.count }

    // MARK: live transport

    /// PUT one conversation property on the chat service (skype token).
    nonisolated static func livePut(chatID: String, name: String, body: Data) throws {
        let ctx = try CoreReads.production()
        let (skype, slots) = try CoreReads.skypeToken(
            profile: CoreLocal.activeProfileID(), code: "read_state", ctx: ctx)
        guard let url = URL(string: propertyURL(base: CoreReads.chatServiceURL(slots), chatID: chatID, name: name)) else {
            throw CoreCallError.failed("read_state: bad chat id")
        }
        let resp = try URLSessionCalendarHTTP().send(
            "PUT", url: url,
            headers: ["Authentication": "skypetoken=\(skype)", "Content-Type": "application/json"],
            body: body)
        guard (200..<300).contains(resp.status) else {
            throw CoreCallError.failed("read_state: \(name) HTTP \(resp.status)")
        }
    }

    /// Chat service property URL (id path-escaped like the web client's
    /// `encodeURIComponent`-free path; ids carry only `:`, `@`, `.`, `_`).
    public nonisolated static func propertyURL(base: String, chatID: String, name: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        return "\(b)/v1/users/ME/conversations/\(chatID.trimmingCharacters(in: .whitespaces))/properties?name=\(name)"
    }
}
