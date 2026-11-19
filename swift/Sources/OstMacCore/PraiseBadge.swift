// PraiseBadge.swift — praise badge catalog (PRAISE lane).
//
// Teams Praise ships ten badges (Viva Insights / Praise message
// extension). The wire carries the badge name (badge Image altText);
// this catalog pins the display name, the stable token used on the
// wire, and the native glyph the picker and the card render with
// (no remote art dependency).
import Foundation

/// One Praise badge. `rawValue` is the wire token (matches the badge
/// Image altText real Teams clients post).
public enum PraiseBadge: String, Sendable, Equatable, CaseIterable, Codable {
    case thankYou = "ThankYou"
    case awesome = "Awesome"
    case achiever = "Achiever"
    case coach = "Coach"
    case creative = "Creative"
    case kindHeart = "KindHeart"
    case leadership = "Leadership"
    case problemSolver = "ProblemSolver"
    case teamPlayer = "TeamPlayer"
    case courage = "Courage"

    /// Stable token used on the wire and in mining.
    public var wireToken: String { rawValue }

    /// Name shown in the picker and on the rendered card.
    public var displayName: String {
        switch self {
        case .thankYou: "Thank You"
        case .awesome: "Awesome"
        case .achiever: "Achiever"
        case .coach: "Coach"
        case .creative: "Creative"
        case .kindHeart: "Kind Heart"
        case .leadership: "Leadership"
        case .problemSolver: "Problem Solver"
        case .teamPlayer: "Team Player"
        case .courage: "Courage"
        }
    }

    /// Native glyph for the picker row and the rendered card.
    public var symbol: String {
        switch self {
        case .thankYou: "heart.fill"
        case .awesome: "star.fill"
        case .achiever: "trophy.fill"
        case .coach: "megaphone.fill"
        case .creative: "lightbulb.fill"
        case .kindHeart: "heart.circle.fill"
        case .leadership: "person.3.fill"
        case .problemSolver: "puzzlepiece.fill"
        case .teamPlayer: "person.2.fill"
        case .courage: "flame.fill"
        }
    }

    /// Token lookup (mining, send path). Matches the raw token and,
    /// case-insensitively, the display name (badge altText spells it
    /// "Kind Heart").
    public init?(wireToken: String) {
        let t = wireToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let exact = Self(rawValue: t) { self = exact; return }
        let folded = t.lowercased()
        for b in Self.allCases where b.displayName.lowercased() == folded { self = b; return }
        return nil
    }
}
