// RailButtonStyle.swift — square labeled tab button look (UI-SPEC §5.2).
//
// Stock `Button` + this `ButtonStyle`: symbol over label, 10 pt
// continuous corners, semantic fills only. Keyboard focus shows the
// hover fill, never a ring (§10).
import SwiftUI

/// Evidence-only forced visual state (the control gallery).
public enum RailButtonForced: String, CaseIterable, Sendable {
    case normal, hover, pressed, focused, selected, selectedInactive
}

struct RailButtonStyle: ButtonStyle {
    let selected: Bool
    let height: CGFloat
    var forced: RailButtonForced?

    func makeBody(configuration: Configuration) -> some View {
        RailButtonBody(configuration: configuration, selected: selected, height: height, forced: forced)
    }
}

private struct RailButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let height: CGFloat
    let forced: RailButtonForced?
    @State private var hovering = false
    @Environment(\.isFocused) private var focused
    @Environment(\.controlActiveState) private var activeState

    private var isSelected: Bool {
        if let forced { return forced == .selected || forced == .selectedInactive }
        return selected
    }

    private var isKey: Bool {
        if let forced { return forced != .selectedInactive }
        return activeState == .key
    }

    private var pressed: Bool { forced == .pressed || (forced == nil && configuration.isPressed) }
    private var hovered: Bool {
        forced == .hover || forced == .focused || (forced == nil && (hovering || focused))
    }

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .environment(\.railSelected, isSelected)
            .environment(\.railKey, isKey)
            .frame(width: RailModel.itemWidth, height: height)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
    }

    /// Selected in an inactive window keeps the label at `.primary`, as
    /// every other label: `.secondary` read lighter than the unselected
    /// tabs, as if disabled (the gray selection fill carries the state).
    private var foreground: AnyShapeStyle {
        if isSelected, isKey { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(.primary)
    }

    private var background: AnyShapeStyle {
        if isSelected {
            return isKey ? AnyShapeStyle(.tint.quaternary) : AnyShapeStyle(.fill.tertiary)
        }
        if pressed { return AnyShapeStyle(.fill.tertiary) }
        if hovered { return AnyShapeStyle(.fill.quaternary) }
        return AnyShapeStyle(.clear)
    }
}

private struct RailSelectedKey: EnvironmentKey { static let defaultValue = false }
private struct RailKeyWindowKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    var railSelected: Bool {
        get { self[RailSelectedKey.self] }
        set { self[RailSelectedKey.self] = newValue }
    }

    var railKey: Bool {
        get { self[RailKeyWindowKey.self] }
        set { self[RailKeyWindowKey.self] = newValue }
    }
}

/// Symbol over label, badge overlaid top-trailing on the symbol.
struct RailButtonLabel: View {
    let title: String
    let symbol: String
    let badge: Int?
    @Environment(\.railSelected) private var selected
    @Environment(\.railKey) private var key

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .symbolVariant(selected ? .fill : .none)
                .font(.title2)
                .foregroundStyle(symbolStyle)
                .frame(height: 24)
                .overlay(alignment: .topTrailing) {
                    if let badge { RailBadge(count: badge).offset(x: 10, y: -5) }
                }
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 2)
        }
    }

    private var symbolStyle: AnyShapeStyle {
        if selected { return key ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.secondary)
    }
}

/// Red capsule, white monospaced digits; 1…99 then 99+; 0 = dot only.
struct RailBadge: View {
    let count: Int

    var body: some View {
        if count <= 0 {
            Circle().fill(Palette.badge).frame(width: 9, height: 9)
                .accessibilityHidden(true)
        } else {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.badgeText)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(Palette.badge))
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}
