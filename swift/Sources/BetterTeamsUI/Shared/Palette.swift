// Palette.swift — the only literal colors in the UI target (UI-SPEC
// R14). Everything else uses semantic styles.
import AppKit
import OstMacCore
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
    /// Syntax colors for code in message bodies (`codeToken` runs): adaptive
    /// system colors, so light and dark follow the appearance. `.plain` has
    /// none (the bubble's own text color).
    public static func codeTokenNS(_ token: CodeHighlight.Token) -> NSColor? {
        switch token {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .systemGray
        case .number: .systemOrange
        case .title: .systemBlue
        case .type: .systemTeal
        case .tag: .systemGreen
        case .plain: nil
        }
    }
    /// Activity kind badge disc (mention, reply, reaction, saved): a
    /// fixed system hue that keeps a white glyph legible in light and
    /// dark, whatever the accent (§10 contrast).
    public static let activityBadge = Color(nsColor: .systemBlue)
    /// Destructive actions outside alerts (Leave Chat…, §9.5).
    public static let destructive = Color(nsColor: .systemRed)
    /// "New messages" divider line in the timeline.
    public static let newMessages = Color(nsColor: .systemRed)
    /// Message-body mentions (`MessageTextAttributes.mention`): every
    /// mention takes the brand color; one naming you also gets a tinted
    /// background (never color alone: weight changes too, §10).
    /// Fixed Teams brand hues, not `controlAccentColor`/`.tint`: those
    /// wash to gray when the window or app is inactive, and Teams keeps
    /// own bubbles, mentions and highlights colored regardless of focus.
    /// Mention text: #5B5FC7 light (5.4:1 on white, 4.6:1 on the own
    /// bubble), #A9ACFF dark (≥4.7:1 on both dark bubbles).
    public static let mentionNS = dynamic("mention", light: 0x5B5FC7, dark: 0xA9ACFF)
    public static let mention = Color(nsColor: mentionNS)
    public static let ownMentionBackgroundNS = dynamic("ownMentionBackground", light: 0x5B5FC7, dark: 0x7F85F5,
                                                       lightAlpha: 0.18, darkAlpha: 0.30)
    public static let ownMentionBackground = Color(nsColor: ownMentionBackgroundNS)
    /// Text of a mention naming you, on that wash: #33358A light (≥ 7:1
    /// on the wash over either bubble), #D0D2FF dark (≥ 5.6:1). The brand
    /// #5B5FC7 on its own 18% wash over the own bubble was 3.6:1.
    public static let ownMentionTextNS = dynamic("ownMentionText", light: 0x33358A, dark: 0xD0D2FF)
    public static let ownMentionText = Color(nsColor: ownMentionTextNS)
    /// Own-message bubble (Teams): lavender #E8EBFA in light, muted
    /// indigo #2F3148 in dark (white text ≥ 12:1). Opaque, so it reads
    /// the same whatever sits behind it; Increase Contrast adds the
    /// bubble outline in `MessageRowView`.
    public static let ownCard = Color(nsColor: dynamic("ownCard", light: 0xE8EBFA, dark: 0x2F3148))
    /// Others' chat bubble (Teams): a neutral wash — light gray in light,
    /// dark gray in dark — that follows the window background.
    public static let otherCard = Color(nsColor: NSColor(name: NSColor.Name("otherCard")) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.055)
    })
    /// Jump / marked message band (§6.2.1): a brand wash (Teams tints
    /// the jumped-to message), stronger in Dark Mode, stable when the
    /// window is inactive.
    public static let messageHighlight = Color(nsColor: dynamic("messageHighlight", light: 0x5B5FC7, dark: 0x7F85F5,
                                                                lightAlpha: 0.16, darkAlpha: 0.30))

    /// A fixed sRGB color per appearance (resolved at draw time).
    private static func dynamic(_ name: String, light: UInt32, dark: UInt32,
                                lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        func rgb(_ v: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
        }
        return NSColor(name: NSColor.Name(name)) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        }
    }
    /// AppKit twins for attributed runs (selectable text renders through
    /// AppKit attributes): `mentionNS`, `ownMentionBackgroundNS` above.
    /// Code (inline + block) and reply-quote fill: tertiary, so it still
    /// separates from the others' gray bubble (quaternary on that gray
    /// all but vanished) and from the own lavender bubble.
    public static let inlineCodeBackgroundNS = NSColor.tertiarySystemFill
    public static let blockFill = Color(nsColor: inlineCodeBackgroundNS)
    /// Reply-quote preview text: secondary label on the gray bubble was
    /// under 4.5:1; 75% label reads ≥ 7:1 on the quote fill in both
    /// appearances (Increase Contrast uses full label in the view).
    public static let quoteText = Color.primary.opacity(0.75)

    /// Demo meeting slide (MeetingVideoStage): a fixed light slide, so
    /// fixed colors in any appearance.
    static let slideAccent = Color(red: 0.36, green: 0.35, blue: 0.80)
    static let slideInk = Color(red: 0.14, green: 0.15, blue: 0.19)
    static let slideMuted = Color(red: 0.42, green: 0.44, blue: 0.50)

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
    /// Image viewer window + letterbox: the app's window background, so
    /// the viewer follows light/dark live like every other window.
    public static let viewerBackgroundNS = NSColor.windowBackgroundColor

    /// A manifest `accentColor` (`#RRGGBB`); nil when absent or malformed.
    public static func manifestAccent(_ hex: String?) -> Color? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
