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
import SwiftUI

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

    /// Spacing for this mode. Comfortable pins the shipped constants
    /// exactly; Compact tightens gaps, padding and the list avatar only
    /// (fonts and colors never change).
    public var metrics: MessageDensityMetrics {
        switch self {
        case .comfortable:
            return MessageDensityMetrics(
                headerTop: 8, continuationTop: 2, rowBottom: 2,
                bubbleHorizontal: 12, bubbleVertical: 8,
                separatorVertical: 8, chatRowVertical: 3, chatAvatar: 28)
        case .compact:
            return MessageDensityMetrics(
                headerTop: 4, continuationTop: 1, rowBottom: 1,
                bubbleHorizontal: 8, bubbleVertical: 4,
                separatorVertical: 4, chatRowVertical: 1, chatAvatar: 24)
        }
    }
}

/// Pure spacing values for one density mode (points).
public struct MessageDensityMetrics: Equatable, Sendable {
    /// Timeline row top padding when the row starts a run (shows header).
    public let headerTop: CGFloat
    /// Timeline row top padding for a continuation row.
    public let continuationTop: CGFloat
    public let rowBottom: CGFloat
    public let bubbleHorizontal: CGFloat
    public let bubbleVertical: CGFloat
    public let separatorVertical: CGFloat
    /// Sidebar chat-row vertical padding and avatar diameter.
    public let chatRowVertical: CGFloat
    public let chatAvatar: CGFloat

    public init(
        headerTop: CGFloat, continuationTop: CGFloat, rowBottom: CGFloat,
        bubbleHorizontal: CGFloat, bubbleVertical: CGFloat,
        separatorVertical: CGFloat, chatRowVertical: CGFloat, chatAvatar: CGFloat
    ) {
        self.headerTop = headerTop
        self.continuationTop = continuationTop
        self.rowBottom = rowBottom
        self.bubbleHorizontal = bubbleHorizontal
        self.bubbleVertical = bubbleVertical
        self.separatorVertical = separatorVertical
        self.chatRowVertical = chatRowVertical
        self.chatAvatar = chatAvatar
    }
}

private struct MessageDensityKey: EnvironmentKey {
    static let defaultValue: MessageDensity = .comfortable
}

public extension EnvironmentValues {
    /// Set by `HostedRoot` from the window model (comfortable when unset).
    var messageDensity: MessageDensity {
        get { self[MessageDensityKey.self] }
        set { self[MessageDensityKey.self] = newValue }
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

