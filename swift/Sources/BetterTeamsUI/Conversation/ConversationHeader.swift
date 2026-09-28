// ConversationHeader.swift — content-layer header (UI-SPEC §6.2):
// avatar, name, subtitle, trailing segmented Chat | Files | Notes.
import SwiftUI

struct ConversationHeader: View {
    let name: String
    let isGroup: Bool
    let subtitle: String
    @Binding var tab: ConversationTab
    @Environment(\.contentTextScale) private var scale

    /// Shared with the inspector's segmented header: both hairlines sit
    /// on one line at the default text size.
    static let minHeight: CGFloat = 56

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
            Spacer(minLength: 12)
            Picker("View", selection: $tab) {
                ForEach(ConversationTab.allCases, id: \.rawValue) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: Self.minHeight)
        .accessibilityElement(children: .contain)
    }
}
