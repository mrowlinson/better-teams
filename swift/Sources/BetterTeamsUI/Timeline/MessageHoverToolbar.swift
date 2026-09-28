// MessageHoverToolbar.swift — the Teams hover toolbar on a message
// (UI-SPEC §6.2.1).
//
// Hovering a message (or keyboard focus on it) floats a small bar over
// the bubble's top edge: six quick reactions, More reactions, Reply and
// ⋯ More (the context menu's items). It is an overlay, so the row never
// changes size or moves when it appears. Every item calls the same
// `TimelineActions` path as the context menu; VoiceOver gets the same
// items as named actions on the row.
import AppKit
import OstMacCore
import SwiftUI

/// Which message shows the toolbar. One per timeline, shared by every
/// row: rows are reused cells, so per-row view state could carry one
/// message's hover onto another. `evidence` is the demo capture pin
/// (`hover=<messageID>` on an evidence route).
@MainActor
@Observable
final class MessageHover {
    var hoveredID: String?
    var focusedID: String?

    static let evidence = MessageHover()

    /// Pointer entered/left a row: leaving only clears its own hover, so
    /// enter-next/leave-previous in either order ends on the next row.
    func pointer(_ inside: Bool, id: String) {
        hoveredID = HoverToolbarRules.hover(current: hoveredID, id: id, inside: inside)
    }

    func focus(_ focused: Bool, id: String) {
        focusedID = HoverToolbarRules.hover(current: focusedID, id: id, inside: focused)
    }
}

/// Keyboard focus on a toolbar item (buttons join the key loop when
/// keyboard navigation is on; rows never add `.focusable`, R10).
enum HoverFocus: Hashable {
    case item(Int)
}

/// Pure toolbar rules (unit-tested).
enum HoverToolbarRules {
    /// Quick reactions in Teams order, with their spoken names.
    static let quickReactions: [(emoji: String, name: String)] =
        Array(zip(ConversationStore.reactionEmojis, ["Like", "Heart", "Laugh", "Surprised", "Sad", "Angry"]))

    /// The items after the reactions, in order.
    static let trailingItems = ["More reactions", "Reply", "More options"]

    /// A sending, failed or deleted message has no toolbar (its context
    /// menu is Retry/Delete or Copy Link only).
    static func isAvailable(_ row: MessageRowData) -> Bool {
        row.send == .none && !row.message.deleted
    }

    static func isShown(id: String, hovered: String?, focused: String?, pinned: String?) -> Bool {
        hovered == id || focused == id || pinned == id
    }

    static func hover(current: String?, id: String, inside: Bool) -> String? {
        if inside { return id }
        return current == id ? nil : current
    }

    /// Vertical lift over the bubble's top edge. Header rows have the
    /// name line above the bubble to rise into; continuation rows only
    /// their 2 pt top padding, so the bar stays inside its own row (the
    /// part outside would belong to the previous row's hover area).
    static func lift(showsHeader: Bool) -> CGFloat { showsHeader ? -14 : -2 }

    /// Own bubbles sit at the trailing edge, so a bar wider than the
    /// bubble grows leading; others' grow trailing, into the gap.
    static func alignment(ownTrailing: Bool) -> Alignment { ownTrailing ? .topTrailing : .topLeading }
}

/// The overlay slot: reads the hover state itself, so a hover change
/// re-renders this small view, not every row body. With keyboard
/// navigation on, the bar stays in the tree (transparent, no hits) so
/// Tab reaches its buttons; focus on one shows it like a hover.
struct HoverToolbarSlot: View {
    let row: MessageRowData
    let actions: TimelineActions
    @FocusState private var focus: HoverFocus?

    var body: some View {
        let id = row.message.id
        let shown = HoverToolbarRules.isShown(id: id, hovered: actions.hover.hoveredID,
                                              focused: actions.hover.focusedID,
                                              pinned: MessageHover.evidence.hoveredID)
        if HoverToolbarRules.isAvailable(row), shown || NSApp.isFullKeyboardAccessEnabled {
            // Right-aligned on the bubble; a bar wider than the bubble grows
            // into the free side (the slot's overlay alignment picks it).
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                MessageHoverToolbar(row: row, actions: actions, focus: $focus).fixedSize()
            }
            .offset(y: HoverToolbarRules.lift(showsHeader: row.showsHeader))
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .onChange(of: focus) { _, f in actions.hover.focus(f != nil, id: id) }
        }
    }
}

struct MessageHoverToolbar: View {
    let row: MessageRowData
    let actions: TimelineActions
    var focus: FocusState<HoverFocus?>.Binding
    @Environment(\.contentTextScale) private var scale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let m = row.message
        HStack(spacing: 0) {
            ForEach(Indexed.wrap(HoverToolbarRules.quickReactions)) { r in
                Button { actions.toggleReaction(m, r.value.emoji) } label: {
                    Text(r.value.emoji).font(AppFont.body(scale))
                }
                .help(r.value.name)
                .accessibilityLabel(r.value.name)
                .focused(focus, equals: .item(r.id))
            }
            Button { actions.moreReactions(m) } label: { Image(systemName: "face.smiling") }
                .help("More reactions")
                .focused(focus, equals: .item(6))
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button { actions.reply(m) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help("Reply")
                .focused(focus, equals: .item(7))
            Menu {
                MessageContextMenu(row: row, actions: actions)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("More options")
            .focused(focus, equals: .item(8))
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(AppFont.body(scale))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.separator))
        }
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        // VoiceOver reaches the same items as named row actions.
        .accessibilityHidden(true)
    }
}
