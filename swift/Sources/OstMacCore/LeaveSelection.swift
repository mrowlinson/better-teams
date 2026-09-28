// LeaveSelection.swift — om-leave-block lane: selection fallback on removal.
//
// Pure neighbor rule (the App target can't be unit-tested, so the policy
// lives here next to SelectionRestore): leaving/blocking must never strand
// the selection on the dead thread. Untouched selections stay put; a
// removed selection lands on the next row, else the previous, else nothing.
import Foundation

public enum LeaveSelection {
    /// Selection after `removedID` leaves `chats` (pre-removal order).
    ///
    /// - `selectedID` naming another thread (or nil): unchanged.
    /// - `selectedID` naming the removed thread: the next row after it,
    ///   else the previous row, else nil (it was the only row).
    /// - Removed id absent from `chats` with the selection on it (a
    ///   direct-opened thread): the first row, else nil.
    /// Never returns `removedID`.
    public static func fallback(
        removedID: String, chats: [ChatItem], selectedID: String?
    ) -> String? {
        guard selectedID == removedID else { return selectedID }
        guard let i = chats.firstIndex(where: { $0.id == removedID }) else {
            return chats.first?.id
        }
        let next = chats.index(after: i)
        if next < chats.endIndex { return chats[next].id }
        if i > chats.startIndex { return chats[chats.index(before: i)].id }
        return nil
    }
}
