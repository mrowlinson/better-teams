// KeywordAlerts.swift — d2-alerts lane: keyword alert elevation policy.
//
// Pure policy beside the rules engine (MentionAlert precedent): keyword
// hits elevate to the OM_MENTION banner style family (distinct subtitle
// + critical sound) WITHOUT breaking through anything the engine already
// suppresses. Breakthrough limits (enforced by ChatFilter, pinned here):
// keyword-allow yields to chat-muted, DND, and quiet hours — it only
// forces notify through the soft skips (own, type, edit, noisy) and
// always loses to keyword-block on the same message.
//
// The subtitle carries no keyword text, so it rides the redacted
// (locked/preview-off) banners unchanged — never a text leak.
import Foundation

/// Keyword-alert elevation surface: reasons + banner style. Pure.
public enum KeywordAlert {
    /// Notify reason when an allow word forces notify.
    public static let allowReason = "keyword-allow"
    /// Skip reason when a block word forces skip (beats allow).
    public static let blockReason = "keyword-block"

    /// Banner subtitle for keyword hits. Fixed text (never the matched
    /// word): safe under lock redaction and preview-off.
    public static let subtitle = "Keyword alert"

    /// Elevation for one notify reason: keyword hits elevate (OM_MENTION
    /// style via the caller's isMention flag), everything else is plain.
    public struct Elevation: Sendable, Equatable {
        public let isElevated: Bool
        public let subtitle: String?
    }

    public static func elevation(forReason reason: String) -> Elevation {
        if reason == allowReason {
            return Elevation(isElevated: true, subtitle: subtitle)
        }
        return Elevation(isElevated: false, subtitle: nil)
    }
}
