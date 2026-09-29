// ChatRowStyle.swift — chat list row state → style (Teams parity).
//
// Unread rows bold the name, the preview and the time, and the preview
// takes the primary color (Teams). A muted chat badges its avatar with a
// bell-slash: bottom-trailing on its own; when the 1:1 presence badge
// already holds bottom-trailing, the mute badge takes top-trailing so
// each badge keeps one position and neither covers the other.
import SwiftUI

struct ChatRowStyle: Equatable {
    enum Corner: Equatable { case bottomTrailing, topTrailing }

    /// Name, preview and time weights.
    let nameWeight: Font.Weight
    let previewWeight: Font.Weight
    let timeWeight: Font.Weight
    /// Preview in the primary color (unread) or secondary (read).
    let previewPrimary: Bool
    /// Leading unread dot shown (its slot is always reserved).
    let showsUnreadDot: Bool
    /// Where the mute badge sits on the avatar; nil = no mute badge.
    let muteCorner: Corner?

    init(unread: Bool, muted: Bool, hasPresence: Bool) {
        nameWeight = unread ? .bold : .regular
        previewWeight = unread ? .semibold : .regular
        timeWeight = unread ? .semibold : .regular
        previewPrimary = unread
        showsUnreadDot = unread
        muteCorner = muted ? (hasPresence ? .topTrailing : .bottomTrailing) : nil
    }

    /// Badge diameter on the 28 pt avatar (the presence badge's size,
    /// so both badges read as one family).
    static let badgeSize: CGFloat = 10
}

/// Bell-slash on a filled disc, ringed in the window background like the
/// presence badge (themed light/dark; vector symbol, crisp at any scale).
struct MuteBadge: View {
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "bell.slash.fill")
            .resizable()
            .scaledToFit()
            .padding(size * 0.2)
            .frame(width: size + 2, height: size + 2)
            .foregroundStyle(.background)
            .background(Circle().fill(.secondary))
            .background(Circle().fill(.background).padding(-1.5))
            .accessibilityHidden(true)
    }
}
