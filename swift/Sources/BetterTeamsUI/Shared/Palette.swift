// Palette.swift — the only literal colors in the UI target (UI-SPEC
// R14). Everything else uses semantic styles.
import AppKit
import SwiftUI

public enum Palette {
    /// Rail and list badges: system red capsule (tab bars: "red oval
    /// containing white text").
    public static let badge = Color(nsColor: .systemRed)
    public static let badgeText = Color.white

    /// Monogram avatar fills (white text on each meets 4.5:1).
    private static let avatarFills: [Color] = [
        Color(red: 0.16, green: 0.38, blue: 0.75),
        Color(red: 0.49, green: 0.25, blue: 0.70),
        Color(red: 0.72, green: 0.24, blue: 0.40),
        Color(red: 0.12, green: 0.47, blue: 0.40),
        Color(red: 0.62, green: 0.33, blue: 0.08),
        // Slate: lighter in Dark Mode so the disc stands out from the
        // dark list (≥3:1) while white initials keep 4.5:1.
        Color(nsColor: NSColor(name: "avatarSlate") { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0.40, green: 0.46, blue: 0.56, alpha: 1)
                : NSColor(srgbRed: 0.30, green: 0.36, blue: 0.45, alpha: 1)
        }),
    ]

    public static let avatarText = Color.white

    /// Stable fill for a name (FNV-1a, not `hashValue`, which is seeded
    /// per process).
    public static func avatarFill(for name: String) -> Color {
        var h: UInt32 = 2_166_136_261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return avatarFills[Int(h % UInt32(avatarFills.count))]
    }

    /// Presence colors (always paired with a shape, §6).
    public static let presenceAvailable = Color(nsColor: .systemGreen)
    public static let presenceBusy = Color(nsColor: .systemRed)
    public static let presenceAway = Color(nsColor: .systemYellow)
    public static let presenceOffline = Color(nsColor: .secondaryLabelColor)

    public static let failed = Color(nsColor: .systemRed)
    /// Activity kind badge disc (mention, reply, reaction, saved): a
    /// fixed system hue that keeps a white glyph legible in light and
    /// dark, whatever the accent (§10 contrast).
    public static let activityBadge = Color(nsColor: .systemBlue)
    /// Destructive actions outside alerts (Leave Chat…, §9.5).
    public static let destructive = Color(nsColor: .systemRed)
    /// "New messages" divider line in the timeline.
    public static let newMessages = Color(nsColor: .systemRed)
    /// Message-body mentions (`MessageTextAttributes.mention`): every
    /// mention takes the accent color; one naming you also gets a tinted
    /// background (never color alone: weight changes too, §10).
    /// The system accent (not `.tint`, which draws gray in inactive
    /// windows): own-message cards and quote bars keep their color.
    public static let mention = Color(nsColor: .controlAccentColor)
    public static let ownMentionBackground = Color(nsColor: .controlAccentColor).opacity(0.18)
    /// Own-message card: the accent at 14% reads in light but sank into
    /// the dark window background, so Dark Mode doubles it.
    public static let ownCard = Color(nsColor: accentWash("ownCard", light: 0.14, dark: 0.28))
    /// Jump / marked message band (§6.2.1): the system accent, not
    /// `.tint` (gray in inactive windows), stronger in Dark Mode.
    public static let messageHighlight = Color(nsColor: accentWash("messageHighlight", light: 0.16, dark: 0.32))

    /// The accent at an appearance-dependent alpha (resolved at draw
    /// time, so accent and appearance changes follow).
    private static func accentWash(_ name: String, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: NSColor.Name(name)) { a in
            NSColor.controlAccentColor.withAlphaComponent(
                a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
    /// AppKit twins for attributed runs (selectable text renders through
    /// AppKit attributes).
    public static let mentionNS = NSColor.controlAccentColor
    public static let ownMentionBackgroundNS = NSColor.controlAccentColor.withAlphaComponent(0.18)
    public static let inlineCodeBackgroundNS = NSColor.quaternarySystemFill

    /// Rail divider (§5.2). `separatorColor` (what `Divider()` draws)
    /// nearly vanishes on the dark sidebar; tertiary label reads in both
    /// appearances and still adapts to Increase Contrast.
    public static let railDivider = Color(nsColor: .tertiaryLabelColor)
    /// Timeline day-separator rules ("Today"): same reason as the rail
    /// divider, `separatorColor` vanished on the dark timeline.
    public static let dayRule = Color(nsColor: .tertiaryLabelColor)
    /// Edge of in-message panels (code blocks, link cards): their
    /// `.fill.quaternary` alone barely separates from the dark background.
    public static let panelEdge = Color(nsColor: .separatorColor)
}
