// UnreadStore.swift — om-notifbadge: rules-driven unread + dock badge.
//
// Counts accrue on ChatFilter .notify AND on mute skips
// ("muted"/"teams-muted"/"chat-muted", fid-lists D19): a muted chat
// still bolds its row unread, like real Teams. Every other .skip
// (keyword-block, structural bodies, own/type/edit/noisy,
// meeting-suppressed, snoozed, DND/quiet) leaves counts and the dock
// untouched. The open chat never accrues (its bubbles are already
// visible); opening a chat marks it read. Dock badge = total unread
// EXCLUDING muted chats, cleared at zero.
//
//   let unread = UnreadStore() // live dock badge
//   unread.ingest(decision: decision, chatID: msg.chatID, openChatID: openChatID)
//   unread.markRead(chatID: id) // on open
//
// Launch state: every chat list fetch seeds counts from the Teams read
// horizon (`seed(_:)`, ChatListSeed); live events keep them current.
//
// om-markunread: manual mark-as-unread/read rides a per-thread read
// horizon override (`overrides`). `markUnread` pins a thread unread at
// its current tail (badge shows at least 1); the sidebar badge reads
// the visible count in place (no list refetch, no reorder — the
// ChatListViewModel is untouched); opening the thread clears the
// override via the same `markRead` the open path already calls.
// Threading: @MainActor (ObservableObject for the sidebar + NSApp dock).
// The dock sink is injectable for tests (FakeDockBadge records labels).
import AppKit
import Foundation

/// Dock badge sink: the real dock tile or an in-memory fake.
public protocol DockBadging: Sendable {
    func setBadge(_ label: String?)
}

/// Live sink over the app dock tile. Hops to the main thread (AppKit).
/// Uses NSApplication.shared (never the NSApp global, which traps when
/// no app object exists — e.g. store tests running outside the app).
public final class SystemDockBadge: DockBadging, @unchecked Sendable {
    public init() {}

    public func setBadge(_ label: String?) {
        let value = label ?? ""
        if Thread.isMainThread {
            NSApplication.shared.dockTile.badgeLabel = value
        } else {
            DispatchQueue.main.sync { NSApplication.shared.dockTile.badgeLabel = value }
        }
    }
}

/// In-memory sink (tests): records every label set.
public final class FakeDockBadge: DockBadging, @unchecked Sendable {
    private let lock = NSLock()
    private var _labels: [String?] = []

    public init() {}

    public func setBadge(_ label: String?) {
        lock.lock(); defer { lock.unlock() }
        _labels.append(label)
    }

    public var labels: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _labels
    }
}

/// Per-chat unread counts + dock badge, driven by rules decisions.
@MainActor
public final class UnreadStore: ObservableObject {
    /// Unread per chat id. Zero-count chats are absent, never stored as 0.
    @Published public private(set) var counts: [String: Int] = [:]
    /// Manual read-horizon overrides (om-markunread): threads pinned
    /// unread via Mark as Unread. Cleared ids are absent, never stored
    /// empty. Client-side only (never sent to core); opening a thread
    /// clears its override via `markRead`.
    @Published public private(set) var overrides: Set<String> = []
    /// Muted-unread ids (fid-lists D19): chats whose row unread came
    /// from a mute skip (or a manual mark on a muted chat). Derived
    /// from decisions at ingest — no RulesStore wiring needed. These
    /// chats bold their rows but stay out of `total`/dock. A later
    /// .notify proves unmute and drops the flag; `markRead`/
    /// `markAllRead` clear it with the counts.
    @Published public private(set) var mutedUnreadIDs: Set<String> = []
    /// Ids whose count came from a server seed (ChatListSeed), not a
    /// live accrual: a later seed saying "read" clears only these.
    private var seededIDs: Set<String> = []
    /// When each chat was last opened here: a seed never re-marks a chat
    /// whose last message the owner already saw in this app (read
    /// receipts may be off or lag behind the next list fetch).
    private var readAt: [String: Date] = [:]
    /// Send time of the newest live-accrued message per chat: a later
    /// seed whose last message is at or past it proves the chat was
    /// read elsewhere (another client), so the live count clears too.
    private var accruedAt: [String: Date] = [:]
    /// When each override was set here (CHATSYNC): a list fetch that
    /// started before it cannot clear it (stale answer).
    private var overrideAt: [String: Date] = [:]

    private let dock: any DockBadging

    /// Nonisolated so views can take a default `UnreadStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(dock: (any DockBadging)? = nil) {
        self.dock = dock ?? SystemDockBadge()
    }

    /// Total unread across chats (the dock number), overrides included:
    /// each overridden thread contributes at least 1. Muted-unread
    /// chats are EXCLUDED (fid-lists D19): their rows still bold, but
    /// they never move the badge.
    public var total: Int {
        Self.visibleTotal(counts: counts, overrides: overrides, excluding: mutedUnreadIDs)
    }

    /// Chats with a visible badge (Diagnostics count), overrides included.
    /// Muted-unread chats count here (their rows badge) — only the
    /// dock `total` excludes them.
    public var chatCount: Int {
        Self.visibleChats(counts: counts, overrides: overrides)
    }

    /// Dock label for the current total: nil at zero (clears the tile).
    public var badgeLabel: String? {
        Self.badgeLabel(forTotal: total)
    }

    /// Pure label: nil at zero, else the decimal total.
    nonisolated public static func badgeLabel(forTotal total: Int) -> String? {
        total > 0 ? "\(total)" : nil
    }

    /// Pure visible count for one thread (om-markunread badge math): the
    /// auto count, floored at 1 while its horizon override stands. An
    /// override absorbs the first auto point (mark-unread then one new
    /// message still shows 1, not 2); further accruals count past it.
    nonisolated public static func visibleCount(auto: Int, overridden: Bool) -> Int {
        overridden ? max(auto, 1) : max(auto, 0)
    }

    /// Pure visible total over every thread (the dock number).
    /// `excluding` drops muted-unread chats from the sum (their rows
    /// still badge via `count(for:)`).
    nonisolated public static func visibleTotal(
        counts: [String: Int], overrides: Set<String>, excluding: Set<String> = []
    ) -> Int {
        var total = 0
        for (id, auto) in counts where !excluding.contains(id) {
            total += visibleCount(auto: auto, overridden: overrides.contains(id))
        }
        for id in overrides where counts[id] == nil && !excluding.contains(id) {
            total += 1
        }
        return total
    }

    /// Pure visible chat count: threads with a badge (auto or override).
    nonisolated public static func visibleChats(counts: [String: Int], overrides: Set<String>) -> Int {
        var ids = Set(counts.keys)
        ids.formUnion(overrides)
        return ids.count
    }

    /// True for the mute skips that still accrue row unread
    /// (fid-lists D19): global "muted", "teams-muted", "chat-muted".
    /// Snoozed/DND/quiet and every other skip never accrue.
    nonisolated public static func isMutedSkip(_ decision: ChatFilter.Decision) -> Bool {
        guard case .skip(let reason) = decision else { return false }
        return reason == ChatFilter.mutedReason
            || reason == ChatFilter.teamsMutedReason
            || reason == ChatFilter.chatMutedReason
    }

    /// Pure accrual gate: notify AND mute skips count, unless the chat
    /// is already open (visible bubbles) or the id is blank. Every
    /// other skip never counts. `visibleChatIDs` (e1-popout: main-open
    /// + popped) extends the open-chat exemption to pop-out windows.
    nonisolated public static func shouldCount(
        decision: ChatFilter.Decision, chatID: String, openChatID: String?,
        visibleChatIDs: Set<String> = []
    ) -> Bool {
        switch decision {
        case .notify: break
        case .skip where isMutedSkip(decision): break
        case .skip: return false
        }
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if visibleChatIDs.contains(chatID) { return false }
        if let open = openChatID, open == chatID { return false }
        return true
    }

    /// Accrue one rules decision for a chat. Non-mute skips and
    /// open-chat accruals are no-ops (no dock write). A mute skip
    /// accrues the row count AND flags the chat muted-unread (out of
    /// the dock total); a notify accrues and clears the muted flag (a
    /// notify proves the chat is unmuted now). Accruals that leave the
    /// visible total unchanged (muted accruals, an override absorbing
    /// the first point) also skip the dock write.
    public func ingest(
        decision: ChatFilter.Decision, chatID: String, openChatID: String?,
        visibleChatIDs: Set<String> = [], messageAt: Date? = nil
    ) {
        guard Self.shouldCount(
            decision: decision, chatID: chatID, openChatID: openChatID,
            visibleChatIDs: visibleChatIDs) else { return }
        let before = total
        seededIDs.remove(chatID)
        if let messageAt { accruedAt[chatID] = max(messageAt, accruedAt[chatID] ?? messageAt) }
        counts[chatID, default: 0] += 1
        if Self.isMutedSkip(decision) {
            mutedUnreadIDs.insert(chatID)
        } else {
            mutedUnreadIDs.remove(chatID)
        }
        if total != before {
            syncDock()
        }
    }

    /// Convenience: decide via ChatFilter (stateful meeting window),
    /// accrue, and return the decision so the caller reuses it for the
    /// banner (one decide per event — never double-claim the window).
    @discardableResult
    public func ingest(
        message: RealtimeMessage, chatDisplayName: String,
        ownerMRI: String?, rules: RulesConfig,
        meetingDedup: inout MeetingStartDedup, now: Date,
        openChatID: String?, teamsMutedChatIDs: Set<String> = [],
        dndActive: Bool = false, quietActive: Bool = false,
        snoozedChatIDs: Set<String> = [],
        visibleChatIDs: Set<String> = []
    ) -> ChatFilter.Decision {
        let decision = ChatFilter.decide(
            message: message, chatDisplayName: chatDisplayName,
            ownerMRI: ownerMRI, rules: rules,
            meetingDedup: &meetingDedup, now: now,
            teamsMutedChatIDs: teamsMutedChatIDs,
            dndActive: dndActive, quietActive: quietActive,
            snoozedChatIDs: snoozedChatIDs)
        ingest(
            decision: decision, chatID: message.chatID, openChatID: openChatID,
            visibleChatIDs: visibleChatIDs, messageAt: ChatListFormat.parse(message.time))
        return decision
    }

    /// Unread for one chat (0 when absent). Overrides floor the
    /// visible count at 1; the sidebar badge reads this in place.
    public func count(for chatID: String) -> Int {
        Self.visibleCount(
            auto: counts[chatID] ?? 0,
            overridden: overrides.contains(chatID))
    }

    /// True while a horizon override stands for this thread.
    public func isOverridden(chatID: String) -> Bool {
        overrides.contains(chatID)
    }

    /// True while the thread shows a badge (auto or override).
    public func isUnread(chatID: String) -> Bool {
        count(for: chatID) > 0
    }

    /// Pin a thread unread at its current tail (om-markunread): the
    /// badge shows at least 1 until the thread opens. Blank ids and
    /// re-marks are no-ops (no dock write); marking an already-unread
    /// thread still records the override (clearing stays one open) but
    /// skips the dock write when the visible total is unchanged. Never
    /// touches the chat list — the badge updates in place. `muted`
    /// (fid-lists D19) flags a manual mark on a muted chat so the
    /// override also stays out of the dock total.
    public func markUnread(chatID: String, muted: Bool = false) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard !overrides.contains(id) else { return }
        let before = total
        overrides.insert(id)
        overrideAt[id] = Date()
        if muted {
            mutedUnreadIDs.insert(id)
        }
        if total != before {
            syncDock()
        }
    }

    /// Seed counts accrued while another account was active (gap-g1
    /// switch handoff: the background roll-up drains here so the switch
    /// lands on unread N). Merges additively; blank ids and non-positive
    /// counts are dropped. Empty input is a no-op (no dock write).
    public func ingestBackground(_ counts: [String: Int]) {
        let clean = counts.filter {
            !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value > 0
        }
        guard !clean.isEmpty else { return }
        let before = total
        for (id, n) in clean {
            self.counts[id, default: 0] += n
        }
        if total != before {
            syncDock()
        }
    }

    /// Opening a chat marks it read: drops its auto count AND its
    /// horizon override AND its muted-unread flag, syncs the dock.
    /// Unknown ids are a no-op (no dock write). A lone muted flag
    /// (counts already drained) also clears silently with no dock
    /// write — the flag alone never moved the badge.
    public func markRead(chatID: String) {
        readAt[chatID] = Date()
        seededIDs.remove(chatID)
        accruedAt.removeValue(forKey: chatID)
        let hadCount = counts.removeValue(forKey: chatID) != nil
        let hadOverride = overrides.remove(chatID) != nil
        overrideAt.removeValue(forKey: chatID)
        mutedUnreadIDs.remove(chatID)
        guard hadCount || hadOverride else { return }
        syncDock()
    }

    /// Clear every chat (sign-out): counts, overrides, muted flags.
    /// Empty is a no-op (no dock write).
    public func markAllRead() {
        seededIDs.removeAll()
        readAt.removeAll()
        accruedAt.removeAll()
        guard !counts.isEmpty || !overrides.isEmpty else {
            mutedUnreadIDs.removeAll()
            return
        }
        counts.removeAll()
        overrides.removeAll()
        overrideAt.removeAll()
        mutedUnreadIDs.removeAll()
        syncDock()
    }

    /// Adopt the Teams read state from a fetched chat list (Unread
    /// filter after launch). An unread chat with no count gains 1 (Teams
    /// gives no exact number); a chat Teams now calls read drops a count
    /// only when the seed put it there. Live accruals, manual
    /// mark-unread overrides and chats opened here since their last
    /// message are never touched. Publishes and writes the dock only on
    /// a change.
    /// `asOf` = when the list fetch started (CHATSYNC): Teams "Mark as
    /// unread" bookmarks pin a chat unread here (even one opened here
    /// before the fetch), and an override older than the fetch clears
    /// once Teams says the chat is neither marked nor unread (read or
    /// cleared on another client). Overrides set after the fetch
    /// started stay (the answer predates them).
    public func seed(_ seeds: [UnreadSeed], asOf: Date = .distantPast) {
        var next = counts
        var muted = mutedUnreadIDs
        var seeded = seededIDs
        var marks = overrides
        for s in seeds where !s.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if s.markedUnread {
                if !marks.contains(s.chatID), (readAt[s.chatID] ?? .distantPast) < asOf {
                    marks.insert(s.chatID)
                    overrideAt[s.chatID] = asOf
                    if s.muted { muted.insert(s.chatID) }
                }
                continue
            }
            if !s.unread, marks.contains(s.chatID), (overrideAt[s.chatID] ?? .distantPast) < asOf {
                marks.remove(s.chatID)
                overrideAt.removeValue(forKey: s.chatID)
                if next[s.chatID] == nil { muted.remove(s.chatID) }
            }
            if s.unread {
                guard next[s.chatID] == nil else { continue }
                if let opened = readAt[s.chatID], opened >= (s.lastMessageAt ?? .distantFuture) { continue }
                next[s.chatID] = 1
                seeded.insert(s.chatID)
                if s.muted { muted.insert(s.chatID) }
            } else if seeded.contains(s.chatID) {
                next.removeValue(forKey: s.chatID)
                seeded.remove(s.chatID)
                if !overrides.contains(s.chatID) { muted.remove(s.chatID) }
            } else if let at = accruedAt[s.chatID], let last = s.lastMessageAt, last >= at,
                      !overrides.contains(s.chatID) {
                // Read elsewhere: Teams' horizon covers the newest
                // message counted live here.
                next.removeValue(forKey: s.chatID)
                accruedAt.removeValue(forKey: s.chatID)
                muted.remove(s.chatID)
            }
        }
        seededIDs = seeded
        guard next != counts || muted != mutedUnreadIDs || marks != overrides else { return }
        let before = total
        if marks != overrides { overrides = marks }
        if next != counts { counts = next }
        if muted != mutedUnreadIDs { mutedUnreadIDs = muted }
        if total != before { syncDock() }
    }

    private func syncDock() {
        dock.setBadge(badgeLabel)
    }
}
