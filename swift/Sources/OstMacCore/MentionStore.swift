// MentionStore.swift — om-mentions lane: threads that mention the owner.
//
// Membership accrues ONLY on owner mentions mined from the event's
// unstripped raw (Mention spans + `<at>` tags, MRI preferred with a
// display-name backup — same gate as the noisy-chat rules). Own
// messages never accrue (self-mentions notify nobody); the open chat
// never accrues (its bubbles are already visible); opening a chat
// clears it. The sidebar's Mentions row filters to these ids.
//
// om-mention-alerts: the flag count drives the Dock tile (nil at zero).
// Mute/DND/quiet never stop flagging (the row is the review queue, not
// an interruption — banners/sounds are what those suppress).
//
//   let mentions = MentionStore() // live dock badge
//   mentions.ingest(realtime: msg, ownName: conv.ownDisplayName,
//                   ownerMRI: mri, openChatID: openChatID)
//   mentions.markRead(chatID: id) // on open
//
// Threading: @MainActor (ObservableObject for the sidebar + NSApp dock).
// History is NOT scanned: like UnreadStore (which accrues live-only),
// threads mentioned before launch surface on the next mentioning
// event — `noteThread(chatID:messages:ownName:)` is the explicit seam
// for callers that already hold history (tests, future lanes).
// The dock sink is injectable for tests (FakeDockBadge records labels).
import Foundation

/// Chat ids with an unreviewed owner mention (sidebar filter source).
@MainActor
public final class MentionStore: ObservableObject {
    /// Mentioning chat ids. Cleared ids are absent, never stored empty.
    @Published public private(set) var mentionedIDs: Set<String> = []

    private let dock: any DockBadging

    /// Nonisolated so views can take a default `MentionStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(dock: (any DockBadging)? = nil) {
        self.dock = dock ?? SystemDockBadge()
    }

    /// Mentioning-thread count (the Mentions row badge).
    public var count: Int {
        mentionedIDs.count
    }

    /// Dock label for the current count: nil at zero (clears the tile).
    public var badgeLabel: String? {
        Self.badgeLabel(forCount: count)
    }

    /// Pure label: nil at zero, else the decimal count.
    nonisolated public static func badgeLabel(forCount count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }

    /// True when the chat is currently flagged.
    public func contains(chatID: String) -> Bool {
        mentionedIDs.contains(chatID)
    }

    /// Pure accrual gate: the event must mine an owner mention, must
    /// not be the owner's own message, must carry a non-blank chat id,
    /// and must not belong to the open chat. MRI matching prefers
    /// `ownerMRI` with a display-name backup (`ownName`); both blank
    /// still match nothing (fail closed — never flag the world when
    /// identity is unresolved).
    nonisolated public static func shouldFlag(
        message: RealtimeMessage, ownName: String?,
        ownerMRI: String?, openChatID: String?,
        visibleChatIDs: Set<String> = []
    ) -> Bool {
        let own = ownName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if visibleChatIDs.contains(message.chatID) { return false }
        if let open = openChatID, open == message.chatID { return false }
        if isOwnMessage(message, ownerMRI: ownerMRI, ownName: own) { return false }
        return Mentions.mentionsOwner(
            message.mentions, ownerMRI: ownerMRI, ownerDisplayName: own)
    }

    /// Flag one live event's chat when it mentions the owner. Own
    /// messages, open-chat events, and non-mentions are no-ops (no dock
    /// write); re-flagging an already-flagged chat is a no-op too.
    public func ingest(
        realtime message: RealtimeMessage, ownName: String?,
        ownerMRI: String?, openChatID: String?,
        visibleChatIDs: Set<String> = []
    ) {
        guard Self.shouldFlag(
            message: message, ownName: ownName,
            ownerMRI: ownerMRI, openChatID: openChatID,
            visibleChatIDs: visibleChatIDs)
        else { return }
        if mentionedIDs.insert(message.chatID).inserted {
            syncDock()
        }
    }

    /// Explicit history seam: flag `chatID` when any loaded message
    /// mines an owner mention. Blank ids and blank owners are no-ops
    /// (no dock write).
    public func noteThread(chatID: String, messages: [ChatMessage], ownName: String?) {
        guard !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard messages.contains(where: { $0.mentionsOwner(ownName: ownName) }) else { return }
        if mentionedIDs.insert(chatID).inserted {
            syncDock()
        }
    }

    /// Opening a chat clears its flag (mentions now visible).
    /// Unknown ids are a no-op (no dock write).
    public func markRead(chatID: String) {
        guard mentionedIDs.remove(chatID) != nil else { return }
        syncDock()
    }

    /// Clear every flag (sign-out). Empty is a no-op (no dock write).
    public func markAllRead() {
        guard !mentionedIDs.isEmpty else { return }
        mentionedIDs.removeAll()
        syncDock()
    }

    /// Demo/test seeding: adopt a canned flag set wholesale. Adopting
    /// the current set is a no-op (no dock write).
    public func adopt(_ ids: Set<String>) {
        guard mentionedIDs != ids else { return }
        mentionedIDs = ids
        syncDock()
    }

    private func syncDock() {
        dock.setBadge(badgeLabel)
    }

    /// Owner's own message? MRI preferred; display-name backup when the
    /// event carried no sender MRI. Blank identities never match
    /// (ChatFilter.isOwnMessage parity minus the configurable gate —
    /// the mention tracker always name-matches, like the mine gate).
    nonisolated static func isOwnMessage(
        _ message: RealtimeMessage, ownerMRI: String?, ownName: String
    ) -> Bool {
        if let ownerMRI, !ownerMRI.isEmpty,
           let sender = message.senderID, !sender.isEmpty
        {
            return sender.caseInsensitiveCompare(ownerMRI) == .orderedSame
        }
        let a = message.sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = ownName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && !b.isEmpty && a == b
    }
}
