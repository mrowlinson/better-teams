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

    /// Live scrolls (trackpad) and clip-view moves (wheel, programmatic)
    /// cancel the card. Notification observers, not event monitors (R10).
    private func observeScrolls() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard note.object is NSClipView else { return }
            MainActor.assumeIsolated {
                guard let self, self.shownAnchor != nil || self.pointerAnchor != nil, !self.inCard else { return }
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

    private var enabled: Bool {
        !ref.name.isEmpty && model?.app != nil && ContactHoverRules.isPerson(ref.name)
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .onHover { inside in hover.pointer(inside, anchor: anchor) }
                .onAppear { hover.claimPin(anchor: anchor, name: ref.name) }
                .popover(isPresented: Binding(
                    get: { hover.isShown(anchor) },
                    set: { if !$0, hover.isShown(anchor) { hover.dismiss() } }
                ), arrowEdge: arrowEdge) {
                    ContactHoverCard(ref: ref, hover: hover)
                        .background { PopoverWindowClamp() }
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
        guard url.scheme == scheme else { return .systemAction }
        if let name = name(from: url), let m { ContactActions.openCard(ContactRef(name: name), m) }
        return .handled
    }
}

extension ContactRef {
    init(_ m: TeamMember) { self.init(name: m.displayName, userID: m.userId, email: m.email) }
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

/// A hover card is a popover window; AppKit only keeps it on screen, so
/// near a window edge it hangs off the app. This pins the popover's
/// window inside the window that hosts its anchor, re-checking whenever
/// the card resizes (its sections load in after the first frame).
struct PopoverWindowClamp: NSViewRepresentable {
    func makeNSView(context: Context) -> ClampView { ClampView() }
    func updateNSView(_ view: ClampView, context: Context) { view.clampSoon() }

    final class ClampView: NSView {
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
            let target = PopoverClamp.clamped(pop.frame, in: host.frame)
            guard abs(target.origin.x - pop.frame.origin.x) > 0.5
                || abs(target.origin.y - pop.frame.origin.y) > 0.5 else { return }
            pop.setFrameOrigin(target.origin)
        }
    }
}
