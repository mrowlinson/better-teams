// ChatRow.swift — one chat list row (UI-SPEC §6.2, R13).
//
// Reserved unread slot, avatar, name (headline when unread) and time on
// line 1; line 2 "Sender: preview" with the reserved status slots (pin,
// mute, snooze, mention) trailing. Toggling any indicator never shifts
// text.
import OstMacCore
import SwiftUI

struct ChatRow: View {
    let chat: ChatItem
    let unread: Bool
    let pinned: Bool
    let mentioned: Bool
    /// Notifications off / snoozed (§6.2 row indicators).
    var muted = false
    var snoozed = false
    /// The newest message failed to send (same mark as the timeline).
    var notSent = false
    /// The other person's status in a 1:1 chat (badge on the avatar).
    var presence: PresenceStatus?
    /// The open conversation: an empty row defers to it while it loads
    /// or fails (never "No messages yet" beside a spinner or an error).
    var conv: ConversationStore?
    let now: Date
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.tint)
                .frame(width: 7, height: 7)
                .opacity(unread ? 1 : 0)
                .accessibilityHidden(true)
            Avatar(name: chat.name, isGroup: chat.is_group)
                .overlay(alignment: .bottomTrailing) {
                    // 4 pt out, as in Search People: at 2 pt the ring
                    // clipped the monogram's trailing letter.
                    if let presence { PresenceBadge(status: presence, size: 10).offset(x: 4, y: 4) }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(chat.name)
                        .font(unread ? AppFont.headline(scale) : AppFont.body(scale))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(ChatListFormat.previewTime(chat.last_message_time, now: now))
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                // Send state leads line 2 in a reserved slot (R13): the
                // preview starts at the same x whether or not the newest
                // message failed. Trailing status indicators sit on line 2,
                // off the name line, laid out only when present.
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle")
                        .font(AppFont.caption(scale).weight(.semibold))
                        .foregroundStyle(Palette.failed)
                        .frame(width: Self.sendStateSlot * scale, alignment: .leading)
                        .opacity(notSent ? 1 : 0)
                        .accessibilityHidden(true)
                    Group {
                        if let conv, previewLine.isEmpty {
                            EmptyChatPreview(conv: conv, chatID: chat.id)
                        } else {
                            Text(preview)
                        }
                    }
                    .font(AppFont.subheadline(scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if pinned { slot("pin.fill") }
                    if muted { slot("bell.slash") }
                    if snoozed { slot("moon.zzz") }
                    if mentioned { slot("at") }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    /// Leading send-state slot on line 2 (R13), at text scale 1.
    static let sendStateSlot: CGFloat = 14

    private var preview: String {
        let line = previewLine
        return line.isEmpty ? EmptyChatPreview.noMessages : line
    }

    private var previewLine: String {
        // A 1:1 row names the other person already: no "Name:" prefix
        // when they sent the newest message.
        let sender = chat.last_message_sender
        let shown = !chat.is_group && sender?.trimmingCharacters(in: .whitespaces) == chat.name ? nil : sender
        return ChatListFormat.previewLine(sender: shown, preview: chat.last_message_preview)
    }

    private func slot(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(AppFont.caption(scale))
            .foregroundStyle(.secondary)
            .frame(width: 12)
            .accessibilityHidden(true)
    }

    private var accessibility: String {
        var parts = [chat.name]
        if let presence { parts.append(presence.availabilityTitle) }
        if unread { parts.append("unread") }
        if mentioned { parts.append("mentions you") }
        if pinned { parts.append("pinned") }
        if muted { parts.append("muted") }
        if snoozed { parts.append("snoozed") }
        if notSent { parts.append("not sent") }
        parts.append(preview)
        return parts.joined(separator: ", ")
    }
}

/// Line 2 of a row with no preview: "No messages yet", unless this chat
/// is the open conversation and its messages are still loading or
/// failed to load; then the line stays blank (reserved, R13) so the list
/// never contradicts the detail pane. Observes the conversation only for
/// the rare empty row.
private struct EmptyChatPreview: View {
    static let noMessages = "No messages yet"
    @ObservedObject var conv: ConversationStore
    let chatID: String

    var body: some View {
        // A space, not "", keeps the line's height when blank.
        Text(Self.line(open: conv.chatID == chatID, loading: conv.loading || !conv.didLoad,
                       failed: conv.error != nil, hasMessages: !conv.messages.isEmpty))
    }

    /// Blank while the open chat is unsettled (loading, failed) or already
    /// shows messages the list row hasn't caught up with.
    static func line(open: Bool, loading: Bool, failed: Bool, hasMessages: Bool) -> String {
        open && (loading || failed || hasMessages) ? " " : noMessages
    }
}
