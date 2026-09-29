// ConversationHeader.swift — content-layer header (UI-SPEC §6.2):
// avatar, name, subtitle, trailing tab row (CHATTABS: built-ins per
// chat kind + pinned tabs with a "+N" overflow, `ChatTabBar`).
import SwiftUI

struct ConversationHeader: View {
    let name: String
    let isGroup: Bool
    let subtitle: String
    let layout: ChatTabLayout
    @Binding var tab: ChatTabKey
    /// The pinned tab opened from "+N" (temporary, closable).
    var opened: ChatTabKey? = nil
    var open: (ChatTabKey) -> Void = { _ in }
    var close: () -> Void = {}
    @Environment(\.contentTextScale) private var scale

    /// Shared with the inspector's segmented header: both hairlines sit
    /// on one line at the default text size.
    static let minHeight: CGFloat = 56
    /// The name keeps at least this much room; the tab row folds into
    /// "+N" rather than squeeze it out (TABS2).
    static let nameMinWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: name, isGroup: isGroup, diameter: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(AppFont.title3(scale))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppFont.subheadline(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: Self.nameMinWidth, alignment: .leading)
            Spacer(minLength: 12)
            // The row claims width before the name, which truncates down
            // to `nameMinWidth`; past that the row folds tabs into "+N".
            ChatTabBar(layout: layout, selection: $tab, opened: opened, open: open, close: close)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: Self.minHeight)
        .accessibilityElement(children: .contain)
    }
}
