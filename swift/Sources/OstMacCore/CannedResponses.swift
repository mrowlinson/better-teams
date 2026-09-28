// CannedResponses.swift — e2-canned: message-template pure policy.
//
// User-authored canned responses (message templates): filter, draft
// insertion, blank-rejection. Persistence lives in
// CannedResponsesStore; the picker in CannedResponsesPickerView.
import Foundation

/// One user-authored message template: a title (picker row) + body
/// (inserted into the draft). Codable for the UserDefaults store.
public struct CannedTemplate: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String

    public init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// Pure template policy: filtering, insertion, validation.
public enum CannedResponses {
    /// Case-insensitive substring filter over title + body. Blank
    /// query returns the templates in order (MentionCompose precedent).
    public static func filtered(
        _ templates: [CannedTemplate], query: String
    ) -> [CannedTemplate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return templates }
        return templates.filter {
            $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    /// Insert a template body into the draft. APPEND decision (never
    /// clobbers user text): empty drafts become the body, non-empty
    /// drafts gain exactly one separating space. No trailing space is
    /// added — the template is complete message text, the user hits
    /// Send. Blank bodies leave the draft untouched.
    public static func insert(_ body: String, into draft: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return draft }
        if draft.isEmpty { return body }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") || draft.hasSuffix("\t")
            ? draft + body
            : draft + " " + body
    }

    /// Blank-rejection for the Settings editor. Returns the inline
    /// reason, or nil when both fields are usable.
    public static func validate(title: String, body: String) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the template a title."
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Template text can't be empty."
        }
        return nil
    }
}
