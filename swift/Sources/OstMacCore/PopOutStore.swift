// PopOutStore.swift — e1-popout: pop-out chat registry.
//
// One chat id = max one pop-out window. The registry tracks which chats
// are visibly popped (the unread + Mentions open-chat parity set), caches
// one ConversationStore per popped chat for the session (re-pop restores
// without reload), and caches per-chat drafts (close loses nothing).
//
// Fan-out: `ingest(realtime:)` routes a live event to its pop-out store
// (the AppState feed calls this beside the main `isFor` guard — the main
// selection never moves for pop-out traffic). Send mirroring: `bind(main:)`
// wires both directions through `ConversationStore.onLocalSend`, so an
// own-bubble posted in either window appears in both timelines (upsert by
// id — the mirror never re-mirrors, so no echo loop).
//
//   let pops = PopOutStore()
//   pops.bind(main: conv)
//   if pops.pop(chatID: id) { openWindow(value: id) } // else focus it
//   pops.ingest(realtime: msg) // fan-out beside the main guard
//   pops.close(chatID: id) // red dot: visible drops, store+draft stay
import Combine
import Foundation

/// Popped-chat registry + per-chat stores + draft cache.
@MainActor
public final class PopOutStore: ObservableObject {
    /// Currently visible pop-outs (the unread/Mentions open-chat set).
    @Published public private(set) var poppedIDs: Set<String> = []
    /// Session store cache (chatID → store). Plain (never @Published):
    /// resolved during window-body eval, must not republish mid-render.
    public private(set) var stores: [String: ConversationStore] = [:]
    /// Per-chat draft cache (continuous save, close-proof).
    private var drafts: [String: String] = [:]
    private weak var main: ConversationStore?

    public init() {}

    /// Pure visible set: the main-open chat plus every popped chat.
    nonisolated public static func visibleChatIDs(
        open: String?, popped: Set<String>
    ) -> Set<String> {
        var out = popped
        if let open { out.insert(open) }
        return out
    }

    /// Visible set against the live registry.
    public func visibleChatIDs(open: String?) -> Set<String> {
        Self.visibleChatIDs(open: open, popped: poppedIDs)
    }

    /// The main-window store (send-mirror counterpart). Wires the main
    /// side and any stores already cached; `store(for:)` wires the rest.
    public func bind(main: ConversationStore) {
        self.main = main
        main.onLocalSend = { [weak self] bubble in
            self?.mirrorFromMain(bubble)
        }
        for (_, s) in stores {
            wireMirror(s)
        }
    }

    /// Pop a chat: true when newly popped, false when already popped
    /// (caller focuses the existing window) or the id is blank.
    @discardableResult
    public func pop(chatID: String) -> Bool {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !poppedIDs.contains(id) else { return false }
        _ = store(for: id) // window content exists before it renders
        poppedIDs.insert(id)
        return true
    }

    /// True while the chat has a visible pop-out window.
    public func isPopped(chatID: String) -> Bool {
        poppedIDs.contains(chatID)
    }

    /// Window closed (red dot): the chat leaves the visible set (unread
    /// + Mentions resume accruing) while its store and draft stay cached
    /// for the session — re-pop restores both with no reload.
    public func close(chatID: String) {
        poppedIDs.remove(chatID)
    }

    /// Cached store for a chat, created + mirror-wired on demand. Blank
    /// ids still resolve (callers fall back to the id as the name).
    public func store(for chatID: String) -> ConversationStore {
        if let s = stores[chatID] { return s }
        let s = ConversationStore()
        stores[chatID] = s
        wireMirror(s)
        return s
    }

    /// Live-event fan-out: routes to the popped store only. True when a
    /// visible pop-out consumed the event (caller refreshes Seen state).
    @discardableResult
    public func ingest(realtime message: RealtimeMessage) -> Bool {
        guard poppedIDs.contains(message.chatID),
              let s = stores[message.chatID]
        else { return false }
        s.ingest(realtime: message)
        return true
    }

    /// Cached draft for a chat ("" when none).
    public func draft(for chatID: String) -> String {
        drafts[chatID] ?? ""
    }

    /// Continuous draft save (blank ids are a no-op).
    public func saveDraft(_ text: String, for chatID: String) {
        let id = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        drafts[id] = text
    }

    /// Drop a cached draft (unknown ids are a no-op).
    public func purgeDraft(for chatID: String) {
        drafts.removeValue(forKey: chatID)
    }

    /// Mirror one pop-out store's local sends into the main timeline
    /// when the main window shows the same chat (no cross-talk).
    private func wireMirror(_ s: ConversationStore) {
        s.onLocalSend = { [weak self, weak s] bubble in
            guard let self, let s, let id = s.chatID else { return }
            guard self.main?.chatID == id else { return }
            self.main?.ingest(bubble, keepOwnership: true)
        }
    }

    /// Mirror a main-window local send into the popped store for the
    /// same chat (popped only — unpopped chats never gain bubbles).
    private func mirrorFromMain(_ bubble: ChatMessage) {
        guard let id = main?.chatID,
              poppedIDs.contains(id),
              let s = stores[id]
        else { return }
        s.ingest(bubble, keepOwnership: true)
    }
}
