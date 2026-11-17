// MessageSelection.swift — the keyboard-selected message (C8c).
//
// Up/Down move it through the timeline's messages, Esc clears it; the
// Conversation menu's message actions work on it. One per timeline
// (owned by its `TimelineActions`); the window's services point at the
// focused timeline's actions. Pure step logic, unit-tested.
import Foundation

/// The timeline keyboard selection: which conversation's which message.
@MainActor
@Observable
final class KeyboardMessageSelection {
    private(set) var chatID: String?
    private(set) var messageID: String?
    /// The owning timeline re-renders the old and new rows.
    var onChange: (() -> Void)?

    var selected: (chatID: String, messageID: String)? {
        guard let c = chatID, let m = messageID else { return nil }
        return (c, m)
    }

    func select(chatID: String, messageID: String) {
        guard self.chatID != chatID || self.messageID != messageID else { return }
        self.chatID = chatID
        self.messageID = messageID
        onChange?()
    }

    /// Step through `ids` (top to bottom, messages only): from nothing,
    /// Down takes the first and Up the last; the ends clamp.
    func move(chatID: String, in ids: [String], direction: Int) {
        guard let next = Self.nextID(in: ids, current: messageID, direction: direction) else { return }
        select(chatID: chatID, messageID: next)
    }

    func clear() {
        guard chatID != nil || messageID != nil else { return }
        chatID = nil
        messageID = nil
        onChange?()
    }

    /// Pure step (unit-tested): nil ids or a no-op stay nil.
    static func nextID(in ids: [String], current: String?, direction: Int) -> String? {
        guard !ids.isEmpty, direction != 0 else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else {
            return direction > 0 ? ids.first : ids.last
        }
        let j = min(max(i + (direction > 0 ? 1 : -1), 0), ids.count - 1)
        guard j != i else { return nil }
        return ids[j]
    }
}
