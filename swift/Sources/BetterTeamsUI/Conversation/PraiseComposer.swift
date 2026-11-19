// PraiseComposer.swift — Praise compose popover (PRAISE lane).
//
// Native popover anchored to the composer's Praise button (§6.2.2):
// badge grid, recipient field, note field, Send. One popover at a
// time (`ComposerPopover.praise`); the draft is untouched.
import OstMacCore
import SwiftUI

/// Praise compose (badge + recipient + note), pure-hosted in the
/// composer's popover slot.
struct PraiseComposer: View {
    let conv: ConversationStore
    @ObservedObject var composer: ComposerModel
    @State private var badge: PraiseBadge = .thankYou
    @State private var recipient: String = ""
    @State private var note: String = ""
    @Environment(\.contentTextScale) private var scale

    private var canSend: Bool {
        !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Praise")
                .font(AppFont.headline(scale))
            badgeGrid
            TextField("To", text: $recipient)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Recipient")
            TextField("Note (optional)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3)
                .accessibilityLabel("Note")
            HStack {
                Spacer(minLength: 0)
                Button("Send Praise") {
                    conv.sendPraise(badge: badge, recipient: recipient, note: note)
                    composer.popover = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canSend)
                .accessibilityLabel("Send Praise")
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            if recipient.isEmpty {
                recipient = PraiseCard.suggestRecipient(messages: conv.messages,
                                                        ownName: conv.ownDisplayName)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Praise")
    }

    /// Badge picker: native buttons in a 5-column grid (same row
    /// target family as the emoji picker), checkmark on the pick.
    private var badgeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
            ForEach(PraiseBadge.allCases, id: \.wireToken) { b in
                let on = b == badge
                Button(action: { badge = b }) {
                    VStack(spacing: 2) {
                        Image(systemName: b.symbol)
                            .font(.system(size: 18))
                            .frame(width: 28, height: 28)
                        Text(b.displayName)
                            .font(AppFont.caption(scale))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.tint.opacity(0.15))
                    }
                }
                .help(b.displayName)
                .accessibilityLabel("\(b.displayName) badge")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityLabel("Praise badge")
    }
}
