// MessageImportance.swift — COMPOSER-B (C1b): importance/urgent compose level.
//
// Teams behavior reference: Normal posts plainly, Important shows a red
// header to recipients, Urgent re-notifies until read. Wire values are
// Graph `chatMessage.importance` parity (`high`/`urgent`); normal is the
// chatsvc default and is never serialized.
import Foundation

/// Composer importance level (pure, unit-tested).
public enum MessageImportance: String, Sendable, Equatable, CaseIterable, Codable {
    case normal
    case important
    case urgent

    /// `"high"` / `"urgent"`, or `""` for normal (never on the wire —
    /// the server default already means normal).
    public var wireValue: String {
        switch self {
        case .normal: ""
        case .important: "high"
        case .urgent: "urgent"
        }
    }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .important: "Important"
        case .urgent: "Urgent"
        }
    }

    /// Tolerant parse (unknown → normal — cosmetic, never fails a send).
    public static func parse(_ s: String) -> MessageImportance {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "important": .important
        case "urgent": .urgent
        default: .normal
        }
    }
}
