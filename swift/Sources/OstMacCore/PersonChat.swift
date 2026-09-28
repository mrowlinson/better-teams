// PersonChat.swift — om-lt5-person11: person-pick opens 1:1.
// Pure ref rules shared by the live create path and the demo path.
// No FFI, no network.
import Foundation

public enum PersonChat {
    /// Graph user ref for one directory hit: the AAD id when set,
    /// else the work email (Graph binds either). Nil when both are
    /// missing/blank (the pick falls back to the v1 copy behavior).
    public static func userRef(for person: TeamMember) -> String? {
        if let id = person.userId, !id.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        {
            return id
        }
        guard let email = person.email, !email.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return email
    }

    /// Demo 1:1 thread id for one directory hit (the demo path opens
    /// a canned thread; its messages come from `DemoData`). Prefers
    /// the same ref as the live path; hits without a ref fall back
    /// to the row id (never empty — `TeamMember.id` is required).
    public static func demoChatID(for person: TeamMember) -> String {
        "demo-1:1-\(userRef(for: person) ?? person.id)"
    }
}
