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
// Server sync: no server-side chat pin API exists in ost/ostmac-core
// (probed chat/graph/models + the C ABI — no pin endpoint), so this
// lane is local-first and local-only. If such an API appears, sync it
// here best-effort; local state stays the source of truth regardless.
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

    public init(
        messageID: String, sender: String, preview: String,
        timestamp: String, pinnedAt: Double
    ) {
        self.messageID = messageID
        self.sender = sender
        self.preview = preview
        self.timestamp = timestamp
        self.pinnedAt = pinnedAt
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

/// Per-thread pins, persisted locally. Main-actor (SwiftUI-owned).
@MainActor
public final class PinnedMessageStore: ObservableObject {
    /// Thread id -> pins (pin-time order). Empty threads are absent.
    @Published public private(set) var map: [String: [PinnedMessage]] = [:]

    private let defaults: UserDefaults
    private let key: String

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults = .standard, key: String = PinnedMessages.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
        _map = Published(initialValue: PinnedMessages.decode(defaults.data(forKey: key)))
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

    /// Unpin one bubble. Unknown ids are a no-op (no write).
    public func unpin(chatID: String?, messageID: String) {
        guard let id = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty
        else { return }
        let mid = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty, var cur = map[id] else { return }
        let before = cur.count
        cur.removeAll(where: { $0.messageID == mid })
        guard cur.count != before else { return }
        if cur.isEmpty {
            map.removeValue(forKey: id)
        } else {
            map[id] = cur
        }
        persist()
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
}

