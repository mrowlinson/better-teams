// PinnedMessageBar.swift — FIXPACK3 R3: the chat's pinned message, shown at
// the top of the conversation (Teams behavior: the newest pin rides above
// the timeline; click jumps to it; several pins open a list). Native
// controls only: an SF Symbol pin, a plain button, a pull-down menu for the
// rest, the bar material and a hairline. The Info panel's Pinned tab keeps
// the full list.
import OstMacCore
import SwiftUI

struct PinnedMessageBar: View {
    @ObservedObject var store: PinnedMessageStore
    @ObservedObject var conv: ConversationStore
    let chatID: String

    var body: some View {
        // Cheap early-out first: chats with no pins never index the messages.
        if !store.pins(for: chatID).isEmpty {
            let rows = store.rows(for: chatID, messages: conv.chatID == chatID ? conv.messages : [])
            if let newest = rows.last {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Button { jump(newest) } label: {
                            (Text(sender(newest)).fontWeight(.medium) + Text("  ") + Text(newest.preview)
                                .foregroundStyle(.secondary))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(newest.isAvailable ? "Show in Conversation" : "Not in loaded history")
                        .accessibilityLabel("Pinned message from \(sender(newest))")
                        .accessibilityHint("Shows the message in the conversation")
                        .contextMenu {
                            Button("Unpin") { store.unpin(chatID: chatID, messageID: newest.messageID) }
                        }
                        if rows.count > 1 {
                            Menu("\(rows.count) Pinned") {
                                ForEach(rows.reversed()) { r in
                                    Button("\(sender(r)): \(r.preview)") { jump(r) }
                                        .disabled(!r.isAvailable)
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                .background(.bar)
            }
        }
    }

    private func sender(_ r: PinnedMessages.StripRow) -> String {
        !r.sender.isEmpty && r.sender == conv.ownDisplayName ? "You" : r.sender
    }

    private func jump(_ r: PinnedMessages.StripRow) {
        guard r.isAvailable else { return }
        conv.seek(messageID: r.messageID)
    }
}
