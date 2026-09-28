// PresenceBadge.swift — presence = shape + color (UI-SPEC §6; HIG
// accessibility "more than color alone").
import OstMacCore
import SwiftUI

enum PresenceGlyph {
    static func symbol(_ s: PresenceStatus) -> String {
        switch s {
        case .available: "checkmark.circle.fill"
        case .busy: "circle.fill"
        case .dnd: "minus.circle.fill"
        case .away, .brb: "clock.fill"
        case .offline: "xmark.circle"
        }
    }

    static func color(_ s: PresenceStatus) -> Color {
        switch s {
        case .available: Palette.presenceAvailable
        case .busy, .dnd: Palette.presenceBusy
        case .away, .brb: Palette.presenceAway
        case .offline: Palette.presenceOffline
        }
    }
}

struct PresenceBadge: View {
    let status: PresenceStatus
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: PresenceGlyph.symbol(status))
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(PresenceGlyph.color(status))
            .background(Circle().fill(.background).padding(-1.5))
            .accessibilityLabel(status.title)
    }
}
