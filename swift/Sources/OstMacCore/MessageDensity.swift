// MessageDensity.swift — f2-density lane: message-density options.
//
// One global setting (Comfortable default / Compact) under
// Settings → Chats → Appearance. Density is SPACING ONLY — fonts,
// colors, and token values never change; Comfortable resolves to
// today's exact constants. Compact tightens the timeline (row gap,
// bubble padding, day separators) and the sidebar chat rows (row
// padding, avatar) so more fits on screen.
import Combine
import Foundation

/// Message density: Comfortable (today's layout, default) or Compact
/// (tighter spacing, same type).
public enum MessageDensity: String, CaseIterable, Sendable {
    case comfortable
    case compact

    public var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }
}

/// Persisted density store: one raw-string key (QuietHours/GhostStore
/// precedent — suite-injectable UserDefaults, @Published + didSet).
@MainActor
public final class DensityStore: ObservableObject {
    public nonisolated static let modeKey = "om.messageDensity"

    private let defaults: UserDefaults

    @Published public var mode: MessageDensity {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    /// Unknown/missing raw values fall back to Comfortable (fresh
    /// installs + forward-compat).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.modeKey)
        let mode = raw.flatMap(MessageDensity.init(rawValue:)) ?? .comfortable
        _mode = Published(initialValue: mode)
    }
}

