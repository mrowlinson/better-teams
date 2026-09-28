// Hosting.swift — the one hosting factory (UI-SPEC R22, DL7).
//
// `NSHostingController(` and `NSHostingView(` appear only here. Every
// host: `sceneBridgingOptions = []` (SwiftUI never touches the window
// title or toolbar); `sizingOptions` per role (panes `[]` so content
// never resizes split items or the window; sheets, popovers, Settings
// `[.preferredContentSize]`; overlay cells `[.intrinsicContentSize]`;
// timeline rows `[]`, filled to their explicit row height);
// `.focusEffectDisabled()` at the root (§10); and the environment that
// does not cross an AppKit boundary on its own (`ContentTextScale`,
// `WindowModel`).
import AppKit
import SwiftUI

public enum HostingRole: Sendable {
    case pane, sheet, popover, settings, cell
    /// A table row whose height is explicit (timeline): pinned to all
    /// four cell edges, so SwiftUI lays out at exactly the row height
    /// (no intrinsic size, which is width-agnostic and misplaces wrapped
    /// content).
    case row
}

/// The root every hosted view is wrapped in.
public struct HostedRoot<Content: View>: View {
    let content: Content
    let model: WindowModel?

    public var body: some View {
        content
            .focusEffectDisabled()
            .environment(\.windowModel, model)
            .environment(\.contentTextScale, model?.textScale ?? 1.0)
            // Evidence only: captures may run with the screen locked, where
            // no app can become active; content-layer SwiftUI renders with
            // the key-window appearance. AppKit chrome and the sidebar's
            // selection emphasis still draw inactive.
            .transformEnvironment(\.controlActiveState) { if model?.options.evidence == true { $0 = .key } }
    }
}

@MainActor
public enum Hosting {
    static func sizing(_ role: HostingRole) -> NSHostingSizingOptions {
        switch role {
        case .pane, .row: []
        case .sheet, .popover, .settings: [.preferredContentSize]
        case .cell: [.intrinsicContentSize]
        }
    }

    public static func root<V: View>(_ v: V, model: WindowModel?) -> HostedRoot<V> {
        HostedRoot(content: v, model: model)
    }

    public static func controller<V: View>(_ v: V, role: HostingRole, model: WindowModel?)
        -> NSHostingController<HostedRoot<V>>
    {
        let c = NSHostingController(rootView: root(v, model: model))
        c.sceneBridgingOptions = []
        c.sizingOptions = sizing(role)
        return c
    }

    public static func view<V: View>(_ v: V, role: HostingRole, model: WindowModel?)
        -> NSHostingView<HostedRoot<V>>
    {
        let h = NSHostingView(rootView: root(v, model: model))
        h.sceneBridgingOptions = []
        h.sizingOptions = sizing(role)
        return h
    }
}

private struct WindowModelKey: EnvironmentKey {
    static let defaultValue: WindowModel? = nil
}

private struct ContentTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// The window this view lives in (injected by `Hosting`).
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }

    /// Text size (§10): scales `AppFont` styles in lists, timeline,
    /// composer. The rail follows the system sidebar icon size instead.
    var contentTextScale: Double {
        get { self[ContentTextScaleKey.self] }
        set { self[ContentTextScaleKey.self] = newValue }
    }
}
