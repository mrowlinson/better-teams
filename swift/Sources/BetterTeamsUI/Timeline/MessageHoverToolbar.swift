// MessageHoverToolbar.swift — the Teams hover toolbar on a message
// (UI-SPEC §6.2.1).
//
// Resting the pointer on a message (or keyboard focus on it) shows a
// small bar: six quick reactions, More reactions, Reply and ⋯ More (the
// context menu's items). Timing is Teams-like: it appears after a short
// dwell and fades in, survives a brief grace so the pointer can travel
// onto it, moves to a neighbour after a shorter warm dwell, and stays
// away while the timeline scrolls. It sits in empty space of its own
// row, never over any message content (`BubbleLane`), and that space is
// part of the row's layout whether or not the bar shows, so nothing
// moves when it appears. Every item calls the same `TimelineActions`
// path as the context menu; VoiceOver gets the same items as named
// actions on the row.
import AppKit
import OstMacCore
import SwiftUI

/// Hover timing (Teams web runs on Fluent UI v9: 250 ms show/hide are
/// Fluent's popup defaults, 150/100 ms its fast/faster motion tokens).
enum HoverTiming {
    /// Pointer must rest this long before the bar appears.
    static let showDelay: UInt64 = 250
    /// While a bar is up, resting on another message moves it this fast.
    static let warmDelay: UInt64 = 100
    /// Leaving the message hides the bar only after this grace.
    static let hideGrace: UInt64 = 250
    static let fadeIn = 0.15
    static let fadeOut = 0.10
}

/// The one delayed job the hover state waits on (injectable so tests
/// step time by hand; production waits on `Debounce`, the R7 delay).
@MainActor
protocol HoverScheduler: AnyObject {
    /// Replaces any pending job.
    func schedule(after milliseconds: UInt64, _ work: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class DebounceHoverScheduler: HoverScheduler {
    private var pending: Debounce?

    func schedule(after milliseconds: UInt64, _ work: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let d = Debounce(milliseconds: milliseconds)
        pending = d
        d.schedule(work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Which message shows the toolbar. One per timeline, shared by every
/// row: rows are reused cells, so per-row view state could carry one
/// message's hover onto another. `evidence` is the demo capture pin
/// (`hover=<messageID>` on an evidence route).
@MainActor
@Observable
final class MessageHover {
    /// The message whose bar is up (after the dwell).
    var shownID: String?
    var focusedID: String?
    /// The message under the pointer right now (drives `shownID`).
    @ObservationIgnored private(set) var pointerID: String?
    @ObservationIgnored private let scheduler: HoverScheduler

    init(scheduler: HoverScheduler? = nil) {
        self.scheduler = scheduler ?? DebounceHoverScheduler()
    }

    static let evidence = MessageHover()

    /// Pointer entered/left a row. Leaving only clears its own hover, so
    /// enter-next/leave-previous in either order ends on the next row.
    func pointer(_ inside: Bool, id: String) {
        if inside {
            pointerID = id
            if shownID == id {
                scheduler.cancel()    // back within the grace: keep it
                return
            }
            let delay = shownID == nil ? HoverTiming.showDelay : HoverTiming.warmDelay
            scheduler.schedule(after: delay) { [weak self] in self?.settle() }
        } else {
            guard pointerID == id else { return }
            pointerID = nil
            if shownID == nil {
                scheduler.cancel()    // left before the dwell ended
            } else {
                scheduler.schedule(after: HoverTiming.hideGrace) { [weak self] in self?.settle() }
            }
        }
    }

    /// The timeline scrolled: hide now, show again once the pointer has
    /// rested for a full dwell after the last scroll step.
    func scrolled() {
        if shownID != nil { shownID = nil }
        if pointerID != nil {
            scheduler.schedule(after: HoverTiming.showDelay) { [weak self] in self?.settle() }
        } else {
            scheduler.cancel()
        }
    }

    func focus(_ focused: Bool, id: String) {
        focusedID = HoverToolbarRules.hover(current: focusedID, id: id, inside: focused)
    }

    private func settle() {
        if shownID != pointerID { shownID = pointerID }
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

    /// One toolbar item (every item has this exact frame, so the bar's
    /// size is known before it is ever drawn).
    static func itemSize(scale: Double) -> CGSize {
        CGSize(width: (24 * scale).rounded(), height: (20 * scale).rounded())
    }

    /// 9 items + divider (1 pt, 2 pt each side) + 6/3 pt padding.
    static func size(scale: Double) -> CGSize {
        let item = itemSize(scale: scale)
        return CGSize(width: item.width * 9 + 5 + 12, height: item.height + 6)
    }
}

/// Where the bar goes in a message's lane (header + bubble).
enum ToolbarPlacement: Equatable {
    case none
    /// Beside the bubble's top, in the row's empty side.
    case side
    /// Above the bubble in the header line, clear of the name/time.
    case header
    /// A strip reserved above the lane (no empty space anywhere else).
    case strip
    /// A run's continuation bubble with no room beside it: the bar sits
    /// over the bubble's top free-side corner, as Teams floats its bar,
    /// so a same-sender run stays tight (CHATSYNC3 R3).
    case overlay
}

/// Frames for one lane, in lane coordinates (the bar may sit outside
/// the lane's bounds, in the row's empty side or top padding).
struct LanePlan: Equatable {
    var size: CGSize
    var header: CGRect?
    var card: CGRect
    var toolbar: CGRect?
    var placement: ToolbarPlacement

    static let spacing: CGFloat = 4
    /// Gap between the bar and the bubble or header text.
    static let gap: CGFloat = 6

    /// - width: the lane's proposed width (nil = ideal).
    /// - slack: empty row width beyond that proposal on the free side
    ///   (the row's spacer minimum).
    /// - topPadding: the row's padding above the lane (the bar may use it).
    static func make(width: CGFloat?, header: CGSize?, card: CGSize, toolbar: CGSize?,
                     ownTrailing: Bool, slack: CGFloat, topPadding: CGFloat) -> LanePlan {
        let laneW = max(header?.width ?? 0, card.width)
        let block = header.map { $0.height + spacing } ?? 0
        func edge(_ w: CGFloat) -> CGFloat { ownTrailing ? laneW - w : 0 }
        let headerRect = header.map { CGRect(x: edge($0.width), y: 0, width: $0.width, height: $0.height) }
        let cardRect = CGRect(x: edge(card.width), y: block, width: card.width, height: card.height)
        var plan = LanePlan(size: CGSize(width: laneW, height: block + card.height),
                            header: headerRect, card: cardRect, toolbar: nil, placement: .none)
        guard let tb = toolbar else { return plan }
        // The free side of the row, in lane x: others' bubbles have it
        // trailing, own bubbles leading.
        let avail = (width ?? laneW) + slack
        let lo = ownTrailing ? laneW - avail : 0
        let hi = ownTrailing ? laneW : avail

        // 1. Beside the bubble, top-aligned, when the empty side fits it.
        if avail - card.width - gap >= tb.width {
            let x = ownTrailing ? cardRect.minX - gap - tb.width : cardRect.maxX + gap
            plan.toolbar = CGRect(x: x, y: cardRect.minY, width: tb.width, height: tb.height)
            plan.placement = .side
            return plan
        }
        // 2. Header line, at the bubble's free-side corner, clear of the
        //    name/time (a wide bubble leaves the header mostly empty).
        if let h = headerRect {
            let x = ownTrailing ? min(cardRect.minX, h.minX - gap - tb.width)
                                : max(cardRect.maxX - tb.width, h.maxX + gap)
            if x >= lo && x + tb.width <= hi {
                let y = block - 1 - tb.height
                let reserve = max(0, -topPadding - y)
                plan.shift(reserve)
                plan.toolbar = CGRect(x: x, y: y + reserve, width: tb.width, height: tb.height)
                plan.placement = .header
                return plan
            }
        }
        // 3. A run's continuation (no header): over the bubble's top
        //    free-side corner, inside the row, no reserved height. Teams
        //    keeps same-sender runs tight and floats its bar over the
        //    message; a reserved strip opened a ~25 pt gap mid-run in
        //    narrow windows (the pop-out).
        if header == nil {
            // At the far edge of the free side: as little bubble under it as fits.
            let x = ownTrailing ? min(lo, laneW - tb.width) : max(0, hi - tb.width)
            plan.toolbar = CGRect(x: x, y: cardRect.minY - min(topPadding, 2), width: tb.width, height: tb.height)
            plan.placement = .overlay
            return plan
        }
        // 4. A strip above the lane, reserved in the row's height.
        let reserve = max(0, tb.height + 1 - topPadding)
        plan.shift(reserve)
        let x = ownTrailing ? min(cardRect.minX, laneW - tb.width) : max(0, cardRect.maxX - tb.width)
        plan.toolbar = CGRect(x: x, y: reserve - 1 - tb.height, width: tb.width, height: tb.height)
        plan.placement = .strip
        return plan
    }

    private mutating func shift(_ dy: CGFloat) {
        guard dy > 0 else { return }
        size.height += dy
        header = header?.offsetBy(dx: 0, dy: dy)
        card = card.offsetBy(dx: 0, dy: dy)
    }
}

/// Header (optional) over the bubble, plus the toolbar slot placed by
/// `LanePlan`. Subviews: [header?, card, toolbar?].
struct BubbleLane: Layout {
    let ownTrailing: Bool
    let hasHeader: Bool
    let toolbar: CGSize?
    let slack: CGFloat
    let topPadding: CGFloat

    private func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> LanePlan {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let p = ProposedViewSize(width: width, height: nil)
        let cardIndex = hasHeader ? 1 : 0
        let header = hasHeader ? subviews[0].sizeThatFits(p) : nil
        let card = subviews[cardIndex].sizeThatFits(p)
        let tb = subviews.count > cardIndex + 1 ? toolbar : nil
        return LanePlan.make(width: width, header: header, card: card, toolbar: tb,
                             ownTrailing: ownTrailing, slack: slack, topPadding: topPadding)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(proposal, subviews)
        // Own lanes hang from the trailing edge (the VStack may be wider).
        let dx = ownTrailing ? bounds.width - plan.size.width : 0
        func put(_ i: Int, _ r: CGRect) {
            subviews[i].place(at: CGPoint(x: bounds.minX + dx + r.minX, y: bounds.minY + r.minY),
                              proposal: ProposedViewSize(r.size))
        }
        var i = 0
        if let h = plan.header { put(i, h); i += 1 }
        put(i, plan.card)
        if let t = plan.toolbar, subviews.count > i + 1 { put(i + 1, t) }
    }
}

/// The toolbar slot: reads the hover state itself, so a hover change
/// re-renders this small view, not every row body. With keyboard
/// navigation on, the bar stays in the tree (transparent, no hits) so
/// Tab reaches its buttons; focus on one shows it like a hover.
struct HoverToolbarSlot: View {
    let row: MessageRowData
    let actions: TimelineActions
    @FocusState private var focus: HoverFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let id = row.message.id
        let shown = HoverToolbarRules.isShown(id: id, hovered: actions.hover.shownID,
                                              focused: actions.hover.focusedID,
                                              pinned: MessageHover.evidence.shownID)
        let anim = fade(in: shown)
        ZStack(alignment: row.ownTrailing ? .topTrailing : .topLeading) {
            if shown || NSApp.isFullKeyboardAccessEnabled {
                MessageHoverToolbar(row: row, actions: actions, focus: $focus)
                    .fixedSize()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: row.ownTrailing ? .topTrailing : .topLeading)
        .animation(anim, value: shown)
        .onChange(of: focus) { _, f in actions.hover.focus(f != nil, id: id) }
    }

    /// Subtle fade (none with Reduce Motion).
    private func fade(in shown: Bool) -> Animation? {
        if reduceMotion { return nil }
        return shown ? .easeOut(duration: HoverTiming.fadeIn) : .easeIn(duration: HoverTiming.fadeOut)
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
        let item = HoverToolbarRules.itemSize(scale: scale)
        HStack(spacing: 0) {
            ForEach(Indexed.wrap(HoverToolbarRules.quickReactions)) { r in
                Button { actions.toggleReaction(m, r.value.emoji) } label: {
                    Text(r.value.emoji).font(AppFont.body(scale))
                        .frame(width: item.width, height: item.height).contentShape(Rectangle())
                }
                .help(r.value.name)
                .accessibilityLabel(r.value.name)
                .focused(focus, equals: .item(r.id))
            }
            Button { actions.moreReactions(m) } label: {
                Image(systemName: "face.smiling")
                    .frame(width: item.width, height: item.height).contentShape(Rectangle())
            }
            .help("More reactions")
            .focused(focus, equals: .item(6))
            Divider().frame(width: 1, height: item.height - 4).padding(.horizontal, 2)
            Button { actions.reply(m) } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .frame(width: item.width, height: item.height).contentShape(Rectangle())
            }
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
            .frame(width: item.width, height: item.height)
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
