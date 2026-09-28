// BackgroundAccounts.swift — gap-g1: background events + unified notif
// roll-up for INACTIVE accounts.
//
// The live RealtimeFeed serves the active profile only (single global
// trouter). This file is the 2nd feed: a REST poller that sweeps the
// inactive accounts' chat lists on a timer, diffs each chat's last-message
// fingerprint, and emits one BackgroundChatEvent per arrival. No profile
// flips, no trouter disturb: CoreReads loads each account's tokens by
// profile (same seam as the per-account whoami/refresh reads).
//
// Pipeline (App owns it, live mode only):
//   poller.pollOnce(accounts:activeID:) → [BackgroundChatEvent]
//     → per-account rules snapshot (BackgroundRules) → ChatFilter.decide
//     → .notify: banner naming the account (userInfo carries the account
//       id) + BackgroundUnreadRollup.note (surfaced on switch)
//     → .skip: counted, silent
//
// Cadence: the App's 30s timer drives pollOnce off-main (blocking
// network, same contract as the old FFI reads). First sight of an
// account seeds its snapshot silently — launch never banner-storms.
import Foundation

/// One arrival on an inactive account: the chat-list diff signal shaped
/// like a live event. `fingerprint` is the last-message snapshot that
/// changed (time|sender|preview); `asRealtimeMessage` synthesizes the
/// notifiable event (msgId stable per fingerprint, account-stamped).
public struct BackgroundChatEvent: Sendable, Equatable {
    public let accountID: String
    public let accountName: String
    public let chatID: String
    public let chatName: String
    /// Group thread per the polled list row (blocked-gate parity with
    /// the live path, which reads the active list instead).
    public let isGroup: Bool
    public let sender: String
    public let text: String
    public let time: String
    public let fingerprint: String

    public init(
        accountID: String, accountName: String,
        chatID: String, chatName: String,
        isGroup: Bool = false,
        sender: String, text: String, time: String,
        fingerprint: String
    ) {
        self.accountID = accountID
        self.accountName = accountName
        self.chatID = chatID
        self.chatName = chatName
        self.isGroup = isGroup
        self.sender = sender
        self.text = text
        self.time = time
        self.fingerprint = fingerprint
    }

    /// Last-message snapshot for one chat row (unit separator-joined;
    /// nils fold to ""). Pure: the poller and tests share it.
    public static func fingerprint(chat: ChatItem) -> String {
        [
            chat.last_message_time ?? "",
            chat.last_message_sender ?? "",
            chat.last_message_preview ?? "",
        ].joined(separator: "\u{1F}")
    }

    /// True when the row carries no last-message at all (empty chat —
    /// never an arrival, but still seeds the snapshot).
    public static func isEmptyChat(chat: ChatItem) -> Bool {
        (chat.last_message_time ?? "").isEmpty
            && (chat.last_message_sender ?? "").isEmpty
            && (chat.last_message_preview ?? "").isEmpty
    }

    /// Synthesized live-shaped event: stable msgId per fingerprint
    /// (FNV-1a over account+chat+fingerprint), stamped with the owning
    /// account. Feeds the same rules/banner path as trouter events.
    public var asRealtimeMessage: RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: Self.messageID(
                accountID: accountID, chatID: chatID,
                fingerprint: fingerprint),
            sender: sender, text: text, time: time,
            isEdit: false, accountID: accountID)
    }

    /// Stable id for one background arrival (dedupe + UN request id).
    public static func messageID(accountID: String, chatID: String, fingerprint: String) -> String {
        var hash: UInt64 = 14_695_981_037_393_711_985
        for byte in "\(accountID)\u{1F}\(chatID)\u{1F}\(fingerprint)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "bg-\(String(hash, radix: 16))"
    }
}

/// Per-account rules snapshot (gap-g1): the global config with the
/// OWNER identity re-stamped for the polled account. Own-message and
/// mention matching must see the background account's identity, never
/// the active account's. Mute/keyword sets stay global (chat ids are
/// tenant-unique in practice; per-account overrides are out of scope).
public enum BackgroundRules {
    /// Snapshot `base` for `account`: displayName always re-stamped;
    /// MRI from the record's Teams user id, or "" when unresolved (falls
    /// back to name matching — never the ACTIVE account's MRI).
    public static func snapshot(base: RulesConfig, account: AccountRecord) -> RulesConfig {
        var cfg = base
        cfg.owner.displayName = account.displayName
        if let oid = account.userID, !oid.isEmpty {
            cfg.owner.mri = "8:orgid:\(oid)"
        } else {
            cfg.owner.mri = ""
        }
        return cfg
    }

    /// Owner MRI the snapshot resolves (the App's live-name backup does
    /// not apply: background accounts have no live conv identity).
    public static func ownerMRI(account: AccountRecord) -> String? {
        guard let oid = account.userID, !oid.isEmpty else { return nil }
        return "8:orgid:\(oid)"
    }
}

/// Unified unread roll-up for inactive accounts (gap-g1): per-account
/// per-chat counts accrued by background .notify decisions. The live
/// UnreadStore keeps serving the active account only; on switch the App
/// drains the newly-active account's stash into it (`take`), so the
/// switch lands on unread 1. Session-scoped (in-memory): relaunch
/// re-seeds from the next poll, never from stale disk.
public struct BackgroundUnreadRollup: Sendable, Equatable {
    /// accountID → chatID → count. Zero-count entries never stored.
    public private(set) var counts: [String: [String: Int]] = [:]

    public init() {}

    public var isEmpty: Bool { counts.isEmpty }

    /// Total across every inactive account (Diagnostics).
    public var grandTotal: Int {
        counts.values.flatMap(\.values).reduce(0, +)
    }

    /// Total for one account (0 when absent).
    public func total(for accountID: String) -> Int {
        counts[accountID]?.values.reduce(0, +) ?? 0
    }

    /// Per-chat counts for one account (empty when absent).
    public func counts(for accountID: String) -> [String: Int] {
        counts[accountID] ?? [:]
    }

    /// Accrue one background arrival. Blank ids are no-ops.
    public mutating func note(accountID: String, chatID: String) {
        let acct = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !acct.isEmpty, !chat.isEmpty else { return }
        counts[acct, default: [:]][chat, default: 0] += 1
    }

    /// Drain one account's stash (switch handoff): returns its per-chat
    /// counts and drops the entry. Unknown accounts yield [:].
    public mutating func take(accountID: String) -> [String: Int] {
        counts.removeValue(forKey: accountID) ?? [:]
    }

    /// Merge counts accrued elsewhere (gap-g2 window-close handoff:
    /// the closing window's graph unread lands here, so a later
    /// switch still shows unread N). Additive; blank ids and
    /// non-positive counts are dropped. Empty input is a no-op.
    public mutating func ingest(
        _ incoming: [String: Int], for accountID: String
    ) {
        let acct = accountID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !acct.isEmpty else { return }
        for (chatID, n) in incoming {
            let chat = chatID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !chat.isEmpty, n > 0 else { continue }
            counts[acct, default: [:]][chat, default: 0] += n
        }
    }

    /// Drop one account's stash without reading it (remove-account).
    public mutating func drop(accountID: String) {
        counts.removeValue(forKey: accountID)
    }

    /// Clear every stash (sign-out-all).
    public mutating func clear() {
        counts.removeAll()
    }
}

/// 2nd feed: REST sweep over inactive accounts. Stateful differ —
/// `pollOnce` fetches each non-active account's chat list (per-profile
/// tokens, no active flip), diffs last-message fingerprints against the
/// per-account snapshot, and returns one event per new/changed arrival:
///
/// - first sight of an account seeds its snapshot silently (no events)
/// - empty chats (no last message) seed but never emit
/// - vanished chats are forgotten silently (no event)
/// - a failed fetch skips that account (lastError kept), others proceed
/// - the active account is never fetched
///
/// Threading: locked state, sync blocking fetch — call off-main.
public final class BackgroundAccountPoller: @unchecked Sendable {
    /// Chat-list page per account per sweep (recency-ordered; arrivals
    /// surface at the top).
    public static let pollLimit: Int32 = 20

    private let lock = NSLock()
    private var snapshots: [String: [String: String]] = [:]
    private var errors: [String: String] = [:]
    private let fetch: @Sendable (String) throws -> ChatsResponse

    /// `fetch` maps profile id → chat list. Default is the live
    /// per-profile read; tests inject stubs. Zero network either way
    /// until pollOnce runs.
    public init(
        fetch: (@Sendable (String) throws -> ChatsResponse)? = nil
    ) {
        self.fetch = fetch ?? { try RustCore.chats(
            limit: BackgroundAccountPoller.pollLimit, profile: $0) }
    }

    /// Last fetch failure per account id, cleared on the next success.
    public func lastError(for accountID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return errors[accountID]
    }

    /// Accounts currently snapshotted (Diagnostics).
    public var snapshotAccountIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(snapshots.keys)
    }

    /// One sweep over `accounts` minus `activeID`. Returns arrivals
    /// oldest-first per account, accounts in list order.
    @discardableResult
    public func pollOnce(accounts: [AccountRecord], activeID: String?) -> [BackgroundChatEvent] {
        var events: [BackgroundChatEvent] = []
        for account in accounts {
            guard account.id != activeID else { continue }
            let response: ChatsResponse
            do {
                response = try fetch(account.id)
            } catch {
                lock.lock()
                errors[account.id] = String(describing: error)
                lock.unlock()
                continue
            }
            lock.lock()
            errors.removeValue(forKey: account.id)
            let previous = snapshots[account.id]
            lock.unlock()
            let seen = previous != nil
            var next: [String: String] = [:]
            next.reserveCapacity(response.chats.count)
            for chat in response.chats {
                let fp = BackgroundChatEvent.fingerprint(chat: chat)
                next[chat.chatId] = fp
                guard seen else { continue } // first sweep seeds silently
                guard !BackgroundChatEvent.isEmptyChat(chat: chat) else { continue }
                guard previous?[chat.chatId] != fp else { continue }
                events.append(BackgroundChatEvent(
                    accountID: account.id, accountName: account.displayName,
                    chatID: chat.chatId, chatName: chat.name,
                    isGroup: chat.is_group,
                    sender: chat.last_message_sender ?? "",
                    text: chat.last_message_preview ?? "",
                    time: chat.last_message_time ?? "",
                    fingerprint: fp))
            }
            lock.lock()
            snapshots[account.id] = next
            lock.unlock()
        }
        return events
    }

    /// Forget one account (remove-account): snapshot + error dropped.
    public func drop(accountID: String) {
        lock.lock(); defer { lock.unlock() }
        snapshots.removeValue(forKey: accountID)
        errors.removeValue(forKey: accountID)
    }

    /// Forget everything (sign-out-all / tests).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        snapshots.removeAll()
        errors.removeAll()
    }
}
