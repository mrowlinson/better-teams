// SavedMessages.swift — e2-saved lane: cross-chat saved messages.
//
// Save any bubble from any chat/channel via the message menu; every save
// lands in ONE flat cross-chat collection (save-time order, newest-first)
// with a dedicated searchable view (SavedMessagesView). Local-first,
// per-account, persisted across relaunch.
//
// Shape precedent: PinnedMessages.swift (suite-injectable UserDefaults
// JSON, save-time snapshot + live-window resolve, sanitize, per-account
// key, menuTitle). Different axis: pins are a per-thread map with a
// per-thread strip; saved is ONE flat list. Two distinct stores — never
// merge pins into saved.
//
// Lane picks (stated here + pinned by SavedMessagesTests):
// - Menu label: `Save this message` / `Unsave` (fid-msgs D16: Teams
//   literal for save; unsave short form — Teams client unverified).
//   `Save…` ALREADY means
//   save-to-.txt-file in both bubble menus (MessageActions.saveBody) —
//   the toggle MUST stay literally distinct (inequality test), and the
//   file-export item is never renamed.
// - Search: in-memory token filter over snapshots reusing
//   LocalSearchStore.tokenize + its match semantics (lowercase alnum,
//   prefix-match, multi-term AND). No second tokenizer, no searcher
//   property, no RustCore reference anywhere in this file: offline by
//   construction (LocalSearchStore precedent).
// - Cap: 500 saves; oldest-save-first eviction (CallHistoryStore precedent).
// - Preview-off contract (Notifications.showPreview): snippets and row
//   previews render MessageNotifications.hiddenPreviewBody ("New message")
//   — never message content. Matching still runs offline over content
//   (rows stay findable by chat/sender/time); only displayed text redacts.
// - Jump: rows convert to SearchHit and ride the existing
//   App.jumpToMessage funnel (open chat + seek). Evicted/unknown ids stay
//   put, never conjure (pin-jump precedent: conv.seek no-ops off-window).
import Foundation
import Combine

/// One saved message: source coordinates (chat + optional team/channel +
/// message id) plus a save-time snapshot so the row still renders when
/// the bubble aged out of the loaded window. Live content wins when the
/// bubble is in the rows' `live` window.
public struct SavedMessage: Codable, Sendable, Equatable, Identifiable {
    /// Composite: message ids are thread-scoped on the wire, so the
    /// stable row identity is chat + message (never message alone).
    public var id: String { "\(chatID)\n\(messageID)" }
    public let chatID: String
    public let teamID: String?
    public let channelID: String?
    public let messageID: String
    public let sender: String
    public let preview: String
    public let content: String
    public let timestamp: String
    /// Save moment (seconds since epoch) — list order key.
    public let savedAt: Double

    public init(
        chatID: String, teamID: String? = nil, channelID: String? = nil,
        messageID: String, sender: String, preview: String,
        content: String, timestamp: String, savedAt: Double
    ) {
        self.chatID = chatID
        self.teamID = teamID
        self.channelID = channelID
        self.messageID = messageID
        self.sender = sender
        self.preview = preview
        self.content = content
        self.timestamp = timestamp
        self.savedAt = savedAt
    }

    /// Snapshot one bubble at save time.
    public static func from(
        chatID: String, teamID: String? = nil, channelID: String? = nil,
        message: ChatMessage, at: Date = Date()
    ) -> SavedMessage {
        SavedMessage(
            chatID: chatID, teamID: teamID, channelID: channelID,
            messageID: message.id, sender: message.sender,
            preview: SavedMessages.preview(for: message),
            content: MessageActions.copyText(for: message),
            timestamp: message.timestamp,
            savedAt: at.timeIntervalSince1970)
    }
}

/// Pure saved-messages helpers (store, view, and tests share them).
public enum SavedMessages {
    public nonisolated static let defaultsKey = "om.savedMessages.v1"
    /// Per-account key (d1-accounts): default keeps the legacy key.
    public static func key(for accountID: String) -> String {
        AccountProfile.key(defaultsKey, for: accountID)
    }
    /// Row preview width: one collapsed line, 80 chars + ellipsis
    /// (pin-strip parity).
    public static let previewMax = 80
    /// Collection cap (CallHistoryStore precedent): snapshots carry full
    /// content, so the list never exceeds this; the oldest save evicts.
    public static let cap = 500

    /// One-line row preview: exactly what the bubble shows (shortcodes
    /// expanded, same source as Copy), collapsed to one line. Reuses the
    /// pin-strip collapse — no second preview rule.
    public static func preview(for message: ChatMessage, max: Int = previewMax) -> String {
        PinnedMessages.preview(for: message, max: max)
    }

    /// Top-level context-menu label for the save toggle (fid-msgs D16:
    /// Teams "Save this message"). Deliberately NOT `Save…` (the
    /// file-export item): distinct literal, pinned by test.
    public static func menuTitle(isSaved: Bool) -> String {
        isSaved ? "Unsave" : "Save this message"
    }

    /// Displayed row text under the preview setting: OFF shows the shared
    /// generic body (never message content); ON shows the snippet.
    public static func displayPreview(snippet: String, showPreview: Bool) -> String {
        showPreview ? snippet : MessageNotifications.hiddenPreviewBody
    }

    /// One collection row: live bubble content when available (edits
    /// track), else the save-time snapshot. `isLive` marks the source.
    public struct SavedRow: Sendable, Equatable, Identifiable {
        public var id: String { "\(chatID)\n\(messageID)" }
        public let chatID: String
        public let teamID: String?
        public let channelID: String?
        public let messageID: String
        public let sender: String
        public let preview: String
        public let timestamp: String
        public let savedAt: Double
        public let isLive: Bool

        public init(
            chatID: String, teamID: String? = nil, channelID: String? = nil,
            messageID: String, sender: String, preview: String,
            timestamp: String, savedAt: Double, isLive: Bool
        ) {
            self.chatID = chatID
            self.teamID = teamID
            self.channelID = channelID
            self.messageID = messageID
            self.sender = sender
            self.preview = preview
            self.timestamp = timestamp
            self.savedAt = savedAt
            self.isLive = isLive
        }
    }

    /// Collection rows: saves in save-time order (newest-first), each
    /// resolved against the loaded window (live wins, snapshot falls
    /// back). The window usually holds the open chat only — other chats'
    /// rows render snapshots until their chat opens.
    public static func rows(
        saves: [SavedMessage], live: [ChatMessage]
    ) -> [SavedRow] {
        rows(saves: saves, live: live, index: MessageIndex(live))
    }

    /// Indexed rows (om-s6-renderparse): same rows, O(saves) against a
    /// body-eval `MessageIndex` (no per-save scan).
    public static func rows(
        saves: [SavedMessage], live: [ChatMessage], index: MessageIndex
    ) -> [SavedRow] {
        saves.sorted { $0.savedAt > $1.savedAt }.map { save in
            if let bubble = index.byID[save.messageID] {
                return SavedRow(
                    chatID: save.chatID, teamID: save.teamID,
                    channelID: save.channelID, messageID: save.messageID,
                    sender: bubble.sender, preview: preview(for: bubble),
                    timestamp: bubble.timestamp, savedAt: save.savedAt,
                    isLive: true)
            }
            return SavedRow(
                chatID: save.chatID, teamID: save.teamID,
                channelID: save.channelID, messageID: save.messageID,
                sender: save.sender,
                preview: save.preview.isEmpty ? "(no text)" : save.preview,
                timestamp: save.timestamp, savedAt: save.savedAt,
                isLive: false)
        }
    }

    /// Jump-funnel input for one row: the saved coordinates + snapshot
    /// preview. The caller (App.jumpToMessage) opens the chat and seeks;
    /// evicted/unknown ids stay put (seek no-ops off-window).
    public static func hit(for save: SavedMessage) -> SearchHit {
        SearchHit(
            messageID: save.messageID, chatID: save.chatID,
            teamID: save.teamID, channelID: save.channelID,
            sender: save.sender, timestamp: save.timestamp,
            preview: save.preview)
    }

    /// Jump target when the source chat is already open: the message id
    /// when the bubble is in the loaded window, else nil (caller stays
    /// put — never conjures a bubble). Blank ids never target.
    public static func jumpTarget(
        messageID: String, loaded: [ChatMessage]
    ) -> String? {
        let id = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return loaded.contains(where: { $0.id == id }) ? id : nil
    }

    /// Offline match over one save's snapshot (sender + content +
    /// preview): every term prefix-matches some token (multi-term AND).
    /// Tokenizer is LocalSearchStore's — this file defines none.
    public static func matches(_ save: SavedMessage, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let tokens = LocalSearchStore.tokenize(
            "\(save.sender) \(save.content) \(save.preview)")
        for term in terms {
            guard tokens.contains(where: { $0.hasPrefix(term) }) else {
                return false
            }
        }
        return true
    }

    /// Query filter: LocalSearchStore.tokenize semantics (lowercase alnum,
    /// prefix-match, multi-term AND). Blank queries restore the full list.
    public static func filter(_ saves: [SavedMessage], query: String) -> [SavedMessage] {
        let terms = LocalSearchStore.tokenize(query)
        guard !terms.isEmpty else { return saves }
        return saves.filter { matches($0, terms: terms) }
    }

    /// Best-effort decode: corrupt payloads yield empty (never throw).
    public static func decode(_ data: Data?) -> [SavedMessage] {
        guard let data,
              let raw = try? JSONDecoder().decode([SavedMessage].self, from: data)
        else { return [] }
        return sanitize(raw)
    }

    public static func encode(_ saves: [SavedMessage]) -> Data? {
        try? JSONEncoder().encode(sanitize(saves))
    }

    /// Drop blank chat/message ids, dedupe by chat+message (earliest save
    /// wins), sort newest-first, trim to cap (oldest-save-first eviction).
    public static func sanitize(_ saves: [SavedMessage]) -> [SavedMessage] {
        var seen = Set<String>()
        var kept: [SavedMessage] = []
        for save in saves.sorted(by: { $0.savedAt < $1.savedAt }) {
            let cid = save.chatID.trimmingCharacters(in: .whitespacesAndNewlines)
            let mid = save.messageID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cid.isEmpty, !mid.isEmpty else { continue }
            guard seen.insert("\(cid)\n\(mid)").inserted else { continue }
            kept.append(save)
        }
        kept.sort { $0.savedAt > $1.savedAt }
        if kept.count > cap {
            kept.removeLast(kept.count - cap)
        }
        return kept
    }
}

/// Cross-chat saved collection, persisted locally. Main-actor (SwiftUI-owned).
@MainActor
public final class SavedMessageStore: ObservableObject {
    /// Every save, newest-first. Flat — never a per-thread map.
    @Published public private(set) var saves: [SavedMessage] = []
    /// Live search text (the view binds its field here; blank = all).
    @Published public var query = ""

    /// Backing defaults; nil = memory-only (demo: never the real saves).
    private let defaults: UserDefaults?
    private let key: String

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults? = .standard, key: String = SavedMessages.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
        _saves = Published(initialValue: SavedMessages.decode(defaults?.data(forKey: key)))
        _query = Published(initialValue: "")
    }

    /// True when this chat's bubble is saved. Blank ids hold none.
    public func isSaved(chatID: String?, messageID: String) -> Bool {
        guard let cid = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cid.isEmpty
        else { return false }
        let mid = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return false }
        return saves.contains(where: { $0.chatID == cid && $0.messageID == mid })
    }

    /// Save one bubble (snapshot at save time). Blank ids and re-saves
    /// are no-ops (no duplicate, no rewrite). Past the cap, the oldest
    /// save evicts.
    public func save(
        chatID: String?, teamID: String? = nil, channelID: String? = nil,
        message: ChatMessage, at: Date = Date()
    ) {
        guard let cid = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cid.isEmpty
        else { return }
        let mid = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return }
        guard !saves.contains(where: { $0.chatID == cid && $0.messageID == mid }) else {
            return
        }
        var next = saves
        next.append(SavedMessage.from(
            chatID: cid, teamID: teamID, channelID: channelID,
            message: message, at: at))
        saves = SavedMessages.sanitize(next)
        persist()
    }

    /// Unsave one bubble. Unknown ids are a no-op (no write).
    public func unsave(chatID: String?, messageID: String) {
        guard let cid = chatID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cid.isEmpty
        else { return }
        let mid = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mid.isEmpty else { return }
        let before = saves.count
        saves.removeAll(where: { $0.chatID == cid && $0.messageID == mid })
        guard saves.count != before else { return }
        persist()
    }

    /// Toggle one bubble's save (the context-menu action).
    public func toggle(
        chatID: String?, teamID: String? = nil, channelID: String? = nil,
        message: ChatMessage, at: Date = Date()
    ) {
        if isSaved(chatID: chatID, messageID: message.id) {
            unsave(chatID: chatID, messageID: message.id)
        } else {
            save(
                chatID: chatID, teamID: teamID, channelID: channelID,
                message: message, at: at)
        }
    }

    /// Saves matching the live query (blank = all), newest-first.
    public func filtered() -> [SavedMessage] {
        SavedMessages.filter(saves, query: query)
    }

    /// Collection rows for the current query (live window resolves).
    public func rows(live: [ChatMessage]) -> [SavedMessages.SavedRow] {
        SavedMessages.rows(saves: filtered(), live: live)
    }

    /// Adopt saves wholesale (demo seeding + tests).
    public func adopt(_ saves: [SavedMessage]) {
        self.saves = SavedMessages.sanitize(saves)
        persist()
    }

    /// Drop every save (tests only).
    public func clearAll() {
        guard !saves.isEmpty else { return }
        saves.removeAll()
        persist()
    }

    private func persist() {
        defaults?.set(SavedMessages.encode(saves), forKey: key)
    }
}
