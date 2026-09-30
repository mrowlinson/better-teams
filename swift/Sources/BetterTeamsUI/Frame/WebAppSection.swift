// WebAppSection.swift — the one SectionProvider for every web app
// (UI-SPEC §5.3: layout `.full`, detail = the frame, no inspector).
// Opens in the main window's content area exactly like a built-in
// section: no popout, no second window. Toolbar (§7.3): Back / Forward
// (⌘[ / ⌘]), Reload (⌘R; Stop ⌘. in the menu), More ▾. Subtitle = page
// title. ⌘F turns the toolbar field into Find in Page.
import AppKit
import OstMacCore
import SwiftUI
import WebKit

@MainActor
final class WebAppSection: SectionProvider {
    let appID: FrameAppID
    let section: SectionID

    init(appID: FrameAppID) {
        self.appID = appID
        section = .web(appID)
    }

    var title: String { FrameAppDirectory.title(appID) }
    var key: FrameKey { .app(appID) }

    func layout(_ sel: SectionSelection?) -> SectionLayout { .full }

    func subtitle(_ m: WindowModel) -> String {
        guard let p = m.frameHost.page(key), p.pageTitle != title else { return "" }
        return p.pageTitle
    }

    /// Collapsed in `.full`; never shown.
    func listPane(_ m: WindowModel) -> AnyView { AnyView(Color.clear) }

    func detailPane(_ m: WindowModel) -> AnyView { AnyView(WebAppDetail(appID: appID)) }

    var allToolbarItems: [CommandID] {
        [AppsCommands.back, AppsCommands.forward, AppsCommands.reload, AppsCommands.more]
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        if let app = m.frameHost.library.app(appID) { m.frameHost.registerApp(app) }
    }

    // MARK: commands (forwarded by AppsSection)

    private var entry: RailEntry { .web(appID) }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        let w = m.frameHost.webView(key)
        switch c {
        case AppsCommands.back: w?.goBack()
        case AppsCommands.forward: w?.goForward()
        case AppsCommands.reload: m.frameHost.reload(key)
        case AppsCommands.stop: w?.stopLoading()
        case AppsCommands.more: more(arg, m)
        default: return false
        }
        return true
    }

    private func more(_ arg: String?, _ m: WindowModel) {
        typealias A = AppsCommands.MoreArg
        switch arg {
        case A.actualSize: zoom(.actual, m)
        case A.zoomIn: zoom(.in, m)
        case A.zoomOut: zoom(.out, m)
        case A.find: m.navigator?.focusSearch(.conversation)
        case A.copyLink:
            guard let url = pageURL(m) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        case A.openInBrowser:
            if !m.options.demo, let url = pageURL(m) { TeamsLinkRouter.openInBrowser(url) }
        case A.unload:
            m.navigator?.returnToPrevious()
            m.frameHost.unload(key)
        case A.unpin: m.navigator?.unpin(entry)
        case A.keep: m.rail.pin(entry)
        default: break
        }
    }

    /// The page's current URL (the app URL for local demo pages).
    private func pageURL(_ m: WindowModel) -> URL? {
        if let u = m.frameHost.webView(key)?.url, u.scheme == "https" || u.scheme == "http" { return u }
        return m.frameHost.page(key)?.url
    }

    enum Zoom { case actual, `in`, out }

    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func zoom(_ z: Zoom, _ m: WindowModel) {
        guard let w = m.frameHost.webView(key) else { return }
        let cur = w.pageZoom
        switch z {
        case .actual: w.pageZoom = 1
        case .in: w.pageZoom = Self.zoomSteps.first { $0 > cur + 0.001 } ?? cur
        case .out: w.pageZoom = Self.zoomSteps.last { $0 < cur - 0.001 } ?? cur
        }
    }

    func canZoom(_ z: Zoom, _ m: WindowModel) -> Bool {
        guard let w = m.frameHost.webView(key) else { return false }
        switch z {
        case .actual: return abs(w.pageZoom - 1) > 0.001
        case .in: return w.pageZoom < Self.zoomSteps.last! - 0.001
        case .out: return w.pageZoom > Self.zoomSteps.first! + 0.001
        }
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        let w = m.frameHost.webView(key)
        switch c {
        case AppsCommands.back: return CommandValidation(enabled: w?.canGoBack ?? false)
        case AppsCommands.forward: return CommandValidation(enabled: w?.canGoForward ?? false)
        case AppsCommands.reload:
            // Nothing to reload on the browser-only pane ("Opens in Your
            // Browser"): only an in-app page with a view reloads.
            let inApp = m.frameHost.library.app(appID)?.launch.runsInApp ?? false
            return CommandValidation(enabled: inApp && w != nil)
        case AppsCommands.stop: return CommandValidation(enabled: w?.isLoading ?? false)
        case AppsCommands.more: return .enabled
        default: return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        guard c == AppsCommands.more else { return [] }
        typealias A = AppsCommands.MoreArg
        let loaded = m.frameHost.webView(key) != nil
        let pinned = m.rail.pinned.contains(entry)
        return [
            SubmenuItem("Actual Size", arg: A.actualSize, enabled: canZoom(.actual, m)),
            SubmenuItem("Zoom In", arg: A.zoomIn, enabled: canZoom(.in, m)),
            SubmenuItem("Zoom Out", arg: A.zoomOut, enabled: canZoom(.out, m)),
            SubmenuItem("Find in Page", arg: A.find, enabled: loaded, separatorBefore: true),
            SubmenuItem("Copy Link", arg: A.copyLink, separatorBefore: true),
            SubmenuItem("Open in Browser", arg: A.openInBrowser, enabled: !m.options.demo),
            SubmenuItem("Unload App", arg: A.unload, enabled: loaded, separatorBefore: true),
            pinned ? SubmenuItem("Unpin from Tab Bar", arg: A.unpin)
                : SubmenuItem("Keep in Tab Bar", arg: A.keep),
        ]
    }
}

/// The web app's detail pane.
private struct WebAppDetail: View {
    let appID: FrameAppID
    @Environment(\.windowModel) private var model

    var body: some View {
        if let m = model {
            if let app = m.frameHost.library.app(appID) {
                content(app, m)
            } else {
                EmptyPane("App Unavailable", systemImage: "questionmark.square.dashed",
                          message: "This app is no longer in your library.") {
                    Button("Show Apps") { m.navigator?.select(section: .apps) }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ app: FrameApp, _ m: WindowModel) -> some View {
        if app.launch.runsInApp {
            // Registration is idempotent and not observed (safe in body).
            let _ = m.frameHost.registerApp(app)
            FrameContainer(key: .app(appID), forced: m.forced(.web(appID)))
        } else {
            EmptyPane("Opens in Your Browser", systemImage: "arrow.up.forward.app",
                      message: "\(app.label) can't run inside Better Teams.") {
                Button("Open in Browser") { TeamsLinkRouter.openInBrowser(app.launch.url) }
                    .disabled(m.options.demo)
            }
        }
    }
}
