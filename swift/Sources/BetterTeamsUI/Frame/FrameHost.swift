// FrameHost.swift — owns every WKWebView for one account window
// (UI-SPEC §7.3, R16). `WKWebView(` appears only in this file.
//
// Keys: `app:<id>` (pinned/transient web apps) and `tab:<id>` (channel
// web tabs). `attach` puts a key's view in a container (one parent,
// ever); `detach` removes it without destroying it, so the same
// instance returns on the next visit (no reload, R16). Views not in a
// window are LRU-evicted beyond the keep-in-memory cap (Low 1 /
// Balanced 3 / High 6); warm views past the keep-alive are suspended;
// memory pressure evicts early. All checks run on attach/detach events
// and pressure notifications — no timers, no polling.
//
// Data store: one persistent `WKWebsiteDataStore(forIdentifier:)` per
// account, shared by the sign-in sheet and every frame. Before the
// first frame load, a one-time migration copies the Microsoft session
// cookies of the old default jar into it (TeamsFrameSSO, 5 s gate).
// No WKProcessPool. Demo never touches disk or network: a
// non-persistent store and local placeholder pages.
import AppKit
import OstMacCore
import WebKit

/// Load state a frame shows (§7.3 "Load failure").
public enum FrameLoadState: Equatable, Sendable {
    case idle, loading, loaded
    case failed(message: String, offline: Bool)
}

/// One keyed page: its web view (while resident) and observable load
/// state. Navigation, UI and download delegate for its view.
@Observable
@MainActor
public final class FramePage: NSObject {
    @ObservationIgnored public let key: FrameKey
    @ObservationIgnored public private(set) var url: URL
    @ObservationIgnored public private(set) var title: String
    @ObservationIgnored fileprivate(set) var web: WKWebView?
    @ObservationIgnored fileprivate var lastUsed = Date.distantPast
    @ObservationIgnored fileprivate var suspended = false
    /// Saved at eviction; restores back/forward and scroll state.
    @ObservationIgnored fileprivate var savedInteraction: Any?
    @ObservationIgnored fileprivate var savedURL: URL?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored fileprivate weak var host: FrameHost?
    /// Running downloads → their Transfers entry (§7.3, Files ▸ Downloads).
    @ObservationIgnored fileprivate var downloads: [ObjectIdentifier: (id: String, dest: URL?, obs: NSKeyValueObservation?)] = [:]

    public fileprivate(set) var state: FrameLoadState = .idle
    /// True once the first page has committed (first paint).
    public fileprivate(set) var committed = false
    public fileprivate(set) var progress: Double = 0
    public fileprivate(set) var pageTitle = ""
    /// The page's last on-screen picture (taken as its view leaves the
    /// window). A page re-created after eviction shows it, under the
    /// progress line, until the restore finishes: never a blank or white
    /// pane on app switch.
    public fileprivate(set) var snapshot: NSImage?
    /// The view was re-created from saved state and has not finished
    /// loading yet (the snapshot stands in until it does).
    public fileprivate(set) var restoring = false

    init(key: FrameKey, url: URL, title: String) {
        self.key = key
        self.url = url
        self.title = title
    }

    fileprivate func update(url: URL, title: String) -> Bool {
        self.title = title
        guard url != self.url else { return false }
        self.url = url
        return true
    }

    /// A web view exists (Settings ▸ Apps ▸ apps in memory).
    public var isResident: Bool { web != nil }
    /// Shown in a window right now.
    public var isOnScreen: Bool { web?.window != nil }
    public var canGoBack: Bool { web?.canGoBack ?? false }
    public var canGoForward: Bool { web?.canGoForward ?? false }
    public var isLoading: Bool { web?.isLoading ?? false }

    fileprivate func observe(_ w: WKWebView) {
        // KVO fires on the main thread for WKWebView; hop explicitly.
        observations = [
            w.observe(\.estimatedProgress) { [weak self] v, _ in
                let value = v.estimatedProgress
                Task { @MainActor in self?.progress = value }
            },
            w.observe(\.title) { [weak self] v, _ in
                let value = v.title ?? ""
                Task { @MainActor in
                    self?.pageTitle = value
                    self?.host?.pageChanged(self)
                }
            },
            w.observe(\.canGoBack) { _, _ in Task { @MainActor in NSApp.setWindowsNeedUpdate(true) } },
            w.observe(\.canGoForward) { _, _ in Task { @MainActor in NSApp.setWindowsNeedUpdate(true) } },
            w.observe(\.isLoading) { _, _ in Task { @MainActor in NSApp.setWindowsNeedUpdate(true) } },
        ]
    }

    fileprivate func stopObserving() { observations = [] }
}

// MARK: - WKNavigationDelegate

extension FramePage: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let host else { return decisionHandler(.allow) }
        if action.shouldPerformDownload { return decisionHandler(.download) }
        let scheme = url.scheme?.lowercased() ?? ""
        if host.isDemo {
            // Demo: no network, ever.
            return decisionHandler(scheme == "about" || scheme == "data" ? .allow : .cancel)
        }
        let main = action.targetFrame?.isMainFrame ?? true
        if main, !host.isAllowed(url, for: self) {
            // §7.3 navigation policy: leave the frame for the browser.
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state = .loading
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed = true
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        committed = true
        restoring = false
        state = .loaded
        host?.probeChrome(self)
        host?.hostedDidFinish(self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        fail(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        restoring = false
        state = .failed(message: "The page stopped unexpectedly.", offline: false)
    }

    private func fail(_ error: Error) {
        let e = error as NSError
        // Cancelled / interrupted by a policy decision (download, browser hand-off).
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }
        if e.domain == WKErrorDomain || e.domain == "WebKitErrorDomain", e.code == 102 { return }
        restoring = false
        let offline = e.domain == NSURLErrorDomain && [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
        ].contains(e.code)
        state = .failed(message: e.localizedDescription, offline: offline)
    }
}

// MARK: - WKUIDelegate (popups, permissions)

extension FramePage: WKUIDelegate {
    /// §7.3 popups: auth hosts open in a sheet around a child view made
    /// here (R16); other allowed hosts load in place; anything else goes
    /// to the default browser. No popup windows, ever.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url, let host, !host.isDemo else { return nil }
        if FrameHost.isAuthHost(url) {
            return host.presentPopup(configuration: configuration, opener: self)
        }
        if host.isAllowed(url, for: self) {
            webView.load(action.request)
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        host?.closePopup(webView)
    }

    /// Calls are native: web apps never get the camera or microphone.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

// MARK: - WKDownloadDelegate (§7.3 downloads → ~/Downloads)

extension FramePage: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let dir = host?.downloadsFolder ?? TeamsFrameDownloads.defaultDirectory()
        let name = TeamsFrameDownloads.sanitizedFilename(suggestedFilename)
        var dest = dir.appendingPathComponent(name)
        var n = 1
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        // Listed in Files ▸ Downloads and the Transfers popover.
        if let transfers = host?.window?.app?.transfers {
            let size = response.expectedContentLength > 0 ? UInt64(response.expectedContentLength) : 0
            let id = transfers.begin(FileTransfer(name: dest.lastPathComponent, direction: .download,
                                                  origin: title, path: dest.path, size: size, progress: 0))
            let obs = download.progress.observe(\.fractionCompleted) { [weak transfers] p, _ in
                let f = p.fractionCompleted
                Task { @MainActor in transfers?.update(id, progress: f) }
            }
            downloads[ObjectIdentifier(download)] = (id, dest, obs)
        }
        completionHandler(dest)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let d = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        d.obs?.invalidate()
        let size = d.dest.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64 }
        host?.window?.app?.transfers.finish(d.id, path: d.dest?.path, size: size)
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let d = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        d.obs?.invalidate()
        host?.window?.app?.transfers.fail(d.id, message: error.localizedDescription)
    }
}

// MARK: - chrome route relay

/// Receives a Teams page's in-page route changes (`FrameChromeStyle`
/// route hook). Weak to its page: the content controller retains it.
@MainActor
private final class FrameChromeRouteRelay: NSObject, WKScriptMessageHandler {
    weak var page: FramePage?
    init(_ page: FramePage) { self.page = page }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let page else { return }
        page.host?.probeChrome(page)
    }
}

// MARK: - FrameHost

@MainActor
public final class FrameHost {
    public let accountKey: String
    /// The Apps library (§7.2); loaded at window creation so pinned web
    /// apps have their names before the rail first draws.
    let library: AppsLibrary
    /// The window this host serves (title refresh, popups, connection).
    weak var window: WindowModel?
    private var pages: [String: FramePage] = [:]
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Popup child views shown in the auth sheet.
    private var popup: WKWebView?
    /// Loads waiting for the one-time SSO migration.
    private var ssoWaiting: [FramePage]?
    /// Manifest apps hosted natively over TeamsJS (APPHOST), by key.
    private var hosted: [String: TeamsAppLaunch] = [:]
    /// The TeamsJS host of each resident hosted view, by key.
    private var jsHosts: [String: TeamsJSHost] = [:]
    /// Apps switched to their Teams-shell page this session (native
    /// host auth failed for good; retried next launch).
    private(set) var fallbackApps: Set<FrameAppID> = []
    private var identityCache: TeamsAppIdentity?
    private lazy var broker: TeamsJSTokenBroker = isDemo ? DemoTokenBroker() : CoreTokenBroker(profile: accountKey)

    /// Non-visible views kept resident (§7.3: 1 / 3 default / 6).
    var keepInMemory: Int
    /// Warm → suspended after this long (`teamsFrameKeepAliveMinutes`).
    var keepAlive: TimeInterval
    /// Settings ▸ Apps ▸ Downloads folder (§7.3 downloads).
    var downloadsFolder: URL
    /// Settings ▸ Apps ▸ Hide the Teams header and app bar (§7.3 chrome
    /// hiding): Teams-hosted pages get the `FrameChromeStyle` sheet.
    var hideChrome: Bool {
        didSet { if hideChrome != oldValue { applyChromeStyle() } }
    }
    /// Per-app crops (§7.3 fallback), keyed by `FrameKey.raw`; absent = none.
    private(set) var crops: [String: TeamsFrameCrop]
    /// Chrome the measure probe still saw after the last load or route
    /// change, keyed by `FrameKey.raw`; absent = hidden or not measured.
    private(set) var measured: [String: TeamsFrameCrop] = [:]

    static let downloadsFolderKey = "bt.frame.downloadsFolder"

    public init(accountKey: String) {
        self.accountKey = accountKey
        library = AppsLibrary(accountKey: accountKey)
        let demo = accountKey == "demo"
        keepInMemory = demo ? 3 : FramePolicy.keepInMemory()
        keepAlive = demo ? 15 * 60 : TimeInterval(TeamsFrameConfig.keepAliveMinutes(defaults: .standard) * 60)
        let saved = demo ? nil : UserDefaults.standard.string(forKey: Self.downloadsFolderKey)
        downloadsFolder = saved.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TeamsFrameDownloads.defaultDirectory()
        hideChrome = demo ? true : FrameChromeStyle.hideChrome(defaults: .standard)
        crops = demo ? [:] : FrameChromeStyle.loadCrops(defaults: .standard)
    }

    var isDemo: Bool { accountKey == "demo" }

    /// One persistent store per account; demo never touches disk.
    public private(set) lazy var dataStore: WKWebsiteDataStore = {
        if isDemo { return .nonPersistent() }
        return WKWebsiteDataStore(forIdentifier: Self.storeUUID(accountKey))
    }()

    /// Stable per-account store identifier (created once, persisted).
    static func storeUUID(_ account: String) -> UUID {
        let key = "bt.webStore.\(account)"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    // MARK: registration

    /// Declares a channel web tab's page; idempotent.
    public func registerTab(_ key: FrameKey, url: URL, title: String) {
        register(key, url: url, title: title)
    }

    /// Declares a web app's page (`app:<id>`); idempotent.
    public func registerApp(_ app: FrameApp) {
        let key = FrameKey.app(app.id)
        if case .teamsApp(var l) = app.launch, !fallbackApps.contains(app.id) {
            l.transport = TeamsJSTransportChoice.resolve(l, demo: isDemo)
            hosted[key.raw] = l
            // Theme-free expansion: a theme change must not reload.
            let url = URL(string: TeamsJSPolicy.expand(l.contentTemplate, appContext(l, theme: "default")))
            register(key, url: url ?? l.fallback, title: app.label)
        } else {
            hosted[key.raw] = nil
            register(key, url: app.launch.url, title: app.label)
        }
    }

    /// Declares a channel tab served by a catalog app (`tab:<id>`), hosted
    /// natively with channel context (APPHOST-B2). Idempotent: called from
    /// view bodies, so an unchanged launch never re-registers (session
    /// placeholders would otherwise change the URL and reload).
    public func registerHostedTab(_ key: FrameKey, launch: TeamsAppLaunch, title: String) {
        if fallbackApps.contains(launch.appID) {
            register(key, url: launch.fallback, title: title)
            return
        }
        var l = launch
        l.transport = TeamsJSTransportChoice.resolve(l, demo: isDemo)
        if pages[key.raw] != nil, let cur = hosted[key.raw], cur.appID == l.appID,
           cur.contentTemplate == l.contentTemplate, cur.channel == l.channel {
            return
        }
        hosted[key.raw] = l
        let url = URL(string: TeamsJSPolicy.expand(l.contentTemplate, appContext(l, theme: "default")))
        register(key, url: url ?? l.fallback, title: title)
    }

    /// Host mode changed in the app card: re-host every resident view of
    /// the app with the transport it now resolves to.
    func hostModeChanged(appID: String) {
        for (raw, l) in hosted where l.appID == appID {
            let t = TeamsJSTransportChoice.resolve(l, demo: isDemo)
            if t != l.transport, let key = pages[raw]?.key { rehost(key, transport: t) }
        }
    }

    /// Automatic host mode: a frameless page that has not initialized
    /// TeamsJS 8 s after loading gets one try in the iframe transport; an
    /// iframe try that also stays silent goes back to frameless for good.
    /// The first transport that initializes is remembered per app.
    func hostedDidFinish(_ p: FramePage) {
        guard let l = hosted[p.key.raw], let js0 = jsHosts[p.key.raw],
              TeamsJSTransportChoice.mode(l.appID, demo: isDemo) == .automatic else { return }
        let learned = TeamsJSTransportChoice.learned(l.appID, demo: isDemo)
        if js0.initialized {
            if learned == nil { TeamsJSTransportChoice.learn(l.transport, app: l.appID, demo: isDemo) }
            return
        }
        guard learned != .frameless, learned == nil || l.transport == .iframe else { return }
        let key = p.key
        let check = Debounce(milliseconds: 8_000)
        hostChecks[key.raw] = check
        check.schedule { [weak self] in
            // Same view as scheduled (a rehost or reload starts over).
            guard let self, let js = self.jsHosts[key.raw], js === js0, let cur = self.hosted[key.raw] else { return }
            let demo = self.isDemo
            let now = TeamsJSTransportChoice.learned(cur.appID, demo: demo)
            if js.initialized {
                if now == nil { TeamsJSTransportChoice.learn(cur.transport, app: cur.appID, demo: demo) }
                return
            }
            guard now != .frameless else { return }
            let next: TeamsJSTransport = cur.transport == .frameless ? .iframe : .frameless
            TeamsJSTransportChoice.learn(next, app: cur.appID, demo: demo)
            self.rehost(key, transport: next)
        }
    }

    /// Pending automatic host-mode checks, by key (one per page).
    private var hostChecks: [String: Debounce] = [:]

    /// Rebuilds a hosted view in place with another transport.
    private func rehost(_ key: FrameKey, transport t: TeamsJSTransport) {
        guard var l = hosted[key.raw], let p = pages[key.raw] else { return }
        l.transport = t
        hosted[key.raw] = l
        let container = p.web?.superview
        evict(p, keepState: false)
        if let container { attach(key, to: container) }
    }

    /// Whether `key` is shown by the native TeamsJS host.
    func isNativelyHosted(_ key: FrameKey) -> Bool { hosted[key.raw] != nil }

    // MARK: native TeamsJS host (APPHOST)

    /// Signed-in identity for app context (stored token claims, no network).
    private func identity() -> TeamsAppIdentity? {
        if isDemo { return DemoTeamsJSApp.identity }
        if identityCache == nil { identityCache = TeamsAppService.identity(profile: accountKey) }
        return identityCache
    }

    func appContext(_ l: TeamsAppLaunch, theme: String) -> TeamsJSAppContext {
        var c = TeamsJSAppContext()
        c.appId = l.appID
        c.entityId = l.entityID
        c.locale = TeamsJSPolicy.locale()
        c.theme = theme
        if let ch = l.channel {
            c.teamId = ch.teamID
            c.channelId = ch.channelID
            c.groupId = ch.groupID
            c.teamName = ch.teamName
            c.channelName = ch.channelName
        }
        if let i = identity() {
            c.tenantId = i.tenantId
            c.userObjectId = i.userObjectId
            c.userPrincipalName = i.upn
            c.userDisplayName = i.name
        }
        return c
    }

    private func makeJSHost(_ l: TeamsAppLaunch, key: FrameKey) -> TeamsJSHost {
        let theme = (NSApp?.effectiveAppearance).map(TeamsJSPolicy.theme(for:)) ?? "default"
        let js = TeamsJSHost(transport: l.transport, launch: l, context: appContext(l, theme: theme))
        js.broker = broker
        js.trustsBlankOrigin = isDemo
        js.onFallback = { [weak self] _ in self?.fallBack(key) }
        js.onDeepLink = { [weak self] url in
            guard let m = self?.window else { return false }
            return DeepLinkRouter.route(url, m)
        }
        return js
    }

    private func loadHosted(_ p: FramePage, _ js: TeamsJSHost, in web: WKWebView) {
        if isDemo {
            let html = js.launch.demoHTML ?? Self.demoPage(title: p.title, url: p.url)
            web.loadHTMLString(js.transport == .iframe ? TeamsJSHost.iframeHostHTML(src: nil, srcdoc: html) : html,
                               baseURL: nil)
            return
        }
        guard let content = js.contentURL else {
            p.state = .failed(message: "This app's page address isn't valid.", offline: false)
            return
        }
        switch js.transport {
        case .frameless:
            web.load(URLRequest(url: p.savedURL ?? content))
        case .iframe:
            web.loadHTMLString(TeamsJSHost.iframeHostHTML(src: content),
                               baseURL: URL(string: "https://teams.microsoft.com/"))
        }
        p.savedURL = nil
    }

    /// The native host cannot run this app (auth refused): swap its view
    /// in place for the Teams-shell page, for the rest of the session.
    private func fallBack(_ key: FrameKey) {
        guard let l = hosted[key.raw], let p = pages[key.raw] else { return }
        fallbackApps.insert(l.appID)
        hosted[key.raw] = nil
        let container = p.web?.superview
        evict(p, keepState: false)
        _ = p.update(url: l.fallback, title: p.title)
        if let container { attach(key, to: container) }
    }

    private func register(_ key: FrameKey, url: URL, title: String) {
        if let p = pages[key.raw] {
            // A changed URL reloads the resident view in place.
            if p.update(url: url, title: title), let web = p.web { load(p, in: web) }
            return
        }
        let p = FramePage(key: key, url: url, title: title)
        p.host = self
        pages[key.raw] = p
    }

    public func page(_ key: FrameKey) -> FramePage? { pages[key.raw] }

    /// The resident web view, if any (tests, commands).
    func webView(_ key: FrameKey) -> WKWebView? { pages[key.raw]?.web }

    // MARK: attach / detach (§7.3 ownership)

    /// Shows `key` in `container`, creating or restoring its view. Moves
    /// a view shown elsewhere (one parent, ever).
    public func attach(_ key: FrameKey, to container: NSView) {
        guard let p = pages[key.raw] else { return }
        let web = p.web ?? makeView(p)
        if web.superview !== container {
            web.removeFromSuperview()
            web.frame = FrameChromeStyle.frame(in: container.bounds, crop: layoutCrop(key), flipped: container.isFlipped)
            web.autoresizingMask = [.width, .height]
            container.addSubview(web)
        }
        p.lastUsed = Date()
        if p.suspended {
            p.suspended = false
            web.setAllMediaPlaybackSuspended(false, completionHandler: nil)
        }
        rebalance()
    }

    /// Removes `key`'s view from `container` without destroying it.
    public func detach(_ key: FrameKey, from container: NSView) {
        guard let p = pages[key.raw], let web = p.web, web.superview === container else { return }
        captureSnapshot(key)
        web.removeFromSuperview()
        p.lastUsed = Date()
        rebalance()
    }

    /// The page's picture as it leaves the screen (`FramePage.snapshot`).
    /// Best effort: no snapshot falls back to the loading pane. A page
    /// still restoring keeps the picture it is standing in with.
    func captureSnapshot(_ key: FrameKey) {
        guard let p = pages[key.raw], let web = p.web, web.window != nil,
              p.committed, !p.restoring else { return }
        web.takeSnapshot(with: nil) { [weak p] image, _ in
            if let image { p?.snapshot = image }
        }
    }

    /// A container left or re-entered a window (a hidden pane child is
    /// off-window without being dismantled, §5.1).
    func containerMoved(_ key: FrameKey, _ container: NSView) {
        if container.window != nil {
            attach(key, to: container)
        } else if let p = pages[key.raw], p.web?.superview === container {
            p.lastUsed = Date()
            rebalance()
        }
    }

    /// Unload from Memory (More ▸ Unload App, Close App).
    public func unload(_ key: FrameKey) {
        guard let p = pages[key.raw] else { return }
        evict(p, keepState: false)
    }

    /// Pages with a web view, by title (Settings ▸ Apps ▸ apps in memory).
    public var residentPages: [FramePage] {
        pages.values.filter(\.isResident).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: chrome hiding and crops (§7.3)

    func crop(_ key: FrameKey) -> TeamsFrameCrop { crops[key.raw] ?? .none }

    /// The crop the view is laid out with: the app's own crop, else (while
    /// hiding is on) the chrome the probe still measures, else none.
    func layoutCrop(_ key: FrameKey) -> TeamsFrameCrop {
        crops[key.raw] ?? (hideChrome ? measured[key.raw] : nil) ?? .none
    }

    /// Runs the `TeamsFrameMeasure` probe on a resident Teams page:
    /// visible app bar + header insets, or nil when none show (or the
    /// page is not resident / not Teams-hosted). Reads layout only.
    func measureChrome(_ key: FrameKey) async -> TeamsFrameCrop? {
        guard !isDemo, let p = pages[key.raw], let web = p.web, FrameChromeStyle.applies(to: p.url) else { return nil }
        guard let json = try? await web.evaluateJavaScript(TeamsFrameMeasure.script) as? String else { return nil }
        return TeamsFrameMeasure.parseResult(json)
    }

    /// §7.3 (2): re-measure after every load and in-page route change;
    /// chrome still showing despite the sheet becomes the layout crop.
    func probeChrome(_ p: FramePage) {
        guard hideChrome, !isDemo, p.web != nil, FrameChromeStyle.applies(to: p.url) else { return }
        let key = p.key
        Task { @MainActor [weak self] in
            let seen = await self?.measureChrome(key)
            guard let self, self.measured[key.raw] != seen else { return }
            self.measured[key.raw] = seen
            self.relayout(key)
        }
    }

    /// Sets one app's crop and re-lays out its view if resident.
    func setCrop(_ crop: TeamsFrameCrop, for key: FrameKey) {
        crops[key.raw] = crop == .none ? nil : crop
        relayout(key)
    }

    /// Settings ▸ Apps ▸ Reset Crops.
    func resetCrops() {
        let keys = crops.keys
        crops = [:]
        for k in keys { relayout(FrameKey(k)) }
    }

    private func relayout(_ key: FrameKey) {
        guard let web = pages[key.raw]?.web, let container = web.superview else { return }
        web.frame = FrameChromeStyle.frame(in: container.bounds, crop: layoutCrop(key), flipped: container.isFlipped)
    }

    /// Hiding toggled: resident Teams pages add or drop the sheet now and
    /// keep the matching document-start script for later loads.
    private func applyChromeStyle() {
        for p in pages.values {
            guard let web = p.web, FrameChromeStyle.applies(to: p.url) else { continue }
            let content = web.configuration.userContentController
            content.removeAllUserScripts()
            if hideChrome {
                content.addUserScript(FrameChromeStyle.userScript())
                content.addUserScript(FrameChromeStyle.routeScript())
                web.evaluateJavaScript(FrameChromeStyle.injectJS + FrameChromeStyle.routeHookJS)
                probeChrome(p)
            } else {
                web.evaluateJavaScript(FrameChromeStyle.removeJS)
                // Hiding off: the probe's fallback crop no longer applies.
                if measured.removeValue(forKey: p.key.raw) != nil { relayout(p.key) }
            }
        }
    }

    /// Residents, for policy and tests.
    var residents: [FramePolicy.Resident] {
        pages.values.compactMap { p in
            guard let web = p.web else { return nil }
            return FramePolicy.Resident(key: p.key.raw, visible: web.window != nil,
                                        lastUsed: p.lastUsed, suspended: p.suspended)
        }
    }

    private func rebalance(_ pressure: FramePolicy.Pressure = .normal) {
        for k in FramePolicy.suspend(residents, now: Date(), keepAlive: keepAlive) {
            guard let p = pages[k], let web = p.web else { continue }
            p.suspended = true
            web.pauseAllMediaPlayback(completionHandler: nil)
            web.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        }
        for k in FramePolicy.evict(residents, cap: keepInMemory, pressure: pressure) {
            guard let p = pages[k] else { continue }
            evict(p, keepState: true)
            // Under memory pressure the stand-in picture goes too.
            if pressure != .normal { p.snapshot = nil }
        }
    }

    /// `evicted`: interaction state + URL saved, view released.
    private func evict(_ p: FramePage, keepState: Bool) {
        guard let web = p.web else { return }
        if keepState {
            p.savedInteraction = web.interactionState
            p.savedURL = web.url
        } else {
            p.savedInteraction = nil
            p.savedURL = nil
            p.snapshot = nil
        }
        p.stopObserving()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: FrameChromeStyle.routeMessage)
        if let js = jsHosts.removeValue(forKey: p.key.raw) {
            js.detach()
            TeamsJSHost.uninstall(from: web.configuration.userContentController)
        }
        web.removeFromSuperview()
        p.web = nil
        p.suspended = false
        p.committed = false
        p.restoring = false
        p.progress = 0
        p.state = .idle
        if findKey == p.key { endFind() }
    }

    private func makeView(_ p: FramePage) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = TeamsFrameConfig.userAgentSuffix
        config.mediaTypesRequiringUserActionForPlayback = .all
        var js: TeamsJSHost?
        if let l = hosted[p.key.raw] {
            let h = makeJSHost(l, key: p.key)
            // The iframe host page speaks as teams.microsoft.com: keep it
            // out of the account's cookie store (spike B6).
            if l.transport == .iframe { config.websiteDataStore = .nonPersistent() }
            h.install(into: config.userContentController)
            jsHosts[p.key.raw] = h
            js = h
        } else if FrameChromeStyle.applies(to: p.url) {
            config.userContentController.add(FrameChromeRouteRelay(p), name: FrameChromeStyle.routeMessage)
            if hideChrome {
                config.userContentController.addUserScript(FrameChromeStyle.userScript())
                config.userContentController.addUserScript(FrameChromeStyle.routeScript())
            }
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.focusRingType = .none
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.navigationDelegate = p
        web.uiDelegate = p
        js?.attach(web)
        p.web = web
        p.observe(web)
        startPressureMonitor()
        if let saved = p.savedInteraction, !isDemo {
            web.interactionState = saved
            p.savedInteraction = nil
            p.state = .loading
        } else {
            load(p, in: web)
        }
        // Re-created after eviction: its last picture stands in.
        p.restoring = p.snapshot != nil
        return web
    }

    private func load(_ p: FramePage, in web: WKWebView) {
        p.state = .loading
        p.committed = false
        if isDemo, let js = jsHosts[p.key.raw] {
            loadHosted(p, js, in: web)
            return
        }
        if isDemo {
            web.loadHTMLString(Self.demoPage(title: p.title, url: p.url), baseURL: nil)
            return
        }
        if var waiting = ssoWaiting {
            waiting.append(p)
            ssoWaiting = waiting
            return
        }
        if !UserDefaults.standard.bool(forKey: ssoKey) {
            migrateSSO(then: p)
            return
        }
        if let js = jsHosts[p.key.raw] {
            loadHosted(p, js, in: web)
            return
        }
        web.load(URLRequest(url: p.savedURL ?? p.url))
        p.savedURL = nil
    }

    // MARK: SSO migration (one time)

    private var ssoKey: String { "bt.webStore.ssoMigrated.\(accountKey)" }

    /// Copies the old default jar's Microsoft cookies into the account
    /// store once (5 s gate), then loads everything that waited.
    private func migrateSSO(then first: FramePage) {
        ssoWaiting = [first]
        let store = dataStore
        Task { @MainActor [weak self] in
            _ = await TeamsFrameSSO.bootstrapWithTimeout(into: store, seconds: 5)
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: self.ssoKey)
            let waiting = self.ssoWaiting ?? []
            self.ssoWaiting = nil
            for p in waiting { if let web = p.web { self.load(p, in: web) } }
        }
    }

    // MARK: memory pressure (§7.3)

    private func startPressureMonitor() {
        guard pressureSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            let critical = src?.data.contains(.critical) ?? false
            Task { @MainActor in self?.rebalance(critical ? .critical : .warning) }
        }
        src.resume()
        pressureSource = src
    }

    // MARK: navigation policy

    static let authHosts = ["login.microsoftonline.com", "login.live.com", "login.microsoft.com", "login.windows.net"]

    static func isAuthHost(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return FramePolicy.hostMatches(h, authHosts)
    }

    /// Allowed in a frame: Teams + Microsoft auth/content hosts, the
    /// standalone app hosts, and the page's own host.
    func isAllowed(_ url: URL, for p: FramePage) -> Bool {
        // Natively hosted apps: their manifest's validDomains (APPHOST).
        if let l = hosted[p.key.raw] { return TeamsJSPolicy.allowsNavigation(url, launch: l) }
        if TeamsFrameConfig.isAllowed(url) { return true }
        guard let h = url.host?.lowercased() else { return false }
        if FramePolicy.hostMatches(h, FramePolicy.standaloneHosts) { return true }
        return h == p.url.host?.lowercased()
    }

    // MARK: popups (auth sheet)

    fileprivate func presentPopup(configuration: WKWebViewConfiguration, opener: FramePage) -> WKWebView? {
        guard popup == nil, let window else { return nil }
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 600), configuration: configuration)
        child.focusRingType = .none
        // `window.close()` in the popup arrives as webViewDidClose.
        child.uiDelegate = opener
        let sheet = WebAuthSheet(web: child, start: nil, redirectURI: "") { [weak self] _ in
            self?.closePopup(child)
        }
        guard window.presenter?.present(sheet, request: SheetRequest("webPopup", in: window.nav.section)) == true
        else { return nil }
        popup = child
        return child
    }

    fileprivate func closePopup(_ web: WKWebView) {
        guard popup === web else { return }
        popup = nil
        web.stopLoading()
        window?.dismissSheet()
    }

    // MARK: page commands (§7.3 web-app toolbar)

    func pageChanged(_ p: FramePage?) {
        guard let p, let m = window, case .web(let id) = m.nav.section, p.key == .app(id) else { return }
        m.navigator?.refreshTitle()
    }

    func reload(_ key: FrameKey) {
        guard let p = pages[key.raw] else { return }
        if let web = p.web {
            if p.committed, !isDemo { web.reload() } else { load(p, in: web) }
        }
    }

    /// Try Again after a failure: a fresh load of the app's URL.
    func retry(_ key: FrameKey) {
        guard let p = pages[key.raw], let web = p.web else { return }
        load(p, in: web)
    }

    // MARK: find in page (§5.5, G10)

    /// The page the toolbar field searches, while ⌘F is active in a web app.
    public private(set) var findKey: FrameKey?
    private(set) var findQuery = ""

    func beginFind(_ key: FrameKey) { findKey = key }

    func endFind() {
        guard findKey != nil else { return }
        findKey = nil
        findQuery = ""
    }

    func find(_ text: String) {
        findQuery = text
        guard !text.isEmpty else { return }
        runFind(backwards: false, beep: false)
    }

    func findAgain(backwards: Bool) { runFind(backwards: backwards, beep: true) }

    private func runFind(backwards: Bool, beep: Bool) {
        guard let key = findKey, let web = pages[key.raw]?.web, !findQuery.isEmpty else { return }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.wraps = true
        c.caseSensitive = false
        web.find(findQuery, configuration: c) { result in
            if beep, !result.matchFound { NSSound.beep() }
        }
    }

    // MARK: demo page

    static func demoPage(title: String, url: URL) -> String {
        let esc = { (s: String) in
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(esc(title))</title>
        <style>:root{color-scheme:light dark}body{font:-apple-system-body;margin:32px;max-width:640px}
        h1{font:-apple-system-title1;margin:0 0 8px}p{color:GrayText;margin:0 0 16px}
        li{margin:6px 0}</style></head><body>
        <h1>\(esc(title))</h1><p>\(esc(url.absoluteString))</p>
        <ul><li>Release checklist</li><li>Rollout owners</li><li>Known issues</li></ul>
        </body></html>
        """
    }

    /// The Microsoft sign-in web view, on the account's data store
    /// (§7.4). No custom chrome; the sheet owns Cancel.
    /// `ephemeral`: a store of its own (Add Account: the new account must
    /// not sign in with this account's Microsoft session).
    public func makeSignInWebView(ephemeral: Bool = false) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ephemeral ? .nonPersistent() : dataStore
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 600), configuration: config)
        web.focusRingType = .none
        return web
    }

    /// Settings ▸ Accounts ▸ Sign In to Web Apps: the sheet opens Teams on
    /// the web in this account's store and closes once Teams loads
    /// signed in, so every web app shares that session (§7.3 SSO).
    static let webAppsSignedInPrefix = "https://teams.microsoft.com/v2"
}
