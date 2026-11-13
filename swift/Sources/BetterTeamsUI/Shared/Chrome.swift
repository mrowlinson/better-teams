// Chrome.swift — the one switch between Liquid Glass and the plain
// standard macOS look for the control layer (GLASS lane).
//
// Glass APIs (`glassEffect`, `GlassEffectContainer`, the glass button
// styles, `NSGlassEffectView`) appear only in this file. Every
// control-layer site that wears glass names its `ChromeSite` and goes
// through `Chrome`; content (messages, rows, tables, the calendar grid,
// documents) never does. Settings ▸ Appearance ▸ Glass-free swaps every
// site to the plain standard look live: SwiftUI sites re-render through
// Observation, AppKit sites re-apply through `Chrome.observe`. The
// system's Reduce Transparency is not a switch here: AppKit already
// renders glass frosted and more opaque under it.
import AppKit
import Combine
import SwiftUI

/// Every control-layer site that can wear glass. The guard checks each
/// case is used outside this file and resolves differently per mode.
enum ChromeSite: String, CaseIterable, Sendable {
    /// Bordered toolbar buttons: main, pop-out chat and call windows.
    case toolbarItems
    /// The left app rail (a floating glass pane on the sidebar material).
    case rail
    /// "Jump to latest" over the timeline.
    case jumpToLatest
    /// Pinned message bar above the conversation.
    case pinnedMessageBar
    /// The hover action bar floating over a message.
    case messageHoverBar
    /// The composer's text field box.
    case composerField
    /// Play/pause over an animated GIF.
    case mediaPlayButton
    /// The image viewer's floating control bar.
    case imageViewerBar
    /// Name chips over call video tiles.
    case callNameChip
}

/// What a site draws in one mode (pure: the guard checks the mapping).
enum ChromeLook: Equatable, Sendable {
    /// Liquid Glass (regular variant).
    case glass
    /// The standard material the site used before glass.
    case material(NSVisualEffectView.Material)
    /// A standard bordered control (button sites).
    case bordered
    /// The site's own plain fill (window background, fill + separator).
    case plainFill
    /// Plain borderless toolbar items (system toolbar, no glass capsule).
    case borderless
}

@MainActor
enum Chrome {
    /// Glass unless Glass-free is on.
    nonisolated static func usesGlass(glassFree: Bool) -> Bool {
        !glassFree
    }

    /// The live answer for AppKit sites.
    static var usesGlass: Bool {
        usesGlass(glassFree: AppSettings.shared.glassFree)
    }

    /// The look each site draws per mode.
    nonisolated static func look(_ site: ChromeSite, glass: Bool) -> ChromeLook {
        if glass { return .glass }
        switch site {
        case .toolbarItems: return .borderless
        case .rail: return .material(.sidebar)
        case .jumpToLatest: return .bordered
        case .pinnedMessageBar: return .material(.headerView)
        case .messageHoverBar, .composerField, .callNameChip: return .plainFill
        case .mediaPlayButton: return .material(.hudWindow)
        case .imageViewerBar: return .material(.popover)
        }
    }

    /// Calls `apply` with the current mode now and whenever Glass-free
    /// changes. Keep the returned token alive.
    static func observe(_ apply: @escaping @MainActor (Bool) -> Void) -> AnyCancellable {
        apply(usesGlass)
        // Delivered synchronously on main (settings change there), so a
        // flip re-renders in the same turn; `apply` must be idempotent.
        return AppSettings.shared.changes
            .sink { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { apply(usesGlass) }
                } else {
                    DispatchQueue.main.async { apply(usesGlass) }
                }
            }
    }

    // MARK: AppKit

    /// Toolbar buttons: glass capsules, or plain borderless items. Custom
    /// views, search, separators, segmented groups and the `.prominent`
    /// item (Leave) keep their own look.
    static func apply(_ site: ChromeSite, glass: Bool, to items: [NSToolbarItem]) {
        let bordered = look(site, glass: glass) == .glass
        for item in items where item.view == nil && !(item is NSSearchToolbarItem)
            && !(item is NSTrackingSeparatorToolbarItem) && !(item is NSToolbarItemGroup)
            && item.style != .prominent && item.itemIdentifier != .flexibleSpace
            && item.itemIdentifier != .space {
            item.isBordered = bordered
        }
    }
}

/// An AppKit backing for a floating control: `NSGlassEffectView` in
/// glass mode, the site's standard material otherwise. Swaps live.
@MainActor
final class ChromeBackgroundView: NSView {
    let site: ChromeSite
    let cornerRadius: CGFloat
    /// The hosted controls; re-parented into whichever backing is live.
    let contentView: NSView
    /// Glass mode only: the glass pane floats this far inside the bounds.
    let glassInset: CGFloat
    /// Plain mode draws no backing of its own: the content sits directly
    /// on whatever the superview draws (the rail on its sidebar material).
    let plainBacking: Bool
    private var backing: NSView?
    private var token: AnyCancellable?
    private(set) var isGlass = false

    init(site: ChromeSite, cornerRadius: CGFloat, contentView: NSView,
         glassInset: CGFloat = 0, plainBacking: Bool = true) {
        self.site = site
        self.cornerRadius = cornerRadius
        self.contentView = contentView
        self.glassInset = glassInset
        self.plainBacking = plainBacking
        super.init(frame: .zero)
        token = Chrome.observe { [weak self] in self?.install(glass: $0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    private func install(glass: Bool) {
        if backing != nil, glass == isGlass { return }
        isGlass = glass
        backing?.removeFromSuperview()
        contentView.removeFromSuperview()
        let next: NSView
        var inset: CGFloat = 0
        if glass {
            inset = glassInset
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            g.contentView = contentView
            next = g
        } else if !plainBacking {
            next = contentView
        } else {
            let m = NSVisualEffectView()
            if case .material(let mat) = Chrome.look(site, glass: false) { m.material = mat }
            m.blendingMode = site == .rail ? .behindWindow : .withinWindow
            // The image viewer bar stayed active in a background window.
            m.state = site == .imageViewerBar ? .active : .followsWindowActiveState
            m.wantsLayer = cornerRadius > 0
            m.layer?.cornerRadius = cornerRadius
            m.layer?.masksToBounds = cornerRadius > 0
            contentView.translatesAutoresizingMaskIntoConstraints = false
            m.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: m.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: m.bottomAnchor),
                contentView.leadingAnchor.constraint(equalTo: m.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: m.trailingAnchor),
            ])
            next = m
        }
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            next.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            next.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            next.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        backing = next
    }
}

// MARK: SwiftUI

extension View {
    /// A floating control's background: glass in `shape`, or the site's
    /// plain look (`plain`, the fill it drew before glass).
    func chromeBackground<S: Shape, P: View>(_ site: ChromeSite, in shape: S,
                                             @ViewBuilder plain: () -> P) -> some View {
        modifier(ChromeBackground(site: site, shape: shape, plain: plain()))
    }

    /// A bar across the top of a pane: an inset floating glass rounded
    /// rect, or the plain full-width bar material with a hairline below.
    func chromeBar(_ site: ChromeSite, cornerRadius: CGFloat = 10, inset: CGFloat = 8) -> some View {
        modifier(ChromeBarModifier(site: site, cornerRadius: cornerRadius, inset: inset))
    }

    /// A floating control's button style: `.glass`, or `.bordered`.
    func chromeButtonStyle(_ site: ChromeSite) -> some View {
        modifier(ChromeButton(site: site))
    }
}

/// The SwiftUI mode: Glass-free, observed (re-renders on a flip).
private struct ChromeMode {
    @MainActor static var glass: Bool {
        Chrome.usesGlass(glassFree: AppSettings.shared.glassFree)
    }
}

private struct ChromeBackground<S: Shape, P: View>: ViewModifier {
    let site: ChromeSite
    let shape: S
    let plain: P

    func body(content: Content) -> some View {
        if ChromeMode.glass {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background { plain }
        }
    }
}

private struct ChromeButton: ViewModifier {
    let site: ChromeSite

    func body(content: Content) -> some View {
        if ChromeMode.glass {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct ChromeBarModifier: ViewModifier {
    let site: ChromeSite
    let cornerRadius: CGFloat
    let inset: CGFloat

    func body(content: Content) -> some View {
        if ChromeMode.glass {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .padding(.horizontal, inset)
                .padding(.top, inset)
                .padding(.bottom, inset / 2)
        } else {
            VStack(spacing: 0) {
                content
                Divider()
            }
            .background(.bar)
        }
    }
}
