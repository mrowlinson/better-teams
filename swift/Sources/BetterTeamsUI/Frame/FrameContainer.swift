// FrameContainer.swift — cross-lane seam (UI-SPEC §7.3, §11.3). Final
// signature. Shows FrameHost's keyed web view for channel web tabs
// (`tab:<id>`) and web apps (`app:<id>`), with the load states over it:
// loading (spinner until first paint, then a thin determinate bar),
// "Couldn't Load ‹App›" with Try Again / Open in Browser, and offline.
import AppKit
import SwiftUI
import WebKit

/// `app:<id>` or `tab:<id>` (§7.3).
public struct FrameKey: Hashable, Sendable {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public static func app(_ id: FrameAppID) -> FrameKey { FrameKey("app:\(id)") }
    public static func tab(_ id: String) -> FrameKey { FrameKey("tab:\(id)") }
}

public struct FrameContainer: View {
    public let key: FrameKey
    /// Evidence-forced state (web apps, demo only).
    var forced: ForcedPaneState?
    @Environment(\.windowModel) private var model

    public init(key: FrameKey) { self.key = key }

    init(key: FrameKey, forced: ForcedPaneState?) {
        self.key = key
        self.forced = forced
    }

    public var body: some View {
        if let m = model, let page = m.frameHost.page(key) {
            FrameContent(page: page, host: m.frameHost, forced: forced,
                         connectionOffline: m.connection == .offline, demo: m.options.demo)
        } else {
            // Registered by its owner in the same pass (channel tabs load
            // their list first).
            LoadingPane()
        }
    }
}

/// The web view plus its state overlay.
private struct FrameContent: View {
    let page: FramePage
    let host: FrameHost
    let forced: ForcedPaneState?
    let connectionOffline: Bool
    let demo: Bool

    var body: some View {
        ZStack(alignment: .top) {
            FrameWebView(key: page.key, host: host)
            overlay
        }
    }

    private var offline: Bool {
        if case .failed(_, true) = page.state { return true }
        return connectionOffline && (demo || !page.committed)
    }

    @ViewBuilder
    private var overlay: some View {
        if forced == .error {
            failure("A server with the specified hostname could not be found.")
        } else if case .failed(let message, false) = page.state {
            failure(message)
        } else if offline {
            EmptyPane("You're Offline", systemImage: "wifi.slash",
                      message: "\(page.title) will load when you're back online.") {
                Button("Try Again") { host.retry(page.key) }
            }
            .background(.background)
        } else if forced == .loading || !page.committed {
            LoadingPane()
                .background(.background)
                .accessibilityLabel("Loading \(page.title)")
        } else if page.state == .loading {
            ProgressView(value: page.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel("Loading \(page.title)")
        }
    }

    private func failure(_ message: String) -> some View {
        EmptyPane("Couldn't Load \(page.title)", systemImage: "exclamationmark.triangle", message: message) {
            // Each button at its own width: the empty-state action slot
            // otherwise squeezes them to equal widths ("Open in Brow…").
            HStack {
                Button("Retry") { host.retry(page.key) }
                Button("Open in Browser") { NSWorkspace.shared.open(page.url) }
                    .disabled(demo)
            }
            .fixedSize()
        }
        .background(.background)
    }
}

/// The container a FrameHost view is attached to (§7.3): reports
/// window moves, because a hidden pane child is off-window without
/// being dismantled.
final class FrameContainerView: NSView {
    var key: FrameKey
    weak var host: FrameHost?

    init(key: FrameKey, host: FrameHost) {
        self.key = key
        self.host = host
        super.init(frame: .zero)
        // A per-app crop outsets the web view past these bounds (§7.3).
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        host?.containerMoved(key, self)
    }
}

/// `makeNSView` = empty container; `updateNSView` = attach (moving the
/// view from any other parent); `dismantleNSView` = detach (never destroy).
private struct FrameWebView: NSViewRepresentable {
    let key: FrameKey
    let host: FrameHost

    func makeNSView(context: Context) -> FrameContainerView {
        FrameContainerView(key: key, host: host)
    }

    func updateNSView(_ v: FrameContainerView, context: Context) {
        if v.key != key {
            host.detach(v.key, from: v)
            v.key = key
        }
        host.attach(key, to: v)
    }

    static func dismantleNSView(_ v: FrameContainerView, coordinator: ()) {
        v.host?.detach(v.key, from: v)
    }
}
