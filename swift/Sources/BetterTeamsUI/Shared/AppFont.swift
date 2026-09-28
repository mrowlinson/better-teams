// AppFont.swift — the only literal font sizes in the UI target (UI-SPEC
// R14, §10). Base sizes follow the macOS text-style table (Body 13,
// Headline 13 bold, Subheadline 11, Caption 10, Title3 15), scaled by
// `ContentTextScale`; nothing below 10 pt.
import AppKit
import SwiftUI

public enum AppFont {
    public static func body(_ s: Double) -> Font { .system(size: 13 * s) }
    public static func bodyEmphasized(_ s: Double) -> Font { .system(size: 13 * s, weight: .semibold) }
    public static func headline(_ s: Double) -> Font { .system(size: 13 * s, weight: .bold) }
    public static func subheadline(_ s: Double) -> Font { .system(size: 11 * s) }
    public static func caption(_ s: Double) -> Font { .system(size: max(10, 10 * s)) }
    public static func title3(_ s: Double) -> Font { .system(size: 15 * s, weight: .semibold) }
    public static func code(_ s: Double) -> Font { .system(size: 12 * s, design: .monospaced) }
    /// AppKit twins for attributed message runs.
    public static func nsBodyEmphasized(_ s: Double) -> NSFont { .systemFont(ofSize: 13 * s, weight: .semibold) }
    public static func nsBody(_ s: Double) -> NSFont { .systemFont(ofSize: 13 * s) }
    public static func nsCode(_ s: Double) -> NSFont { .monospacedSystemFont(ofSize: 12 * s, weight: .regular) }
    /// Device code (sign-in): large monospaced.
    public static let deviceCode: Font = .system(size: 34, weight: .semibold, design: .monospaced)
    /// Glyph inside a 15 pt avatar corner badge (a symbol, not text).
    public static let avatarBadgeGlyph: Font = .system(size: 9, weight: .bold)
    /// App store icon glyph at a tile size (APPHOST-B2).
    public static func appTileGlyph(_ tile: CGFloat) -> Font {
        .system(size: tile * 0.46, weight: .medium)
    }

    /// Avatar monogram at a diameter.
    public static func monogram(_ diameter: CGFloat) -> Font {
        .system(size: diameter * 0.4, weight: .semibold)
    }
}
