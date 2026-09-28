// ActivityStore.swift — e1-activity: notification history + mentions center.
//
// In-app feed of newest-first items (owner mentions, channel blasts,
// replies-to-owner, reaction deltas on own messages, missed calls),
// each reviewable (dismiss), persisted across relaunch (capped
// UserDefaults JSON, CallHistoryStore precedent), and tappable to
// jump to the message via the search `seek`/`jumpTargetID` funnel.
//
// Ingest is live-only (like MentionStore/UnreadStore): history is NOT
// scanned — `noteHistory` is the explicit seam for callers that
// already hold messages (tests, future lanes).
//
// Reaction contract (i): counts-only on every path (ReactionCount
// carries no reactor identity), so reaction items are count-delta
// ("New reaction 👍×3 on your message") with an UNKNOWN actor —
// `actor` is empty and no sender string is ever shown (pinned).
//
// Mention coupling: kind `.mention` shares review state with
// MentionStore both directions — opening a chat calls
// `markChatReviewed` alongside `MentionStore.markRead`, and reviewing
// the last unreviewed mention for a chat fires
// `onMentionFlagsCleared` (App wires it to `markRead`). Channel
// blasts never held a MentionStore flag, so they never fire the hook.
// The Dock tile stays owned by MentionStore (unreviewed mentions only).
//
//   let activity = ActivityStore()
//   activity.onMentionFlagsCleared = { mentions.markRead(chatID: $0) }
//   activity.ingest(realtime: msg, ownName: conv.ownDisplayName,
//                   ownerMRI: mri, openChatID: openChatID, chatName: name)
//
// Threading: @MainActor (ObservableObject for the feed + center).
import Foundation

/// Feed item kind. Raw values persist in UserDefaults JSON.
public enum ActivityKind: String, Codable, Sendable, Equatable {
    case mention
    case channelBlast
    case reply
    case reaction
    case missedCall

    /// SF Symbol for the feed row.
    public var systemImage: String {
        switch self {
        case .mention: "at"
        case .channelBlast: "megaphone"
        case .reply: "arrowshape.turn.up.left"
        case .reaction: "face.smiling"
        case .missedCall: "phone.arrow.down.left.fill"
        }
    }

    /// VoiceOver word.
    public var label: String {
        switch self {
        case .mention: "Mention"
        case .channelBlast: "Channel mention"
        case .reply: "Reply"
        case .reaction: "Reaction"
        case .missedCall: "Missed call"
        }
    }
}

/// One feed item. `at` is a unix-second stamp (UTC, DST-proof).
/// `messageID` is nil for missed calls (no bubble to land on);
/// `actor` is empty for reactions (unknown — never show a sender).
public struct ActivityItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: ActivityKind
    public let chatID: String
    public let messageID: String?
    public let actor: String
    public let chatName: String
    public var snippet: String
    public let at: UInt64
    public var reviewed: Bool
    /// Missed calls: the caller's id (CallRecord.peer) for presence and
    /// Call Back. Optional so persisted feeds without it still decode.
    public let callerID: String?

    public init(
        kind: ActivityKind, chatID: String, messageID: String? = nil,
        actor: String = "", chatName: String = "", snippet: String = "",
        at: UInt64, reviewed: Bool = false, id: String? = nil,
        callerID: String? = nil
    ) {
        self.callerID = callerID
        self.kind = kind
        self.chatID = chatID
        self.messageID = messageID
        self.actor = actor
        self.chatName = chatName
        self.snippet = snippet
        self.at = at
        self.reviewed = reviewed
        self.id = id
            ?? Self.makeID(kind: kind, chatID: chatID, messageID: messageID)
    }

    /// Stable dedupe id: kind + chat + message (missed calls pass the
    /// call id as the message slot). Reviewed items keep their ids, so
    /// re-ingest never resurrects.
    public static func makeID(
        kind: ActivityKind, chatID: String, messageID: String?
    ) -> String {
        "\(kind.rawValue):\(chatID):\(messageID ?? "-")"
    }

    /// Actor for rows: nil for reactions (unknown actor — the row shows
    /// the kind title instead of a sender string).
    public var actorDisplayName: String? {
        kind == .reaction ? nil : actor
    }

    /// Row title when no actor is shown (reaction-only today).
    public var rowTitle: String {
        switch kind {
        case .reaction: "New reaction"
        default: actor
        }
    }

    /// Start time: locale short clock today, else clock + "22 Sep" (CallRecord rules).
    public var displayTime: String {
        CallRecord.displayTime(
            for: Date(timeIntervalSince1970: TimeInterval(at)))
    }

    /// Generic snippet when Settings preview is OFF (never message
    /// content — NcDelivery redaction precedent).
    public static let redactedSnippet = MessageNotifications.hiddenPreviewBody

    /// Snippet honoring the preview toggle (pure, pinned by tests).
    public static func displaySnippet(
        _ item: ActivityItem, showPreview: Bool
    ) -> String {
        showPreview ? item.snippet : redactedSnippet
    }
}

/// Jump target for one feed row: open the chat, land on the message.
/// `canJump` is false for threadless missed calls (never conjure).
public struct ActivityTarget: Sendable, Equatable {
    public let chatID: String
    public let messageID: String?

    public init(chatID: String, messageID: String?) {
        self.chatID = chatID
        self.messageID = messageID
    }

    public var canJump: Bool {
        !chatID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Live activity feed + mentions-center data. Newest first, capped.
@MainActor
public final class ActivityStore: ObservableObject {
    /// Unreviewed newest-first (the feed's rows; stable ids, diffed).
    @Published public private(set) var items: [ActivityItem] = []
    /// False after `seedDemo` (demo feed is in-memory only).
    private var persists = true

    /// Fired when the last unreviewed `.mention` for a chat is
    /// reviewed (App clears the MentionStore flag — no orphan flags).
    public var onMentionFlagsCleared: ((String) -> Void)?

    public nonisolated static let defaultsKey = "omActivityV1"
    /// Per-account key (d1-accounts): default keeps the legacy key.
    nonisolated public static func key(for accountID: String) -> String {
        AccountProfile.key(defaultsKey, for: accountID)
    }
    public static let maxItems = 200

    private let defaults: UserDefaults
    private let key: String
    /// Last-seen reaction totals per message (`chatID\0messageID`).
    /// Baseline on first sight (no item); deltas on own messages emit.
    private var reactionTotals: [String: Int] = [:]

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults = .standard,
        key: String = ActivityStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
        // Wrapper init (init-time only): seeds the @Published storage
        // directly, no publish.
        self._items = Published(
            initialValue: Self.load(defaults: defaults, key: key))
    }

    // MARK: - Derived

    /// Unreviewed newest-first (feed + center rows).
    public var visibleItems: [ActivityItem] {
        items.filter { !$0.reviewed }
    }

    /// Unreviewed owner mentions + channel blasts (center rows).
    public var mentionItems: [ActivityItem] {
        visibleItems.filter { $0.kind == .mention || $0.kind == .channelBlast }
    }

    public var unreviewedCount: Int {
        items.reduce(0) { $0 + ($1.reviewed ? 0 : 1) }
    }

    /// Total persisted rows (reviewed included) — cap probe for tests.
    public var storedCount: Int { items.count }

    public func item(id: String) -> ActivityItem? {
        items.first { $0.id == id }
    }

    public func hasUnreviewedMentions(chatID: String) -> Bool {
        visibleItems.contains {
            $0.chatID == chatID && $0.kind == .mention
        }
    }

    /// Jump target for one row id; nil when unknown/evicted (callers
    /// stay put — the `jumpToPin`/`jumpToQuote` precedent).
    public func jumpTarget(id: String) -> ActivityTarget? {
        guard let item = item(id: id) else { return nil }
        return ActivityTarget(chatID: item.chatID, messageID: item.messageID)
    }

    // MARK: - Live ingest

    /// Flag one live event: owner mention → `.mention`, channel blast →
    /// `.channelBlast`, reply-to-owner → `.reply`. Own messages,
    /// open-chat events, visible-chat events (popped windows count as
    /// open — e1-popout parity with MentionStore), blank chat ids, and
    /// already-known message ids are no-ops (reviewed items never
    /// resurrect).
    public func ingest(
        realtime message: RealtimeMessage, ownName: String?,
        ownerMRI: String?, openChatID: String?, chatName: String,
        at: Date = Date(), visibleChatIDs: Set<String> = []
    ) {
        let chatID = message.chatID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !chatID.isEmpty else { return }
        // core-a: missed-call events (`Event/Call` partlist) land as
        // missed-call rows carrying the caller id — open chats included
        // (the timeline never renders call events). Never a mention.
        if CallEventPayload.isCallEvent(message.messageType) {
            let own = (ownName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Self.isOwnMessage(message, ownerMRI: ownerMRI, ownName: own),
                  let caller = CallEventPayload.missedCaller(
                    raw: message.raw ?? "", senderID: message.senderID,
                    ownerMRI: ownerMRI)
            else { return }
            let actor = caller.name.isEmpty ? message.sender : caller.name
            noteMissedCall(
                chatID: message.chatID, eventID: message.msgId,
                callerID: caller.identity, actor: actor == "?" ? "" : actor,
                chatName: chatName, at: at)
            return
        }
        if let open = openChatID, open == message.chatID { return }
        if visibleChatIDs.contains(message.chatID) { return }
        let own = (ownName ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        if Self.isOwnMessage(
            message, ownerMRI: ownerMRI, ownName: own)
        { return }
        let mined = message.mentions
        let ownerHit = Mentions.mentionsOwner(
            mined, ownerMRI: ownerMRI, ownerDisplayName: own)
        let blastHit = !ownerHit
            && Mentions.mentionsChannelOrEveryone(mined)
        let replyHit = Self.isReplyToOwner(
            raw: message.raw, ownName: own)
        guard ownerHit || blastHit || replyHit else { return }
        let kind: ActivityKind =
            ownerHit ? .mention : (blastHit ? .channelBlast : .reply)
        let id = ActivityItem.makeID(
            kind: kind, chatID: message.chatID, messageID: message.msgId)
        guard !items.contains(where: { $0.id == id }) else { return }
        insert(ActivityItem(
            kind: kind, chatID: message.chatID, messageID: message.msgId,
            actor: message.sender, chatName: chatName,
            snippet: Self.snippet(for: message), at: Self.stamp(at)))
    }

    /// Reaction totals for one message: first sight records the
    /// baseline (no item); a larger total on an OWN message upserts the
    /// single reaction item (actor unknown — never a sender string).
    /// Unknown/nil ownership and non-positive deltas only move the
    /// baseline. Reviewed reaction items never resurrect (the new total
    /// just becomes the baseline for the next delta).
    public func noteReaction(
        chatID: String, messageID: String, reactions: [ReactionCount],
        chatName: String, isOwnMessage: Bool?, at: Date = Date()
    ) {
        let total = reactions.reduce(0) { $0 + $1.count }
        let key = "\(chatID)\0\(messageID)"
        let previous = reactionTotals[key]
        reactionTotals[key] = total
        // Strict delta: first sight only sets the baseline (a lone
        // total can't prove a change — it may be stale counts on a
        // replayed event). Callers seed baselines from loaded bubbles
        // so open-chat deltas stay exact (see `seedBaseline`).
        guard let previous, total > previous, isOwnMessage == true else { return }
        let id = ActivityItem.makeID(
            kind: .reaction, chatID: chatID, messageID: messageID)
        if let i = items.firstIndex(where: { $0.id == id }) {
            if items[i].reviewed { return }
            items[i].snippet = Self.reactionSnippet(
                reactions: reactions, total: total, chatName: chatName)
            save()
            return
        }
        insert(ActivityItem(
            kind: .reaction, chatID: chatID, messageID: messageID,
            chatName: chatName,
            snippet: Self.reactionSnippet(
                reactions: reactions, total: total, chatName: chatName),
            at: Self.stamp(at)))
    }

    /// Seed one reaction baseline from a loaded bubble's counts (App
    /// calls this for the open chat before `noteReaction`, so the
    /// delta measures the event against the pre-event bubble — never
    /// overwritten by callers once an event has moved it).
    public func seedBaseline(chatID: String, messageID: String, total: Int) {
        let key = "\(chatID)\0\(messageID)"
        if reactionTotals[key] == nil { reactionTotals[key] = total }
    }

    /// Missed-call ingest (CallHistoryStore hook): missed records emit,
    /// connected legs are no-ops. No message id (nothing to land on —
    /// the jump opens the chat only); threadless rows carry an empty
    /// chatID (their target reports `canJump == false`).
    public func noteCallRecord(_ record: CallRecord, chatName: String) {
        guard record.isMissed else { return }
        let id = ActivityItem.makeID(
            kind: .missedCall, chatID: record.thread,
            messageID: record.id)
        guard !items.contains(where: { $0.id == id }) else { return }
        // core-a: the same call may already be listed from its
        // `Event/Call` chat event (same caller, near-same time).
        guard !hasMissedCall(callerID: record.peer, at: record.startedAt) else { return }
        insert(ActivityItem(
            kind: .missedCall, chatID: record.thread,
            messageID: nil, actor: record.displayName,
            chatName: chatName.isEmpty ? record.displayName : chatName,
            snippet: "Missed call · \(record.displayTime)",
            at: record.startedAt, id: id,
            callerID: record.peer.isEmpty ? nil : record.peer))
    }

    /// Missed-call row from a chat `Event/Call` event (core-a). The
    /// caller id rides `callerID` (MRI, CallRecord.peer parity). Known
    /// event ids and a same-caller row within `missedCallWindow`
    /// seconds (the CallRecord path saw it first) are no-ops.
    public func noteMissedCall(
        chatID: String, eventID: String, callerID: String, actor: String,
        chatName: String, at: Date = Date()
    ) {
        let stamp = Self.stamp(at)
        guard !hasMissedCall(callerID: callerID, at: stamp) else { return }
        let when = CallRecord.displayTime(for: at)
        insert(ActivityItem(
            kind: .missedCall, chatID: chatID, messageID: nil,
            actor: actor, chatName: chatName.isEmpty ? actor : chatName,
            snippet: "Missed call · \(when)", at: stamp,
            id: ActivityItem.makeID(kind: .missedCall, chatID: chatID, messageID: eventID),
            callerID: callerID))
    }

    /// Seconds within which two missed-call rows for one caller are the
    /// same call (invitation stamp vs chat-event arrival).
    public nonisolated static let missedCallWindow: UInt64 = 180

    private func hasMissedCall(callerID: String, at: UInt64) -> Bool {
        let want = callerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !want.isEmpty else { return false }
        return items.contains { item in
            guard item.kind == .missedCall,
                  let c = item.callerID?.lowercased(), c == want
            else { return false }
            let gap = item.at > at ? item.at - at : at - item.at
            return gap <= Self.missedCallWindow
        }
    }

    /// Explicit history seam: owner mentions (display-name backup) and
    /// replies whose `reply_to` parent is the owner's. Blank ids are
    /// no-ops; known ids never resurrect.
    public func noteHistory(
        chatID: String, messages: [ChatMessage], ownName: String?,
        chatName: String
    ) {
        guard !chatID.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else { return }
        let own = (ownName ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in messages {
            if message.mentionsOwner(ownName: ownName),
               !Self.isOwnHistoryMessage(message, ownName: own)
            {
                insertUnlessKnown(ActivityItem(
                    kind: .mention, chatID: chatID,
                    messageID: message.id, actor: message.sender,
                    chatName: chatName,
                    snippet: Self.historySnippet(message),
                    at: Self.stamp(Date())))
                continue
            }
            if let parentID = message.reply_to,
               let parent = byID[parentID],
               Self.isOwnHistoryMessage(parent, ownName: own),
               !Self.isOwnHistoryMessage(message, ownName: own)
            {
                insertUnlessKnown(ActivityItem(
                    kind: .reply, chatID: chatID, messageID: message.id,
                    actor: message.sender, chatName: chatName,
                    snippet: Self.historySnippet(message),
                    at: Self.stamp(Date())))
            }
        }
    }

    // MARK: - Review

    /// Dismiss one item. Reviewing the last unreviewed `.mention` for
    /// its chat fires `onMentionFlagsCleared` (shared review state with
    /// MentionStore). Unknown ids are a no-op.
    public func markReviewed(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[i].reviewed else { return }
        items[i].reviewed = true
        let chatID = items[i].chatID
        let wasMention = items[i].kind == .mention
        save()
        if wasMention, !hasUnreviewedMentions(chatID: chatID) {
            onMentionFlagsCleared?(chatID)
        }
    }

    /// Undo a review (Activity context menu "Mark as Unread"). Unknown
    /// or already-unreviewed ids are a no-op.
    public func markUnreviewed(id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[i].reviewed else { return }
        items[i].reviewed = false
        save()
    }

    /// Opening a chat reviews its items (called alongside
    /// `MentionStore.markRead`). Fires the flag-clear hook when the
    /// chat held unreviewed mentions.
    public func markChatReviewed(chatID: String) {
        let hadMentions = hasUnreviewedMentions(chatID: chatID)
        var changed = false
        for i in items.indices where items[i].chatID == chatID {
            guard !items[i].reviewed else { continue }
            items[i].reviewed = true
            changed = true
        }
        guard changed else { return }
        save()
        if hadMentions { onMentionFlagsCleared?(chatID) }
    }

    /// Clear the whole feed (reviewed rows included). Empty is a no-op.
    public func markAllReviewed() {
        guard !items.isEmpty else { return }
        let chats = Set(items.lazy.filter { !$0.reviewed && $0.kind == .mention }.map(\.chatID))
        items.removeAll()
        reactionTotals.removeAll()
        save()
        for chatID in chats { onMentionFlagsCleared?(chatID) }
    }

    // MARK: - Reply miner (live path)

    /// Parent author of a `<quote author="…" guid="…">` block, if any
    /// (host mirror of core's history `reply_to` mining — the live
    /// `RealtimeMessage` carries no `reply_to` field).
    nonisolated public static func quoteParentAuthor(raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let re = try? NSRegularExpression(
            pattern: #"<quote\b[^>]*\bauthor\s*=\s*"([^"]+)""#,
            options: .caseInsensitive)
        else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(
            in: raw, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Parent message id of a `<quote … guid="…">` block, if any.
    nonisolated public static func quoteParentGuid(raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let re = try? NSRegularExpression(
            pattern: #"<quote\b[^>]*\bguid\s*=\s*"([^"]+)""#,
            options: .caseInsensitive)
        else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(
            in: raw, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Live reply-to-owner: the quote block names the owner (display
    /// name, trimmed, case-insensitive). Blank owners never match.
    nonisolated public static func isReplyToOwner(
        raw: String?, ownName: String
    ) -> Bool {
        let want = ownName.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        guard !want.isEmpty else { return false }
        guard let author = quoteParentAuthor(raw: raw)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return author == want
    }

    // MARK: - Internals

    /// Owner's own live event? MRI preferred; display-name backup when
    /// the event carried no sender MRI (MentionStore parity).
    nonisolated static func isOwnMessage(
        _ message: RealtimeMessage, ownerMRI: String?, ownName: String
    ) -> Bool {
        if let ownerMRI, !ownerMRI.isEmpty,
           let sender = message.senderID, !sender.isEmpty
        {
            return sender.caseInsensitiveCompare(ownerMRI) == .orderedSame
        }
        let a = message.sender.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        let b = ownName.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && !b.isEmpty && a == b
    }

    /// Owner's own history bubble? Display-name compare (history
    /// carries no sender MRI); `isOwn` wins when stamped.
    nonisolated static func isOwnHistoryMessage(
        _ message: ChatMessage, ownName: String
    ) -> Bool {
        if message.isOwn { return true }
        let a = message.sender.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        let b = ownName.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && !b.isEmpty && a == b
    }

    /// Feed snippet for a live event: stripped text (single line,
    /// capped), never the raw HTML.
    nonisolated static func snippet(for message: RealtimeMessage) -> String {
        cap(message.text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Feed snippet for a history bubble (same strip rules).
    nonisolated static func historySnippet(_ message: ChatMessage) -> String {
        cap(MessageRender.stripTags(message.content)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Reaction snippet: top emoji + total, actor unknown by design.
    nonisolated static func reactionSnippet(
        reactions: [ReactionCount], total: Int, chatName: String
    ) -> String {
        let top = reactions.max(by: { $0.count < $1.count })?.emoji ?? "🎉"
        if chatName.isEmpty {
            return "New reaction \(top)×\(total) on your message"
        }
        return "New reaction \(top)×\(total) on your message in \(chatName)"
    }

    nonisolated private static func cap(_ text: String, limit: Int = 140) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func stamp(_ date: Date) -> UInt64 {
        UInt64(date.timeIntervalSince1970)
    }

    private func insert(_ item: ActivityItem) {
        insertUnlessKnown(item)
    }

    private func insertUnlessKnown(_ item: ActivityItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.insert(item, at: 0)
        if items.count > Self.maxItems {
            items = Array(items.prefix(Self.maxItems))
        }
        save()
    }

    /// Offline demo feed (mentions, replies, a reaction, a channel
    /// announcement and 1:1 missed calls). Each row is built from the demo message it opens
    /// (same id, sender, text and time), so the row matches the landed
    /// bubble. In-memory only — demo never touches the persisted list.
    public func seedDemo(now: Date = DemoClock.now) {
        // Demo reviews stay in memory: never persist canned rows over
        // the account's real feed.
        persists = false
        func message(_ chatID: String, _ id: String) -> ChatMessage? {
            DemoData.messages(for: chatID).first { $0.id == id }
        }
        func stamp(_ m: ChatMessage?) -> UInt64 {
            guard let m, let d = ChatListFormat.parse(m.timestamp) else { return Self.stamp(now) }
            return Self.stamp(d)
        }
        var feed: [ActivityItem] = []
        let showcase = DemoData.name(for: DemoData.showcaseID) ?? "Showcase"
        if let m = message(DemoData.showcaseID, "sc-1") {
            feed.append(ActivityItem(
                kind: .mention, chatID: DemoData.showcaseID, messageID: m.id,
                actor: m.sender, chatName: showcase,
                snippet: Self.historySnippet(m), at: stamp(m)))
        }
        if let m = message(DemoData.avaID, DemoData.avaReplyID) {
            feed.append(ActivityItem(
                kind: .reply, chatID: DemoData.avaID, messageID: m.id,
                actor: m.sender, chatName: m.sender,
                snippet: Self.historySnippet(m), at: stamp(m)))
        }
        if let m = message(DemoData.showcaseID, "sc-3") {
            let total = m.reactions.reduce(0) { $0 + $1.count }
            feed.append(ActivityItem(
                kind: .reaction, chatID: DemoData.showcaseID, messageID: m.id,
                chatName: showcase,
                snippet: Self.reactionSnippet(reactions: m.reactions, total: total, chatName: showcase),
                at: stamp(m)))
        }
        if let m = message(DemoData.richID, "rich-5") {
            feed.append(ActivityItem(
                kind: .mention, chatID: DemoData.richID, messageID: m.id,
                actor: m.sender, chatName: DemoData.name(for: DemoData.richID) ?? "",
                snippet: Self.historySnippet(m), at: stamp(m)))
        }
        // Shipping channel: mentions, a reply to the owner's post and a
        // channel-wide announcement.
        let shipping = DemoTeams.threadedChannelID
        let posts: [(String, ActivityKind)] = [
            ("ship-q2", .mention), ("ship-q3-r1", .mention), ("ship-p0", .channelBlast), ("ship-p3-r1", .reply),
        ]
        for (id, kind) in posts {
            guard let m = message(shipping, id) else { continue }
            feed.append(ActivityItem(
                kind: kind, chatID: shipping, messageID: m.id, actor: m.sender,
                chatName: "Engineering > Shipping", snippet: Self.historySnippet(m), at: stamp(m),
                reviewed: kind != .mention))
        }
        // A 1:1 call carries its chat thread and the caller's id (as
        // `noteCallRecord` does), so the card offers Message + presence.
        feed.append(ActivityItem(
            kind: .missedCall, chatID: DemoData.avaID,
            messageID: nil, actor: "Ava Lindqvist",
            chatName: "Ava Lindqvist", snippet: "Missed call",
            at: Self.stamp(now) - 3600, id: "missedCall:-:demo-missed",
            callerID: "demo-u-ava"))
        feed.append(ActivityItem(
            kind: .missedCall, chatID: DemoData.tomID,
            messageID: nil, actor: "Tom Becker",
            chatName: "Tom Becker", snippet: "Missed call",
            at: Self.stamp(now) - 19 * 3600, reviewed: true, id: "missedCall:-:demo-missed-tom",
            callerID: "demo-u-tom"))
        items = feed.sorted { $0.at > $1.at }
    }

    // MARK: - Persistence

    private func save() {
        guard persists else { return }
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }

    nonisolated static func load(defaults: UserDefaults, key: String) -> [ActivityItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ActivityItem].self, from: data)) ?? []
    }

    // MARK: - Empty-state copy (moved verbatim from ActivityViews.swift
    // in the scratch-ui rebuild; pinned by ActivityTests).

    /// Feed empty-state copy (single source).
    public static let feedEmptyImage = "bell"
    public static let feedEmptyTitle = "No new activity"
    public static let feedEmptyMessage =
        "Mentions, replies, reactions, and missed calls will appear here."

    /// Mentions empty-state copy (single source).
    public static let mentionsEmptyImage = "at"
    public static let mentionsEmptyTitle = "No mentions"
    public static let mentionsEmptyMessage =
        "Every time someone mentions you — in any chat or channel — it lands here for review."
}
