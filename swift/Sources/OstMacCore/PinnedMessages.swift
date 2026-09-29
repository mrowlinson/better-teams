// PinnedMessages.swift — om-pinmessages lane: pinned messages per thread.
//
// Owner pins reminders about people in 1:1s (works for every thread
// type: 1:1, group, channel — the key is the opaque thread id).
// Pin/Unpin ride the bubble's top-level context menu; the pinned strip
// sits pinned to the top of the timeline (tap jumps to the bubble).
//
// Persistence: UserDefaults (suite-injectable for tests), one JSON key
// holding [threadID: [PinnedMessage]]. Pins survive restart and new
// messages; the store never touches the chat list (no refresh ever).
//
// Server pins (OstMac §84): until §84 this store was LOCAL-ONLY — no
// core call read Teams' own pins, so pins made in Teams never showed.
// Now opening a real chat reads its server pins off-main
// (`RustCore.chatPinnedMessages`: chat-service thread properties first
// — shape undocumented, parsed tolerantly — Graph `pinnedMessages`
// fallback, which 403s without Chat.Read) and merges them in
// (`PinnedMessages.mergeServer`): local pins stay, server pins are
// marked `fromServer`, and the map is only republished when the merge
// changes it (no flash). Unpinning a server pin records its id as
// dismissed (a refetch never re-adds it) and, for Graph-sourced pins
// (`graphPinID`), sends Graph DELETE through the injectable
// `PinnedServerTransport`. Pinning from this app stays local (no
// chat-service pin write is known). Demo mode has no transport.
import Foundation
import Combine

/// One pinned message: the composite key (thread + message id) plus a
/// snapshot so the strip still renders when the bubble aged out of the
/// loaded window. Live content wins when the bubble is in `messages`.
public struct PinnedMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String { messageID }
    public let messageID: String
    public let sender: String
    public let preview: String
    public let timestamp: String
    /// Pin moment (seconds since epoch) — strip order key.
    public let pinnedAt: Double
    /// True for pins read from Teams (§84). Optional so pre-§84 stored
    /// pins decode (absent = local).
    public let fromServer: Bool?
    /// Graph `pinnedChatMessageInfo` id (Graph-sourced pins only): the
    /// id Graph DELETE takes on unpin.
    public let graphPinID: String?

    public var isServer: Bool { fromServer == true }

    public init(
        messageID: String, sender: String, preview: String,
        timestamp: String, pinnedAt: Double,
        fromServer: Bool? = nil, graphPinID: String? = nil
    ) {
        self.messageID = messageID
        self.sender = sender
        self.preview = preview
        self.timestamp = timestamp
        self.pinnedAt = pinnedAt
        self.fromServer = fromServer
        self.graphPinID = graphPinID
    }

    /// Snapshot one bubble at pin time.
    public static func from(message: ChatMessage, at: Date = Date()) -> PinnedMessage {
        PinnedMessage(
            messageID: message.id, sender: message.sender,
            preview: PinnedMessages.preview(for: message),
            timestamp: message.timestamp,
            pinnedAt: at.timeIntervalSince1970)
    }
}

/// Pure pinned-strip helpers (store, strip view, and tests share them).
public enum PinnedMessages {
    public nonisolated static let defaultsKey = "om.pinnedMessages.v1"
    /// Per-account key (d1-accounts): default keeps the legacy key.
    public static func key(for accountID: String) -> String {
        AccountProfile.key(defaultsKey, for: accountID)
    }
    /// Strip preview width: one collapsed line, 80 chars + ellipsis.
    public static let previewMax = 80

    /// One-line strip preview: exactly what the bubble shows
    /// (shortcodes expanded, same source as Copy), collapsed to one
    /// line. Empty bubbles read "(no text)" (forward-preview parity).
    /// Nonisolated pure (same collapse as ConversationStore.quotePreview,
    /// inlined: that helper is MainActor-isolated).
    public static func preview(for message: ChatMessage, max: Int = previewMax) -> String {
        let text = MessageActions.copyText(for: message)
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let flat: String
        if oneLine.count > max {
            let end = oneLine.index(oneLine.startIndex, offsetBy: max)
            flat = "\(oneLine[..<end])…"
        } else {
            flat = oneLine
        }
        return flat.isEmpty ? "(no text)" : flat
    }

    /// Top-level context-menu label for the pin toggle.
    public static func menuTitle(isPinned: Bool) -> String {
        isPinned ? "Unpin" : "Pin"
    }

    /// One strip row: live bubble content when available (edits track),
    /// else the pin-time snapshot. `isAvailable` gates the jump tap.
    public struct StripRow: Sendable, Equatable, Identifiable {
        public var id: String { messageID }
        public let messageID: String
        public let sender: String
        public let preview: String
        public let timestamp: String
        public let pinnedAt: Double
        public let isAvailable: Bool

        public init(
            messageID: String, sender: String, preview: String,
            timestamp: String, pinnedAt: Double, isAvailable: Bool
        ) {
            self.messageID = messageID
            self.sender = sender
            self.preview = preview
            self.timestamp = timestamp
            self.pinnedAt = pinnedAt
            self.isAvailable = isAvailable
        }
    }

    /// Strip rows for one thread: pins in pin-time order, each resolved
    /// against the loaded window (live wins, snapshot falls back).
    public static func rows(
        pins: [PinnedMessage], messages: [ChatMessage]
    ) -> [StripRow] {
        rows(pins: pins, messages: messages, index: MessageIndex(messages))
    }

    /// Indexed strip rows (om-s6-renderparse): same rows, O(pins)
    /// against a body-eval `MessageIndex` (no per-pin scan).
    public static func rows(
        pins: [PinnedMessage], messages: [ChatMessage], index: MessageIndex
    ) -> [StripRow] {
        pins.sorted { $0.pinnedAt < $1.pinnedAt }.map { pin in
            if let live = index.byID[pin.messageID] {
                return StripRow(
                    messageID: pin.messageID, sender: live.sender,
                    preview: preview(for: live), timestamp: live.timestamp,
                    pinnedAt: pin.pinnedAt, isAvailable: true)
            }
            return StripRow(
                messageID: pin.messageID, sender: pin.sender,
                preview: pin.preview.isEmpty ? "(no text)" : pin.preview,
                timestamp: pin.timestamp,
                pinnedAt: pin.pinnedAt, isAvailable: false)
        }
    }

    /// Jump target for a strip tap: the pin id when the bubble is in
    /// the loaded window, else nil (caller stays put — never conjures
    /// a bubble). Blank ids never target.
    public static func jumpTarget(pinID: String, messages: [ChatMessage]) -> String? {
        let id = pinID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return messages.contains(where: { $0.id == id }) ? id : nil
    }

    /// Best-effort decode: corrupt payloads yield empty (never throw).
    public static func decode(_ data: Data?) -> [String: [PinnedMessage]] {
        guard let data,
              let raw = try? JSONDecoder().decode([String: [PinnedMessage]].self, from: data)
        else { return [:] }
        return sanitize(raw)
    }

    public static func encode(_ map: [String: [PinnedMessage]]) -> Data? {
        try? JSONEncoder().encode(sanitize(map))
    }

    /// Drop blank thread/message ids, dedupe by message id (earliest
    /// pin wins), sort by pin time. Empty threads are absent.
    public static func sanitize(_ map: [String: [PinnedMessage]]) -> [String: [PinnedMessage]] {
        var out: [String: [PinnedMessage]] = [:]
        for (thread, pins) in map {
            let t = thread.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            var seen = Set<String>()
            var kept: [PinnedMessage] = []
            for pin in pins.sorted(by: { $0.pinnedAt < $1.pinnedAt }) {
                let mid = pin.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !mid.isEmpty, seen.insert(mid).inserted else { continue }
                kept.append(pin)
            }
            if !kept.isEmpty { out[t] = kept }
        }
        return out
    }
}

/// `ostmac_chat_pinned_messages` envelope (§84).
public struct ServerPinsResponse: Decodable, Sendable {
    public let ok: Bool
    public let source: String?
    public let pins: [ServerPin]
}

/// One server pin as the core reports it.
public struct ServerPin: Decodable, Sendable, Equatable {
    public let messageID: String
    public let sender: String?
    public let preview: String?
    public let time: String?
    public let pinnedBy: String?
    public let pinnedAt: String?
    public let graphPinID: String?

    public init(
        messageID: String, sender: String? = nil, preview: String? = nil,
        time: String? = nil, pinnedBy: String? = nil, pinnedAt: String? = nil,
        graphPinID: String? = nil
    ) {
        self.messageID = messageID
        self.sender = sender
        self.preview = preview
        self.time = time
        self.pinnedBy = pinnedBy
        self.pinnedAt = pinnedAt
        self.graphPinID = graphPinID
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case sender, preview, time
        case pinnedBy = "pinned_by"
        case pinnedAt = "pinned_at"
        case graphPinID = "graph_pin_id"
    }
}

/// `ostmac_chat_unpin_message` envelope.
public struct ServerUnpinResponse: Decodable, Sendable {
    public let ok: Bool
}

/// Server pin I/O (§84). Blocking calls: the store runs them off-main.
/// Tests inject fakes; the app injects `LivePinnedServer` (real mode).
public protocol PinnedServerTransport: Sendable {
    func fetchPins(chatID: String) throws -> [PinnedMessage]
    func unpin(chatID: String, pinID: String) throws
}

/// Core-backed transport (chat-service read, Graph fallback/DELETE).
public struct LivePinnedServer: PinnedServerTransport {
    public init() {}
    public func fetchPins(chatID: String) throws -> [PinnedMessage] {
        PinnedMessages.fromServer(try RustCore.chatPinnedMessages(chatID: chatID).pins)
    }
    public func unpin(chatID: String, pinID: String) throws {
        try RustCore.chatUnpinMessage(chatID: chatID, pinID: pinID)
    }
}

extension PinnedMessages {
    /// Seconds since epoch from a server time: all-digit values are
    /// epoch ms (or s when small), else ISO 8601 (fractional or not).
    public static func serverSeconds(_ raw: String?) -> Double? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Double(t) {
            return n > 100_000_000_000 ? n / 1000 : n
        }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: t) ?? ISO8601DateFormatter().date(from: t) {
            return d.timeIntervalSince1970
        }
        return nil
    }

    /// Core pins → store pins. Order key is deterministic (pin time,
    /// else message time, else the ms-epoch message id, else 0) so a
    /// refetch never reshuffles the strip. Blank ids drop.
    public static func fromServer(_ pins: [ServerPin]) -> [PinnedMessage] {
        pins.compactMap { p in
            let mid = p.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty else { return nil }
            let at = serverSeconds(p.pinnedAt) ?? serverSeconds(p.time) ?? serverSeconds(mid) ?? 0
            return PinnedMessage(
                messageID: mid, sender: p.sender ?? "", preview: p.preview ?? "",
                timestamp: p.time ?? "", pinnedAt: at,
                fromServer: true, graphPinID: p.graphPinID)
        }
    }

    /// FIXPACK F2: a short public reason class for a failed pins read.
    /// Never carries a URL, id or body.
    public static func failureReason(_ error: Error) -> String {
        let text = String(describing: error).lowercased()
        if text.contains("401") || text.contains("unauthorized") || text.contains("no usable") { return "sign-in expired" }
        if text.contains("403") || text.contains("forbidden") { return "not permitted" }
        if text.contains("timed out") || text.contains("timeout") { return "timed out" }
        if text.contains("offline") || text.contains("connection") || text.contains("network") { return "offline" }
        return "read failed"
    }

    /// The pane's sentence for a failure reason.
    public static func failureMessage(_ reason: String) -> String {
        "Teams didn\u{2019}t answer the pinned messages request (\(reason)). Pins already here are kept."
    }

    /// One thread's pins after a server read: local-only pins stay;
    /// server pins (minus `dismissed`) replace the previous server set
    /// (pins unpinned in Teams drop). A pin already held keeps its
    /// order key and fills blank server fields from its old snapshot
    /// (a failed preview fill never blanks a row). Pure.
    public static func mergeServer(
        current: [PinnedMessage], server: [PinnedMessage], dismissed: Set<String>
    ) -> [PinnedMessage] {
        var prev: [String: PinnedMessage] = [:]
        for p in current where prev[p.messageID] == nil { prev[p.messageID] = p }
        var seen = Set<String>()
        let active = server.filter {
            !dismissed.contains($0.messageID) && seen.insert($0.messageID).inserted
        }
        let activeIDs = Set(active.map(\.messageID))
        var out = current.filter { !$0.isServer && !activeIDs.contains($0.messageID) }
        for s in active {
            guard let old = prev[s.messageID] else { out.append(s); continue }
            out.append(PinnedMessage(
                messageID: s.messageID,
                sender: s.sender.isEmpty ? old.sender : s.sender,
                preview: s.preview.isEmpty ? old.preview : s.preview,
                timestamp: s.timestamp.isEmpty ? old.timestamp : s.timestamp,
                pinnedAt: old.pinnedAt,
                fromServer: true, graphPinID: s.graphPinID ?? old.graphPinID))
        }
        return out.sorted { $0.pinnedAt < $1.pinnedAt }
    }
}

/// Per-thread pins, persisted locally. Main-actor (SwiftUI-owned).
@MainActor
public final class PinnedMessageStore: ObservableObject {
    /// Thread id -> pins (pin-time order). Empty threads are absent.
    @Published public private(set) var map: [String: [PinnedMessage]] = [:]
    /// Thread id -> why its last server-pin read failed (cleared by the
    /// next good read). Published only when the text changes.
    @Published public private(set) var loadFailures: [String: String] = [:]

    private let defaults: UserDefaults
    private let key: String
    /// Server pin I/O (§84); nil = local-only (demo, tests).
    public let server: (any PinnedServerTransport)?
    /// Thread id -> server pin ids the user unpinned here (a refetch
    /// never re-adds them). Persisted beside the pins.
    public private(set) var dismissed: [String: Set<String>] = [:]
    private var dismissedKey: String { key + ".dismissed" }

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults = .standard, key: String = PinnedMessages.defaultsKey,
        server: (any PinnedServerTransport)? = nil
    ) {
        self.defaults = defaults
        self.key = key
        self.server = server
        _map = Published(initialValue: PinnedMessages.decode(defaults.data(forKey: key)))
        if let data = defaults.data(forKey: key + ".dismissed"),
           let raw = try? JSONDecoder().decode([String: [String]].self, from: data) {
            dismissed = raw.mapValues { Set($0) }
        }
    }

    /// §84: read one thread's Teams pins off-main and merge them in.
    /// A blank id or no transport (demo) is a no-op. FIXPACK F2: a failed
    /// read keeps whatever the strip already shows, records the reason in
    /// `loadFailures` (the pane says so instead of showing "No Pinned
    /// Messages") and logs the reason class; an empty answer is logged as
    /// "the source carried no pins" so an empty bar can be told apart from
    /// a broken one.
    public func refreshFromServer(chatID: String?) async {
        guard let server,
              let id = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return }
        let result: Result<[PinnedMessage], Error> = await Task.blocking(operation: {
            Result { try server.fetchPins(chatID: id) }
        }).value
        switch result {
        case .success(let fetched):
            if loadFailures[id] != nil { loadFailures[id] = nil }
            if fetched.isEmpty {
                Log.pins.info("pins: chat service answered no pins for this thread (empty source, not an error)")
            }
            applyServer(chatID: id, pins: fetched)
        case .failure(let error):
            let reason = PinnedMessages.failureReason(error)
            Log.pins.error("pins: read failed (\(reason, privacy: .public)); the pins pane shows an error")
            Log.pins.debug("pins: detail \(String(describing: error), privacy: .private)")
            let text = PinnedMessages.failureMessage(reason)
            if loadFailures[id] != text { loadFailures[id] = text }
        }
    }

    /// The user-facing failure for `chatID`'s last server read, if it failed.
    public func loadFailure(for chatID: String?) -> String? {
        guard let id = chatID?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return loadFailures[id]
    }

    /// Merge one thread's server pins (see `PinnedMessages.mergeServer`).
    /// Publishes and persists only when the thread's pins change;
    /// dismissals the server no longer lists are forgotten (a later
    /// re-pin in Teams shows again).
    public func applyServer(chatID: String, pins server: [PinnedMessage]) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let gone = dismissed[id] ?? []
        let kept = gone.intersection(server.map(\.messageID))
        if kept != gone {
            dismissed[id] = kept.isEmpty ? nil : kept
            persistDismissed()
        }
        let cur = map[id] ?? []
        let merged = PinnedMessages.mergeServer(current: cur, server: server, dismissed: kept)
        guard merged != cur else { return }
        if merged.isEmpty {
            map.removeValue(forKey: id)
        } else {
            map[id] = merged
        }
        persist()
    }

    /// Pins for one thread, pin-time order. Blank/nil threads hold none.
    public func pins(for chatID: String?) -> [PinnedMessage] {
        guard let id = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return [] }
        return (map[id] ?? []).sorted { $0.pinnedAt < $1.pinnedAt }
    }

    /// True when the bubble is pinned in this thread.
    public func isPinned(chatID: String?, messageID: String) -> Bool {
        let mid = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return false }
        return pins(for: chatID).contains(where: { $0.messageID == mid })
    }

    /// Pin one bubble (snapshot at pin time). Blank ids and re-pins
    /// are no-ops (no duplicate, no rewrite).
    public func pin(chatID: String?, message: ChatMessage, at: Date = Date()) {
        guard let id = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return }
        let mid = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return }
        var cur = map[id] ?? []
        guard !cur.contains(where: { $0.messageID == mid }) else { return }
        cur.append(PinnedMessage.from(message: message, at: at))
        cur.sort { $0.pinnedAt < $1.pinnedAt }
        map[id] = cur
        persist()
    }

    /// Pin from a snapshot (callers holding ids, not bubbles). Blank
    /// ids and re-pins are no-ops.
    public func pin(
        chatID: String?, messageID: String, sender: String,
        preview: String, timestamp: String, at: Date = Date()
    ) {
        guard let id = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return }
        let mid = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return }
        var cur = map[id] ?? []
        guard !cur.contains(where: { $0.messageID == mid }) else { return }
        cur.append(PinnedMessage(
            messageID: mid, sender: sender, preview: preview,
            timestamp: timestamp, pinnedAt: at.timeIntervalSince1970))
        cur.sort { $0.pinnedAt < $1.pinnedAt }
        map[id] = cur
        persist()
    }

    /// Unpin one bubble. Unknown ids are a no-op (no write). Server
    /// pins (§84) are recorded as dismissed; Graph-sourced ones also
    /// send Graph DELETE off-main (returned task: tests await it).
    @discardableResult
    public func unpin(chatID: String?, messageID: String) -> Task<Void, Never>? {
        guard let id = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return nil }
        let mid = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty, var cur = map[id],
              let pin = cur.first(where: { $0.messageID == mid })
        else { return nil }
        cur.removeAll(where: { $0.messageID == mid })
        if cur.isEmpty {
            map.removeValue(forKey: id)
        } else {
            map[id] = cur
        }
        persist()
        guard pin.isServer else { return nil }
        dismissed[id, default: []].insert(mid)
        persistDismissed()
        guard let server, let pinID = pin.graphPinID, !pinID.isEmpty else { return nil }
        return Task.blocking { try? server.unpin(chatID: id, pinID: pinID) }
    }

    /// Toggle one bubble's pin (the context-menu action).
    public func toggle(chatID: String?, message: ChatMessage, at: Date = Date()) {
        if isPinned(chatID: chatID, messageID: message.id) {
            unpin(chatID: chatID, messageID: message.id)
        } else {
            pin(chatID: chatID, message: message, at: at)
        }
    }

    /// Strip rows for the open thread (live window resolves jumps).
    public func rows(for chatID: String?, messages: [ChatMessage]) -> [PinnedMessages.StripRow] {
        PinnedMessages.rows(pins: pins(for: chatID), messages: messages)
    }

    /// Indexed strip rows (om-s6-renderparse): same rows against a
    /// body-eval `MessageIndex` (no per-pin scan).
    public func rows(
        for chatID: String?, messages: [ChatMessage], index: MessageIndex
    ) -> [PinnedMessages.StripRow] {
        PinnedMessages.rows(pins: pins(for: chatID), messages: messages, index: index)
    }

    /// Adopt one thread's pins wholesale (demo seeding + tests).
    public func adopt(chatID: String, pins: [PinnedMessage]) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let clean = PinnedMessages.sanitize([id: pins])[id] ?? []
        if clean.isEmpty {
            guard map.removeValue(forKey: id) != nil else { return }
        } else {
            map[id] = clean
        }
        persist()
    }

    /// Drop every pin (tests only — the app never clears pins, not
    /// even on sign-out: reminders outlive the session).
    public func clearAll() {
        guard !map.isEmpty else { return }
        map.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(PinnedMessages.encode(map), forKey: key)
    }

    private func persistDismissed() {
        let raw = dismissed.mapValues { $0.sorted() }
        defaults.set(try? JSONEncoder().encode(raw), forKey: dismissedKey)
    }
}

