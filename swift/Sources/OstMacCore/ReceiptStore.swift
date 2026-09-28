// ReceiptStore.swift — om-receipts: per-thread read positions + send path.
//
// Sends the read position (consumption horizon) when the reader views the
// latest bubble, stores peer positions per thread, and answers the
// timeline's own-message read question. Never touches the chat list;
// counters surface in Diagnostics only.
//
//   let receipts = ReceiptStore()
//   receipts.sendReadPosition(chatID: id, latestID: msgs.last?.id)
//   receipts.isOwnRead(chatID: id, messageID: m.id, messages: msgs)
//
// Threading: @MainActor (ObservableObject for timeline + Diagnostics).
// Core calls hop off-main via Task.detached; transports are injectable
// for tests (throwing closures, no network).
import Foundation

/// Per-thread read receipts: sent positions + peer frontier map.
@MainActor
public final class ReceiptStore: ObservableObject {
    /// Peer frontier per thread: threadID -> (userKey -> lastReadMessageID).
    /// Blank user keys collapse onto "" (unknown peer, still counts as read).
    @Published public private(set) var map: [String: [String: String]] = [:]
    /// Last sent own position per thread (dedupes repeat sends).
    @Published public private(set) var sent: [String: String] = [:]
    /// Last send/fetch failure (Diagnostics only; timeline stays quiet).
    @Published public private(set) var lastError: String?

    private let sender: @Sendable (String, String) throws -> Void
    private let fetcher: @Sendable (String) throws -> [ReadReceipt]

    /// Ghost-mode gate (f1-ghost): when set and suppressing receipts,
    /// `sendReadPosition` counts a suppression and sends nothing
    /// (`sent[]` stays unmoved — retryable on lift, same rule as
    /// failure). Nil = live (pre-ghost behavior, byte-identical).
    public var ghost: GhostStore?

    /// Nonisolated so views can take a default `ReceiptStore()` in their
    /// (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        sender: (@Sendable (String, String) throws -> Void)? = nil,
        fetcher: (@Sendable (String) throws -> [ReadReceipt])? = nil
    ) {
        self.sender = sender ?? { chatID, messageID in
            _ = try RustCore.markRead(chatID: chatID, messageID: messageID)
        }
        self.fetcher = fetcher ?? { threadID in
            try RustCore.receipts(threadID: threadID).receipts
        }
    }

    /// Threads with at least one peer position (Diagnostics count).
    public var threadCount: Int { map.count }

    /// Peer positions across all threads (Diagnostics count).
    public var receiptCount: Int { map.values.reduce(0) { $0 + $1.count } }

    /// Sent positions across all threads (Diagnostics count).
    public var sentCount: Int { sent.count }

    /// Pure send gate: both ids non-blank and the position differs from
    /// the last sent one for this thread. Repeat views of the same tail
    /// are no-ops (no network churn).
    nonisolated public static func shouldSend(
        chatID: String?, latestID: String?, sent: [String: String]
    ) -> Bool {
        guard let chat = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chat.isEmpty,
              let latest = latestID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !latest.isEmpty
        else { return false }
        return sent[chat] != latest
    }

    /// True when a send for this thread/tail would fire.
    public func shouldSend(chatID: String?, latestID: String?) -> Bool {
        Self.shouldSend(chatID: chatID, latestID: latestID, sent: sent)
    }

    /// Send the read position for viewing the latest bubble. No-op on
    /// blank ids or repeat tails. Records the position optimistically?
    /// No — only on success (failures stay retryable, error surfaces in
    /// Diagnostics). Demo callers pass `localOnly` to record without core.
    public func sendReadPosition(chatID: String?, latestID: String?, localOnly: Bool = false) {
        guard let chat = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !chat.isEmpty,
              let latest = latestID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !latest.isEmpty
        else { return }
        guard sent[chat] != latest else { return }
        if localOnly {
            sent[chat] = latest
            return
        }
        // Ghost (f1-ghost): suppress the server send only — below the
        // dedupe (repeat tails stay free no-ops) and below localOnly
        // (demo path, no network). `sent[]` unmoved (retryable on
        // lift), `lastError` untouched (not a failure).
        if let ghost, ghost.shouldSuppressReceipts {
            ghost.noteSuppressedReceipt()
            return
        }
        let send = sender
        Task {
            do {
                try await Task.detached { try send(chat, latest) }.value
                self.sent[chat] = latest
            } catch {
                self.lastError = "read position failed: \(error)"
            }
        }
    }

    /// Merge fetched peer positions into one thread's map. Blank message
    /// ids are dropped; blank users collapse onto "". Empty input clears
    /// nothing (a bare poll never wipes known positions).
    public func apply(threadID: String, receipts: [ReadReceipt]) {
        let thread = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thread.isEmpty else { return }
        var cur = map[thread] ?? [:]
        for r in receipts {
            let mid = r.message_id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty else { continue }
            cur[r.user] = mid
        }
        map[thread] = cur
    }

    /// Fetch peer positions for one thread and merge them. Blank ids are
    /// a no-op; failures surface in Diagnostics (timeline keeps showing
    /// the last known state). Never refreshes the chat list.
    public func refresh(threadID: String) {
        let thread = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thread.isEmpty else { return }
        let fetch = fetcher
        Task {
            do {
                let list = try await Task.detached { try fetch(thread) }.value
                self.apply(threadID: thread, receipts: list)
            } catch {
                self.lastError = "receipts failed: \(error)"
            }
        }
    }

    /// Peer frontier ids for one thread (empty when unknown).
    public func peerReadIDs(for chatID: String) -> Set<String> {
        Set((map[chatID] ?? [:]).values)
    }

    /// True when an own bubble reads as seen: some peer frontier sits at
    /// or past it in timeline order. Unknown threads/peers/ids read false
    /// (fail closed — never claim Seen without evidence).
    public func isOwnRead(chatID: String, messageID: String, messages: [ChatMessage]) -> Bool {
        Self.isRead(messageID: messageID, messages: messages, peerIDs: peerReadIDs(for: chatID))
    }

    /// Indexed own-read (om-s6-renderparse): same answer, O(peers)
    /// against a body-eval `MessageIndex.position` (no scans).
    public func isOwnRead(chatID: String, messageID: String, position: [String: Int]) -> Bool {
        Self.isRead(messageID: messageID, position: position, peerIDs: peerReadIDs(for: chatID))
    }

    /// Pure read check: `messageID` precedes-or-equals any `peerIDs` entry
    /// in `messages` order. Unknown message or peers read false. One
    /// pass (first positions win, exactly like the old scan-per-peer).
    nonisolated public static func isRead(
        messageID: String, messages: [ChatMessage], peerIDs: Set<String>
    ) -> Bool {
        guard !messageID.isEmpty, !peerIDs.isEmpty else { return false }
        var at: Int?
        var peerAt: [String: Int] = [:]
        for (i, m) in messages.enumerated() {
            if at == nil, m.id == messageID { at = i }
            if peerIDs.contains(m.id), peerAt[m.id] == nil { peerAt[m.id] = i }
            if at != nil, peerAt.count == peerIDs.count { break }
        }
        guard let at else { return false }
        return peerAt.values.contains { $0 >= at }
    }

    /// Pure read check over a prebuilt position map (same semantics as
    /// the `messages` overload: first positions win).
    nonisolated public static func isRead(
        messageID: String, position: [String: Int], peerIDs: Set<String>
    ) -> Bool {
        guard !messageID.isEmpty, !peerIDs.isEmpty else { return false }
        guard let at = position[messageID] else { return false }
        for peer in peerIDs {
            if let pi = position[peer], pi >= at { return true }
        }
        return false
    }

    /// Peer readers of one bubble (real-Teams receipts): user keys whose
    /// frontier sits at or past it in `position` order. Sorted, blanks
    /// kept ("" = unknown peer, still evidence — same fail-open as
    /// `isRead`). Unknown message reads empty (fail closed).
    public func readers(chatID: String, messageID: String, position: [String: Int]) -> [String] {
        Self.readers(messageID: messageID, position: position, peers: map[chatID] ?? [:])
    }

    /// Pure reader check: every peer whose frontier id sits at or past
    /// `messageID` in `position` order. First positions win (same rule
    /// as the `isRead` overloads).
    nonisolated public static func readers(
        messageID: String, position: [String: Int], peers: [String: String]
    ) -> [String] {
        guard !messageID.isEmpty, !peers.isEmpty else { return [] }
        guard let at = position[messageID] else { return [] }
        return peers.keys.filter { user in
            guard let frontier = peers[user], let pi = position[frontier] else { return false }
            return pi >= at
        }.sorted()
    }

    /// Demo/test seeding: adopt one thread's peer map wholesale.
    public func adopt(threadID: String, peers: [String: String]) {
        let thread = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thread.isEmpty else { return }
        map[thread] = peers
    }

    /// Demo send: record the position without touching core.
    public func noteSent(chatID: String, messageID: String) {
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        let mid = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chat.isEmpty, !mid.isEmpty else { return }
        sent[chat] = mid
    }

    /// Clear every thread (sign-out). Timeline falls back to unread.
    public func clear() {
        guard !map.isEmpty || !sent.isEmpty || lastError != nil else { return }
        map.removeAll()
        sent.removeAll()
        lastError = nil
    }
}

// MARK: - Real-Teams receipt display (lanes/receipts)

/// Own-bubble receipt mark, resolved per bubble (pure, tested):
/// Sent (checkmark) ALWAYS on own sent messages; Seen (eye) upgrade
/// when a peer frontier sits at/past the bubble AND receipts are
/// enabled (mutual opt-out: receipts-off renders Sent forever);
/// group chats with <= `maxGroupReaders` readers show Seen-by-N with
/// the who-read list; channel posts show nothing (no channel receipt
/// API — chat-service consumptionhorizons 403s on channel threads).
public enum ReceiptDisplay: Equatable, Sendable {
    /// No mark: peer bubbles, failed sends, channel posts.
    case none
    /// Own sent, unread (or receipts disabled): checkmark.
    case sent
    /// Own sent + read in 1:1 (or > cap readers): eye.
    case seen
    /// Own sent + read in a group <= cap: eye + count + who list.
    case seenBy(readers: [String])

    /// Teams shows Seen-by-N only in groups of <= 20 members. No
    /// member-count API exists, so the reader count proxies it:
    /// readers can never exceed members, so > 20 readers implies >
    /// 20 members (plain Seen). Fewer readers than the cap in a big
    /// group still shows Seen-by-N (documented approximation).
    public static let maxGroupReaders = 20

    /// Pure matrix. `readers` = `ReceiptStore.readers(...)` for the
    /// bubble (already evidence-filtered); `receiptsEnabled` = NOT
    /// ghost-suppressed (the Settings → Ghost mode → Hide read
    /// receipts toggle, mutual opt-out).
    public static func resolve(
        isOwn: Bool, failed: Bool, isChannel: Bool,
        receiptsEnabled: Bool, isGroup: Bool, readers: [String]
    ) -> ReceiptDisplay {
        guard isOwn, !failed, !isChannel else { return .none }
        guard receiptsEnabled, !readers.isEmpty else { return .sent }
        guard isGroup, readers.count <= maxGroupReaders else { return .seen }
        return .seenBy(readers: readers.sorted())
    }

    /// True for every visible mark (bubble reserves the trailing slot).
    public var isVisible: Bool { self != .none }

    /// True only when the who-read list exists (tap/hover surface).
    public var showsWhoList: Bool {
        if case .seenBy = self { return true }
        return false
    }

    /// VoiceOver label (mark combines image + count into one element).
    public var accessibilityLabel: String {
        switch self {
        case .none: return ""
        case .sent: return "Sent"
        case .seen: return "Seen"
        case .seenBy(let readers): return "Seen by \(readers.count)"
        }
    }
}
