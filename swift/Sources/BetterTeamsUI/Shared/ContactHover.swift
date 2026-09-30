// ContactHover.swift — the contact hover card trigger: ~1 s dwell on a
// person's name or avatar shows a popover beside it (never over it).
// The pointer can cross into the card within a short grace; leaving
// both, or any scroll, hides it. One coordinator app-wide (one pointer).
import AppKit
import OstMacCore
import SwiftUI

enum ContactHoverTiming {
    /// Dwell before the first card (Teams waits about a second).
    static let showDelay: UInt64 = 1000
    /// Dwell when moving straight from one card's anchor to another.
    static let warmDelay: UInt64 = 500
    /// Time to cross from the name into the card before it hides.
    static let hideGrace: UInt64 = 300
}

@MainActor
@Observable
final class ContactHover {
    /// Anchor whose card is up.
    private(set) var shownAnchor: String?
    /// Evidence pin: the first anchor for this name shows its card.
    var pinnedName: String?
    @ObservationIgnored private(set) var pinnedAnchor: String?
    @ObservationIgnored private(set) var pointerAnchor: String?
    @ObservationIgnored private(set) var inCard = false
    @ObservationIgnored private let scheduler: HoverScheduler
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The cards' own popover windows: their scroll view is not a scroll
    /// under the anchor.
    @ObservationIgnored private let cardWindows = NSHashTable<NSWindow>.weakObjects()

    init(scheduler: HoverScheduler? = nil, observeScrolling: Bool = false) {
        self.scheduler = scheduler ?? DebounceHoverScheduler()
        if observeScrolling { observeScrolls() }
    }

    static let shared = ContactHover(observeScrolling: true)

    func isShown(_ anchor: String) -> Bool { shownAnchor == anchor || pinnedAnchor == anchor }

    /// Pointer entered/left a name or avatar.
    func pointer(_ inside: Bool, anchor: String) {
        if inside {
            pointerAnchor = anchor
            if shownAnchor == anchor {
                scheduler.cancel()      // back within the grace
                return
            }
            let delay = shownAnchor == nil ? ContactHoverTiming.showDelay : ContactHoverTiming.warmDelay
            scheduler.schedule(after: delay) { [weak self] in self?.settle() }
        } else {
            guard pointerAnchor == anchor else { return }
            pointerAnchor = nil
            if shownAnchor == nil {
                scheduler.cancel()      // left before the dwell ended
            } else if !inCard {
                scheduler.schedule(after: ContactHoverTiming.hideGrace) { [weak self] in self?.settle() }
            }
        }
    }

    /// Pointer entered/left the card itself (keeps it up).
    func card(_ inside: Bool) {
        inCard = inside
        if inside {
            scheduler.cancel()
        } else if pointerAnchor != shownAnchor || pointerAnchor == nil {
            scheduler.schedule(after: ContactHoverTiming.hideGrace) { [weak self] in self?.settle() }
        }
    }

    /// Any scroll: hide now and forget the pending dwell.
    func scrolled() {
        guard shownAnchor != nil || pointerAnchor != nil else { return }
        scheduler.cancel()
        pointerAnchor = nil
        inCard = false
        if shownAnchor != nil { shownAnchor = nil }
    }

    /// Popover closed itself (click outside, Esc) or an action ran.
    func dismiss() {
        scheduler.cancel()
        inCard = false
        pointerAnchor = nil
        if shownAnchor != nil { shownAnchor = nil }
        if pinnedAnchor != nil { pinnedAnchor = nil; pinnedName = nil }
    }

    /// Evidence: claim the pin for the first matching anchor on screen.
    func claimPin(anchor: String, name: String) {
        guard pinnedAnchor == nil, let pinnedName,
              pinnedName.caseInsensitiveCompare(name) == .orderedSame else { return }
        pinnedAnchor = anchor
        shownAnchor = anchor
    }

    private func settle() {
        if inCard { return }
        if shownAnchor != pointerAnchor { shownAnchor = pointerAnchor }
    }

    /// The card's popover window (its content reports it on arrival).
    func noteCardWindow(_ window: NSWindow) { cardWindows.add(window) }

    /// A clip-view bounds change that counts as a scroll under the anchor:
    /// not one in a card's own window (the card scrolls past its height
    /// cap, so its clip view resizes as the popover lays out and its
    /// sections load; taking that for a scroll hid every card the moment
    /// it appeared), and not one outside any window.
    func isAnchorScroll(_ clip: NSClipView) -> Bool {
        guard let window = clip.window else { return false }
        return !cardWindows.contains(window)
    }

    /// Live scrolls (trackpad) and clip-view moves (wheel, programmatic)
    /// cancel the card. Notification observers, not event monitors (R10).
    private func observeScrolls() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let clip = (note.object as? NSScrollView)?.contentView,
                      self.isAnchorScroll(clip) else { return }
                self.scrolled()
            }
        })
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let clip = note.object as? NSClipView else { return }
            MainActor.assumeIsolated {
                guard let self, self.shownAnchor != nil || self.pointerAnchor != nil, !self.inCard,
                      self.isAnchorScroll(clip) else { return }
                self.scrolled()
            }
        })
    }
}

// MARK: - Modifier

extension View {
    /// Contact hover card for this name/avatar (~1 s dwell).
    func contactHover(_ ref: ContactRef, arrowEdge: Edge = .trailing) -> some View {
        modifier(ContactHoverModifier(ref: ref, arrowEdge: arrowEdge))
    }

    /// Name-only form (senders, chat titles): the directory fills the id.
    func contactHover(name: String, userID: String? = nil, email: String? = nil,
                      arrowEdge: Edge = .trailing) -> some View {
        modifier(ContactHoverModifier(ref: ContactRef(name: name, userID: userID, email: email),
                                      arrowEdge: arrowEdge))
    }
}

struct ContactHoverModifier: ViewModifier {
    let ref: ContactRef
    var arrowEdge: Edge = .trailing
    var hover: ContactHover = .shared

    @Environment(\.windowModel) private var model
    @State private var anchor = UUID().uuidString
    @State private var anchorBox = PopoverAnchorBox()

    private var enabled: Bool {
        !ref.name.isEmpty && model?.app != nil && ContactHoverRules.isPerson(ref.name)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .background { PopoverAnchorReader(box: anchorBox) }
                .onHover { inside in hover.pointer(inside, anchor: anchor) }
                .onAppear { hover.claimPin(anchor: anchor, name: ref.name) }
                .popover(isPresented: Binding(
                    get: { hover.isShown(anchor) },
                    set: { if !$0, hover.isShown(anchor) { hover.dismiss() } }
                ), arrowEdge: arrowEdge) {
                    ContactHoverCard(ref: ref, hover: hover)
                        .background { PopoverWindowClamp(anchor: anchorBox) }
                        .environment(\.windowModel, model)
                        .onHover { hover.card($0) }
                }
        } else {
            content
        }
    }
}

/// Pure hover rules (unit-tested).
enum ContactHoverRules {
    /// Bots, feeds and placeholder senders get no card.
    static func isPerson(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.count > 1, n != "?", n.first?.isLetter == true else { return false }
        let lower = n.lowercased()
        return !(lower.hasSuffix(" bot") || lower.hasSuffix(" rss") || lower == "polly" || lower == "facilitator")
    }
}

// MARK: - Links (mentions) and model refs

/// `betterteams-contact:` links: mention runs carry one, and the
/// message text's openURL handler turns a click into the full card.
@MainActor
enum ContactLinks {
    static let scheme = "betterteams-contact"

    static func url(name: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.path = "person"
        c.queryItems = [URLQueryItem(name: "name", value: name.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")))]
        return c.url
    }

    static func name(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "name" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func open(_ url: URL, _ m: WindowModel?) -> OpenURLAction.Result {
        guard url.scheme == scheme else {
            // Every other link: Microsoft links on their native screen
            // (or refused), the rest to the system (TeamsLinkRouter).
            TeamsLinkRouter.open(url, window: m)
            return .handled
        }
        if let name = name(from: url), let m { ContactActions.openCard(ContactRef(name: name), m) }
        return .handled
    }
}

extension ContactRef {
    init(_ m: TeamMember) { self.init(name: m.displayName, userID: m.userId, email: m.email) }
}

/// Reports the card's popover window to the coordinator as the card
/// arrives in it, before its scroll view's first layout is delivered.
struct CardWindowReporter: NSViewRepresentable {
    let hover: ContactHover

    func makeNSView(context: Context) -> ReporterView { ReporterView(hover: hover) }
    func updateNSView(_ view: ReporterView, context: Context) {}

    final class ReporterView: NSView {
        let hover: ContactHover

        init(hover: ContactHover) {
            self.hover = hover
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { hover.noteCardWindow(window) }
        }
    }
}

// MARK: - Keep the card inside its window

/// Pure clamp (unit-tested): `frame` shifted so it lies inside `bounds`
/// (inset by `margin`); a frame larger than the bounds aligns to the top
/// (screen coordinates, y up) and leading edges.
enum PopoverClamp {
    static func clamped(_ frame: CGRect, in bounds: CGRect, margin: CGFloat = 6) -> CGRect {
        let box = bounds.insetBy(dx: margin, dy: margin)
        var out = frame
        if out.width > box.width { out.origin.x = box.minX }
        else { out.origin.x = min(max(out.origin.x, box.minX), box.maxX - out.width) }
        if out.height > box.height { out.origin.y = box.maxY - out.height }
        else { out.origin.y = min(max(out.origin.y, box.minY), box.maxY - out.height) }
        return out
    }
}

/// Placement (unit-tested): keep the card where AppKit put it when it is
/// inside `bounds` and clear of `anchor`; otherwise flip it to the other
/// side of the anchor (above, below, right, left; nearest first) and only
/// as a last resort clamp it (which may then overlap the anchor).
enum PopoverPlacement {
    static func place(_ frame: CGRect, anchor: CGRect?, in bounds: CGRect,
                      margin: CGFloat = 6, gap: CGFloat = 4) -> CGRect {
        let box = bounds.insetBy(dx: margin, dy: margin)
        let clamped = PopoverClamp.clamped(frame, in: bounds, margin: margin)
        guard let anchor, !anchor.isEmpty else { return clamped }
        func fits(_ r: CGRect) -> Bool { box.contains(r) && !r.intersects(anchor) }
        if fits(frame) { return frame }
        if fits(clamped) { return clamped }
        let w = frame.width, h = frame.height
        let x = min(max(frame.minX, box.minX), max(box.minX, box.maxX - w))
        let y = min(max(frame.minY, box.minY), max(box.minY, box.maxY - h))
        let above = CGRect(x: x, y: anchor.maxY + gap, width: w, height: h)
        let below = CGRect(x: x, y: anchor.minY - gap - h, width: w, height: h)
        let right = CGRect(x: anchor.maxX + gap, y: y, width: w, height: h)
        let left = CGRect(x: anchor.minX - gap - w, y: y, width: w, height: h)
        // Nearest side first: prefer the side the card already leans to.
        let vertFirst = abs(frame.midY - anchor.midY) >= abs(frame.midX - anchor.midX)
        let aboveFirst = frame.midY >= anchor.midY, rightFirst = frame.midX >= anchor.midX
        let vert = aboveFirst ? [above, below] : [below, above]
        let horiz = rightFirst ? [right, left] : [left, right]
        for c in (vertFirst ? vert + horiz : horiz + vert) where fits(c) { return c }
        return clamped
    }
}

/// Live screen frame of the popover's anchor view (read at clamp time so
/// it tracks scrolling).
@MainActor
final class PopoverAnchorBox {
    weak var view: NSView?
    var screenFrame: CGRect? {
        guard let v = view, let w = v.window else { return nil }
        return w.convertToScreen(v.convert(v.bounds, to: nil))
    }
}

struct PopoverAnchorReader: NSViewRepresentable {
    let box: PopoverAnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

/// A hover card is a popover window; AppKit only keeps it on screen, so
/// near a window edge it hangs off the app. This pins the popover's
/// window inside the window that hosts its anchor, re-checking whenever
/// the card resizes (its sections load in after the first frame).
struct PopoverWindowClamp: NSViewRepresentable {
    var anchor: PopoverAnchorBox?
    func makeNSView(context: Context) -> ClampView { let v = ClampView(); v.anchor = anchor; return v }
    func updateNSView(_ view: ClampView, context: Context) { view.anchor = anchor; view.clampSoon() }

    final class ClampView: NSView {
        var anchor: PopoverAnchorBox?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let popWindow = window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: popWindow, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.clamp() } })
            }
            clampSoon()
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func clampSoon() { DispatchQueue.main.async { [weak self] in self?.clamp() } }

        private func hostWindow(of pop: NSWindow) -> NSWindow? {
            if let p = pop.parent { return p }
            return NSApp.windows.first { $0 !== pop && ($0.childWindows?.contains(pop) ?? false) }
        }

        private func clamp() {
            guard let pop = window, let host = hostWindow(of: pop) else { return }
            let target = PopoverPlacement.place(pop.frame, anchor: anchor?.screenFrame, in: host.frame)
            guard abs(target.origin.x - pop.frame.origin.x) > 0.5
                || abs(target.origin.y - pop.frame.origin.y) > 0.5 else { return }
            pop.setFrameOrigin(target.origin)
        }
    }
}
