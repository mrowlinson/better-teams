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
    /// A neutral, non-error pane (a meeting app opened outside a meeting):
    /// Teams' equivalent empty state, not a "couldn't load" failure.
    case info(message: String, systemImage: String)
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
    @ObservationIgnored fileprivate var downloads: [ObjectIdentifier: (id: String?, dest: URL?, obs: NSKeyValueObservation?)] = [:]
    /// A sign-in round trip left the allowlist (the tenant's federated
    /// sign-in and its hops): its pages stay in the frame until it lands
    /// back on an allowed host (APPSIGNIN).
    @ObservationIgnored fileprivate var signingIn = false
    /// The host gave up on this app page (reason in `state`) until the
    /// next load (APPNATIVE4).
    @ObservationIgnored fileprivate var hostFailed = false
    /// Ends a load that never finishes (no endless loading pane): a load
    /// that has not committed in this long fails with Retry. Reset on each
    /// provisional navigation, so it bounds one hop, not a whole redirect
    /// chain. 45 s (was 30 s): a slow provider-auth redirect (Planner's
    /// `auth_pvr` hop) sometimes needs more than 30 s to answer, and a
    /// dead host still fails fast via a DNS/connection error, not this
    /// timer (APPNATIVE5, R7).
    @ObservationIgnored fileprivate let loadWatch = Debounce(milliseconds: 45_000)

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

    /// Arms the load timeout: still unpainted → failed (Retry); painted
    /// but still loading → the progress line goes, the page stays.
    fileprivate func watchLoad() {
        loadWatch.schedule { [weak self] in
            guard let self, self.state == .loading else { return }
            if self.committed {
                self.state = .loaded
                return
            }
            self.web?.stopLoading()
            self.restoring = false
            self.state = .failed(message: "The page took too long to respond.", offline: false)
        }
    }
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
        if let gate = host.navigationGate, !gate(action) { return decisionHandler(.cancel) }
        if TeamsWebGuard.refuses(url, mainFrame: main, iframeHostDocument: main && host.isIframeHostDocument(self, url)) {
            // The Teams web app never loads, in the pane or in any of its
            // frames (APPNATIVE4/6): a page that redirects there on its
            // own is refused quietly; a clicked link opens its native view.
            decisionHandler(.cancel)
            host.refuseTeamsWeb(url, userInitiated: action.navigationType == .linkActivated)
            return
        }
        if let view = host.documentViewRedirect(self, url, mainFrame: main) {
            // A document page opens read-only (R9): its edit address
            // becomes the view address.
            decisionHandler(.cancel)
            webView.load(URLRequest(url: view))
            return
        }
        if main, !host.hostedWillNavigate(self, to: url, from: webView.url) {
            // The native host gave up on this app (APPHOST-B3).
            return decisionHandler(.cancel)
        }
        if main {
            switch FrameHost.mainFrameRoute(to: url, allowed: host.isAllowed(url, for: self), from: webView.url,
                                            signingIn: signingIn, signInHosts: host.signInHosts) {
            case .frame(let signingIn):
                self.signingIn = signingIn
            case .browser:
                // §7.3 navigation policy: leave the frame for the browser.
                decisionHandler(.cancel)
                host.openExternal(url)
                return
            }
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(FrameHost.responsePolicy(response.response, mainFrame: response.isForMainFrame,
                                                 canShow: response.canShowMIMEType))
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state = .loading
        watchLoad()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committed = true
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        committed = true
        restoring = false
        loadWatch.cancel()
        // The host gave up on this app while it loaded: the pane keeps
        // the reason (APPNATIVE4).
        if hostFailed { return }
        state = .loaded
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
    /// §7.3 popups: sign-in popups (auth hosts, scripted popup windows,
    /// popups from a sign-in page) open in a sheet around a child view
    /// made here (R16), keeping `window.opener`; other allowed hosts load
    /// in place; anything else goes to the default browser. No popup
    /// windows, ever.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let host, !host.isDemo else { return nil }
        if let gate = host.navigationGate, !gate(action) { return nil }
        let url = action.request.url
        if let url, TeamsWebGuard.isTeamsWeb(url) {
            // Never the Teams web app, not even in a popup (APPNATIVE4):
            // its native view when the router knows it, else nothing.
            host.refuseTeamsWeb(url, userInitiated: true)
            return nil
        }
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
        let fromSignIn = signingIn || webView.url.map { FrameHost.isSignInHost($0, host.signInHosts) } == true
        switch FrameHost.popupRoute(to: url, sized: sized, allowed: url.map { host.isAllowed($0, for: self) } ?? false,
                                    fromSignIn: fromSignIn, signInHosts: host.signInHosts) {
        case .sheet:
            return host.presentPopup(configuration: configuration, opener: self)
        case .frame:
            webView.load(action.request)
        case .browser:
            // Not a Teams address (refused above): the default browser.
            if let url { host.openExternal(url) }
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
        let dir = host?.downloadsFolder ?? FrameHost.defaultDownloads()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        } else {
            downloads[ObjectIdentifier(download)] = (nil, dest, nil)
        }
        completionHandler(dest)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let d = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        d.obs?.invalidate()
        let size = d.dest.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64 }
        // An empty download is never kept (APPNATIVE4): it was a page or
        // sign-in answer, not a file.
        if size == 0, let dest = d.dest {
            try? FileManager.default.removeItem(at: dest)
            if let id = d.id { host?.window?.app?.transfers.fail(id, message: "The download was empty.") }
            return
        }
        if let id = d.id { host?.window?.app?.transfers.finish(id, path: d.dest?.path, size: size) }
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let d = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        d.obs?.invalidate()
        if let id = d.id { host?.window?.app?.transfers.fail(id, message: error.localizedDescription) }
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
    /// Every registered manifest app page, by key (a host-mode change
    /// re-hosts it).
    private var launches: [String: TeamsAppLaunch] = [:]
    /// The TeamsJS host of each resident hosted view, by key.
    private var jsHosts: [String: TeamsJSHost] = [:]
    /// Why an app's page could not load this session, by catalog app id
    /// (the app card shows it). There is no Teams web page to fall back
    /// to: a failed app shows its reason in the pane, with Retry.
    private(set) var failures: [String: String] = [:]
    private var identityCache: TeamsAppIdentity?
    lazy var broker: TeamsJSTokenBroker = isDemo ? DemoTokenBroker() : CoreTokenBroker(profile: accountKey)

    /// Non-visible views kept resident (§7.3: 1 / 3 default / 6).
    var keepInMemory: Int
    /// Warm → suspended after this long (`teamsFrameKeepAliveMinutes`).
    var keepAlive: TimeInterval
    /// Settings ▸ Apps ▸ Downloads folder (§7.3 downloads).
    var downloadsFolder: URL


    static let downloadsFolderKey = "bt.frame.downloadsFolder"

    /// Test harness hooks (nil in the app): extra page scripts and
    /// handlers, and a veto on navigations.
    var instrument: ((WKUserContentController, FrameKey) -> Void)?
    var navigationGate: ((WKNavigationAction) -> Bool)?
    private var storeOverride: WKWebsiteDataStore?

    /// `store`: a data store of the caller's (tests), else the account's.
    convenience init(accountKey: String, store: WKWebsiteDataStore) {
        self.init(accountKey: accountKey)
        storeOverride = store
    }

    public init(accountKey: String) {
        self.accountKey = accountKey
        library = AppsLibrary(accountKey: accountKey)
        let demo = accountKey == "demo"
        keepInMemory = demo ? 3 : FramePolicy.keepInMemory()
        keepAlive = demo ? 15 * 60 : TimeInterval(TeamsFrameConfig.keepAliveMinutes(defaults: .standard) * 60)
        let saved = demo ? nil : UserDefaults.standard.string(forKey: Self.downloadsFolderKey)
        downloadsFolder = (Self.isTestProcess ? nil : saved).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultDownloads()
    }

    var isDemo: Bool { accountKey == "demo" }

    /// One persistent store per account; demo never touches disk.
    public private(set) lazy var dataStore: WKWebsiteDataStore = {
        if let storeOverride { return storeOverride }
        if isDemo { return .nonPersistent() }
        let store = WKWebsiteDataStore(forIdentifier: Self.storeUUID(accountKey))
        WebSessionKeeper.watch(store)
        return store
    }()

    /// Saves the account's Microsoft web session so it outlives the app
    /// (sign-in without "Stay signed in" is session-only; APPNATIVE4).
    public func keepWebSession() {
        WebSessionKeeper.watch(dataStore)
    }

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
        if case .teamsApp(let l) = app.launch {
            registerTeamsApp(key, launch: l, title: app.label)
        } else if app.id.hasPrefix(AppsLibrary.documentPrefix) {
            launches[key.raw] = nil
            hosted[key.raw] = nil
            registerDocument(key, url: app.launch.url, title: app.label)
        } else {
            launches[key.raw] = nil
            hosted[key.raw] = nil
            register(key, url: app.launch.url, title: app.label)
        }
    }

    /// Declares a channel tab served by a catalog app (`tab:<id>`), hosted
    /// natively with channel context (APPHOST-B2). Idempotent: called from
    /// view bodies, so an unchanged launch never re-registers (session
    /// placeholders would otherwise change the URL and reload).
    public func registerHostedTab(_ key: FrameKey, launch: TeamsAppLaunch, title: String) {
        registerTeamsApp(key, launch: launch, title: title)
    }

    /// A manifest app page, always in the native host: its own content
    /// page is the top document of the pane, over the TeamsJS bridge. It
    /// never loads the Teams web app (APPNATIVE4). Idempotent: an
    /// unchanged launch never re-registers (session placeholders would
    /// change the URL and reload).
    private func registerTeamsApp(_ key: FrameKey, launch: TeamsAppLaunch, title: String) {
        launches[key.raw] = launch
        if pages[key.raw]?.web != nil, hosted[key.raw] == nil {
            // A plain page becoming an app page needs a new view (the
            // bridge scripts); registration runs in view bodies, so not
            // in this pass.
            Task { @MainActor [weak self] in
                guard let self, let base = self.launches[key.raw], self.hosted[key.raw] == nil else { return }
                self.rehost(key, native: self.nativeLaunch(base))
            }
            return
        }
        let l = nativeLaunch(launch)
        if pages[key.raw] != nil, let cur = hosted[key.raw], cur.appID == l.appID,
           cur.contentTemplate == l.contentTemplate, cur.channel == l.channel {
            return
        }
        hosted[key.raw] = l
        register(key, url: hostedURL(l), title: title)
    }

    /// `launch` on the transport its host mode resolves to.
    private func nativeLaunch(_ launch: TeamsAppLaunch) -> TeamsAppLaunch {
        var l = launch
        l.transport = TeamsJSTransportChoice.resolve(launch, demo: isDemo)
        if !isDemo { loadRealm() }
        return TeamsJSPolicy.resolved(l, appContext(l, theme: "default"))
    }

    /// Theme-free expansion: a theme change must not reload. An address
    /// that does not parse loads nothing (the pane says so).
    private func hostedURL(_ l: TeamsAppLaunch) -> URL {
        URL(string: TeamsJSPolicy.expand(l.contentTemplate, appContext(l, theme: "default")))
            ?? URL(string: "about:blank")!
    }

    /// Host mode changed in the app card (or Try Again): every page of
    /// the app re-hosts in place with a fresh start.
    func hostModeChanged(appID: String) {
        failures[appID.lowercased()] = nil
        for (raw, base) in launches where base.appID.caseInsensitiveCompare(appID) == .orderedSame {
            guard let key = pages[raw]?.key else { continue }
            rehost(key, native: nativeLaunch(base))
        }
    }

    /// Why `appID` could not load this session (app card status), if it failed.
    func hostFailure(appID: String) -> String? { failures[appID.lowercased()] }

    /// Automatic host mode: a frameless page that has neither initialized
    /// TeamsJS nor drawn anything 13 s after loading gets one try in the
    /// iframe transport; an iframe try that also stays silent goes back
    /// to frameless for good. A page that draws without TeamsJS (a plain
    /// web page, e.g. a SharePoint page) stays. The first transport that
    /// works is remembered per app.
    func hostedDidFinish(_ p: FramePage) {
        scheduleBlankCheck(p)
        guard let l = hosted[p.key.raw], let js0 = jsHosts[p.key.raw],
              TeamsJSTransportChoice.mode(l.appID, demo: isDemo) == .automatic else { return }
        let learned = TeamsJSTransportChoice.learned(l.appID, demo: isDemo)
        if js0.initialized {
            if learned == nil { TeamsJSTransportChoice.learn(l.transport, app: l.appID, demo: isDemo) }
            return
        }
        guard learned != .frameless, learned == nil || l.transport == .iframe else { return }
        let key = p.key
        let check = Debounce(milliseconds: Self.transportCheck)
        hostChecks[key.raw] = check
        check.schedule { [weak self] in
            // Same view as scheduled (a rehost or reload starts over).
            guard let self, let js = self.jsHosts[key.raw], js === js0, let cur = self.hosted[key.raw] else { return }
            let demo = self.isDemo
            let now = TeamsJSTransportChoice.learned(cur.appID, demo: demo)
            if js.initialized || !(js.paint?.isBlank ?? true) {
                if now == nil { TeamsJSTransportChoice.learn(cur.transport, app: cur.appID, demo: demo) }
                return
            }
            // The app's own web page is plain web: no transport to try.
            guard now != .frameless, !TeamsJSTransportChoice.usesWebsite(cur.appID, demo: demo) else { return }
            let next: TeamsJSTransport = cur.transport == .frameless ? .iframe : .frameless
            TeamsJSTransportChoice.learn(next, app: cur.appID, demo: demo)
            var l = cur
            l.transport = next
            self.rehost(key, native: l)
        }
    }

    /// Pending automatic host-mode checks, by key (one per page).
    private var hostChecks: [String: Debounce] = [:]
    /// The transport check runs after the paint probe's first report
    /// (12 s after the DOM is ready).
    static let transportCheck: UInt64 = 13_000

    // MARK: native host failure watch (APPHOST-B3)

    /// Automatic mode watches a native page for failure; a forced mode
    /// (Direct / In a Frame) leaves it alone.
    private func watchesFailures(_ l: TeamsAppLaunch) -> Bool {
        TeamsJSTransportChoice.mode(l.appID, demo: isDemo) == .automatic
    }

    /// A native page with nothing painted in its app frame this long
    /// after loading is blank (the paint probe reports at 12 s / 20 s).
    static let blankAfter: UInt64 = 26_000
    private var blankChecks: [String: Debounce] = [:]

    /// Main-frame navigation of a native page. False = cancel: the page
    /// shows why it cannot load (a sign-in error), with Retry.
    func hostedWillNavigate(_ p: FramePage, to url: URL, from current: URL?) -> Bool {
        guard hosted[p.key.raw] != nil else { return true }
        if let why = TeamsJSPolicy.signInFailure(url) {
            fail(p.key, why: why)
            return false
        }
        return true
    }

    // MARK: tenant sign-in hosts + SharePoint values (APPHOST-B3)

    /// The tenant's federated sign-in host(s), from its own realm
    /// discovery (never a wildcard): native pages may pass through them.
    private(set) var signInHosts: [String] = []
    private var realmAsked = false

    private func loadRealm() {
        // One identity read per host, found or not (it is a core call).
        guard !realmAsked else { return }
        realmAsked = true
        guard let upn = identity()?.upn, !upn.isEmpty,
              let enc = upn.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])),
              let url = URL(string: "https://login.microsoftonline.com/common/userrealm/\(enc)?api-version=2.1")
        else { return }
        Task { @MainActor [weak self] in
            // Public realm discovery (no token); the answer names the IdP.
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let host = TeamsJSPolicy.federatedHost(realmJSON: data) else { return }
            self?.signInHosts = [host]
        }
    }

    /// SharePoint URLs for placeholders: tenant root + OneDrive, and
    /// team sites by group id. `sitesDone` holds finished lookups
    /// ("" = account), successful or not.
    private var sites = TeamsAppSites()
    private var teamSites: [String: String] = [:]
    private var siteTasks: [String: Task<Void, Never>] = [:]
    private var sitesDone: Set<String> = []

    private func groupID(_ l: TeamsAppLaunch) -> String? {
        guard let ch = l.channel else { return nil }
        return (ch.groupID ?? (UUID(uuidString: ch.teamID) != nil ? ch.teamID : nil))?.lowercased()
    }

    private func sitesReady(_ l: TeamsAppLaunch) -> Bool {
        isDemo || !TeamsJSPolicy.needsSite(l) || sitesDone.contains(groupID(l) ?? "")
    }

    private func ensureSites(_ l: TeamsAppLaunch) async {
        let g = groupID(l)
        let key = g ?? ""
        if let t = siteTasks[key] { return await t.value }
        let profile = accountKey
        let t = Task { @MainActor [weak self] in
            let r = await TeamsAppService.sites(profile: profile, groupID: g)
            guard let self else { return }
            self.sitesDone.insert(key)
            guard case .success(let found) = r else { return }
            if let root = found.root { self.sites.root = root }
            if let my = found.mySite { self.sites.mySite = my }
            if let g, let team = found.teamSite { self.teamSites[g] = team }
            if found.root != nil { self.sitesDone.insert("") }
        }
        siteTasks[key] = t
        await t.value
    }

    /// After a native page loads: nothing painted in the app's frame
    /// (no text, no sized content) by `blankAfter` → Teams web page.
    private func scheduleBlankCheck(_ p: FramePage) {
        guard let l = hosted[p.key.raw], watchesFailures(l), let js0 = jsHosts[p.key.raw],
              blankChecks[p.key.raw] == nil else { return }
        let key = p.key
        let check = Debounce(milliseconds: Self.blankAfter)
        blankChecks[key.raw] = check
        check.schedule { [weak self, weak check] in
            guard let self else { return }
            if self.blankChecks[key.raw] === check { self.blankChecks[key.raw] = nil }
            guard self.jsHosts[key.raw] === js0, let page = self.pages[key.raw] else { return }
            // Offline or mid-load: no verdict (the page shows its state).
            guard page.state == .loaded else { return }
            guard js0.paint?.isBlank ?? true, let web = page.web else { return }
            // The DOM probe misses some pages (reloads, shadow DOM): the
            // view's own pixels decide before switching.
            Task { @MainActor [weak self] in
                let ink = await Self.inkFraction(web)
                guard let self, self.jsHosts[key.raw] === js0, ink.map({ $0 < Self.blankInk }) ?? true else { return }
                self.blankPage(key)
            }
        }
    }

    /// A native page stayed blank: its Teams-embedded page gets one
    /// stand-in, the app's own web page (a same-host websiteUrl from its
    /// manifest or tab), remembered per app when it draws; otherwise, or
    /// when that is blank too, the pane says the app showed nothing.
    private func blankPage(_ key: FrameKey) {
        guard let l = hosted[key.raw] else { return }
        if !TeamsJSTransportChoice.usesWebsite(l.appID, demo: isDemo), websiteURL(l) != nil {
            TeamsJSTransportChoice.setUsesWebsite(true, app: l.appID, demo: isDemo)
            TeamsJSTransportChoice.learn(.frameless, app: l.appID, demo: isDemo)
            var f = l
            f.transport = .frameless
            rehost(key, native: f)
            return
        }
        // A meeting app (Q&A) opened outside a meeting draws nothing, just
        // as it does in Teams: show Teams' equivalent state, not an error.
        if jsHosts[key.raw]?.wantsMeetingContext == true { meetingState(key); return }
        fail(key, why: "blank page")
    }

    /// The app's own web page for `l`, when it may stand in (see
    /// `TeamsJSPolicy.websiteURL`).
    private func websiteURL(_ l: TeamsAppLaunch) -> URL? {
        TeamsJSPolicy.websiteURL(l, appContext(l, theme: "default"))
    }

    /// Share of sampled pixels that differ from the page background; a
    /// painted app is above this (a live feed page measured 0.02, blank
    /// apps 0.00).
    static let blankInk = 0.01

    /// Fraction of a snapshot's sampled pixels unlike its bottom-left
    /// background pixel; nil when no snapshot could be taken.
    static func inkFraction(_ web: WKWebView) async -> Double? {
        guard let img = try? await web.takeSnapshot(configuration: nil),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return inkFraction(cg)
    }

    static func inkFraction(_ cg: CGImage) -> Double? {
        let w = cg.width, h = cg.height
        guard w > 4, h > 4, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * w * 4 + x * 4
            return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
        }
        let bg = px(2, h - 3)
        var n = 0, d = 0
        for y in stride(from: 0, to: h, by: 6) {
            for x in stride(from: 0, to: w, by: 6) {
                n += 1
                let c = px(x, y)
                if abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2) > 24 { d += 1 }
            }
        }
        return n == 0 ? nil : Double(d) / Double(n)
    }

    /// Rebuilds a page's view in place, natively on `l`'s transport.
    private func rehost(_ key: FrameKey, native l: TeamsAppLaunch) {
        guard let p = pages[key.raw] else { return }
        hostChecks[key.raw] = nil
        blankChecks[key.raw] = nil
        hosted[key.raw] = l
        let container = p.web?.superview
        evict(p, keepState: false)
        _ = p.update(url: hostedURL(l), title: p.title)
        if let container { attach(key, to: container) }
    }

    /// Whether `key` is shown by the native TeamsJS host.
    func isNativelyHosted(_ key: FrameKey) -> Bool { hosted[key.raw] != nil }

    /// The TeamsJS host of a hosted page (tests, diagnostics).
    func teamsJSHost(_ key: FrameKey) -> TeamsJSHost? { jsHosts[key.raw] }

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
            c.groupId = groupID(l)
            c.teamName = ch.teamName
            c.channelName = ch.channelName
        }
        let team = groupID(l).flatMap { teamSites[$0] }
        c.teamSiteUrl = team ?? ""
        c.teamSiteDomain = TeamsJSPolicy.siteParts(team ?? sites.root).domain
        c.teamSitePath = team.map { TeamsJSPolicy.siteParts($0).path } ?? ""
        c.mySiteDomain = TeamsJSPolicy.siteParts(sites.mySite).domain
        c.mySitePath = sites.mySite == nil ? "" : TeamsJSPolicy.mySitePath(sites.mySite)
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
        js.onFallback = { [weak self] why in self?.fail(key, why: why) }
        js.watchesFailures = watchesFailures(l)
        js.onConsent = { [weak self] resource in await self?.presentConsent(resource) ?? false }
        js.onAuthenticate = { [weak self, weak js] url in
            guard let self, let js else { return (false, "CancelledByUser") }
            return await self.presentAuthWindow(url, opener: js)
        }
        js.onJoinedTeams = { [weak self] in await self?.joinedTeams() ?? [] }
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
        if let base = launches[p.key.raw], !sitesReady(base) {
            // SharePoint placeholders: look the sites up, then re-host
            // with the filled URL, domains and token resource.
            p.state = .loading
            let key = p.key
            Task { @MainActor [weak self] in
                await self?.ensureSites(base)
                guard let self, self.jsHosts[key.raw] === js else { return }
                self.rehost(key, native: self.nativeLaunch(base))
            }
            return
        }
        let sp = sharePointHosts(js)
        if spSessions.mustWait(sp) {
            // SharePoint / OneDrive pages: sign the account's web store in
            // to their hosts with an app token first (no web sign-in).
            p.state = .loading
            Task { @MainActor [weak self, weak p] in
                guard let self else { return }
                await self.spSessions.prepare(sp, broker: self.broker, store: self.dataStore)
                guard let p, self.jsHosts[p.key.raw] === js, let web = p.web else { return }
                self.loadHosted(p, js, in: web)
            }
            return
        }
        guard let content = js.contentURL else {
            p.state = .failed(message: "This app's page address isn't valid.", offline: false)
            return
        }
        let website = TeamsJSTransportChoice.usesWebsite(js.launch.appID, demo: isDemo) ? websiteURL(js.launch) : nil
        switch js.transport {
        case .frameless:
            web.load(URLRequest(url: p.savedURL ?? website ?? content))
        case .iframe:
            web.loadHTMLString(TeamsJSHost.iframeHostHTML(src: content),
                               baseURL: URL(string: "https://teams.microsoft.com/"))
        }
        p.savedURL = nil
    }

    /// The account's joined teams for hosted apps, read once a session
    /// from the core (demo: none).
    private var joinedTeamsCache: [TeamsJSTeamInfo]?

    private func joinedTeams() async -> [TeamsJSTeamInfo] {
        if isDemo { return [] }
        if let c = joinedTeamsCache { return c }
        let teams = await TeamsAppService.joinedTeams()
        let list = teams.compactMap(TeamsJSTeamInfo.from)
        if !teams.isEmpty { joinedTeamsCache = list }
        return list
    }

    /// SharePoint session sign-ins for native pages (APPNATIVE2).
    private let spSessions = SharePointSessions()

    /// SharePoint hosts a native page needs a session on: its own, and
    /// the account's root and OneDrive sites (pages hop between them).
    private func sharePointHosts(_ js: TeamsJSHost) -> [String] {
        let own = SharePointSession.hosts(for: js.launch, content: js.contentURL)
        guard !own.isEmpty else { return [] }
        let account = [sites.root, sites.mySite].compactMap { TeamsJSPolicy.siteParts($0).domain }
            .filter { !$0.isEmpty && SharePointSession.isSharePointHost($0) }
        var seen = Set<String>()
        return (own + account).filter { seen.insert($0).inserted }
    }

    /// The app cannot run (sign-in error, app-reported failure, blank
    /// page): its pane shows the concrete reason with Retry. Never the
    /// Teams web app (APPNATIVE4: there is no such fallback).
    private func fail(_ key: FrameKey, why: String) {
        guard let p = pages[key.raw] else { return }
        if let l = hosted[key.raw] { failures[l.appID.lowercased()] = why }
        hostChecks[key.raw] = nil
        blankChecks[key.raw] = nil
        p.web?.stopLoading()
        p.loadWatch.cancel()
        p.restoring = false
        p.hostFailed = true
        p.state = .failed(message: Self.failureMessage(why), offline: false)
    }

    /// A meeting app (Q&A) opened outside a meeting: an informational
    /// pane matching Teams' own empty state, not a retryable error.
    /// Kept out of `failures` so the app card shows no failure badge.
    static let meetingAppMessage = "This app opens inside a Teams meeting. Start or join a meeting to use it."
    private func meetingState(_ key: FrameKey) {
        guard let p = pages[key.raw] else { return }
        hostChecks[key.raw] = nil
        blankChecks[key.raw] = nil
        p.web?.stopLoading()
        p.loadWatch.cancel()
        p.restoring = false
        p.hostFailed = true
        p.state = .info(message: Self.meetingAppMessage, systemImage: "video")
    }

    /// The pane's sentence for a failure reason (short, never page content).
    static func failureMessage(_ why: String) -> String {
        let w = why.lowercased()
        if w.hasPrefix("sign-in error") {
            return "Microsoft sign-in refused this app (\(why.dropFirst("sign-in error".count).trimmingCharacters(in: .whitespaces).isEmpty ? "no code" : why.dropFirst("sign-in error ".count))). Retry, or check the app's permissions with your admin."
        }
        if w == "blank page" { return "The app loaded but showed nothing." }
        if w == "consent declined" {
            return "This app needs your permission before it can sign you in. Retry to see the permission request again."
        }
        if w.hasPrefix("app reported") { return "The app reported a problem: \(why.dropFirst("app reported ".count))." }
        if w == "nested app auth failed" || w.contains("token") { return "The app couldn't get a sign-in token for your account." }
        if w == "teams web link" { return "This is a Teams location, not an app page. It opens in its own view in Better Teams." }
        return why.prefix(1).uppercased() + why.dropFirst() + "."
    }

    private func register(_ key: FrameKey, url: URL, title: String) {
        // The Teams web app never loads in a pane (APPNATIVE4): a Teams
        // link registered as a page stays unloaded and says where it goes.
        if TeamsWebGuard.isTeamsWeb(url) {
            let p = pages[key.raw] ?? FramePage(key: key, url: URL(string: "about:blank")!, title: title)
            p.host = self
            pages[key.raw] = p
            launches[key.raw] = nil
            hosted[key.raw] = nil
            if p.web != nil { evict(p, keepState: false) }
            teamsLinks.insert(key.raw)
            p.state = .failed(message: Self.failureMessage("teams web link"), offline: false)
            return
        }
        teamsLinks.remove(key.raw)
        // Any plain page that is an Office document stored in SharePoint
        // or OneDrive (a Files item, a file tab, a web link) opens its
        // read-only view (R9, R4).
        var url = url
        if hosted[key.raw] == nil, let view = OfficeDocumentView.viewURL(url) {
            documentKeys.insert(key.raw)
            url = view
        } else if hosted[key.raw] != nil {
            documentKeys.remove(key.raw)
        }
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

    /// Pages registered with a Teams web address: never loaded.
    private var teamsLinks: Set<String> = []

    /// Pages opened as documents (Files ▸ Open, R9): they stay read-only.
    private(set) var documentKeys: Set<String> = []

    /// Opens an Office document's web page in a pane, read-only.
    func registerDocument(_ key: FrameKey, url: URL, title: String) {
        documentKeys.insert(key.raw)
        register(key, url: url, title: title)
    }

    /// A document page's main-frame hop to an edit address: the view
    /// address instead (nil = let it load).
    func documentViewRedirect(_ p: FramePage, _ url: URL, mainFrame: Bool) -> URL? {
        guard mainFrame, documentKeys.contains(p.key.raw) else { return nil }
        return OfficeDocumentView.viewURL(url).flatMap { $0 == url ? nil : $0 }
    }

    /// The iframe transport's own host document (an HTML string at the
    /// Teams origin, no network): the one Teams-origin load allowed.
    func isIframeHostDocument(_ p: FramePage, _ url: URL) -> Bool {
        hosted[p.key.raw]?.transport == .iframe && url.host?.lowercased() == "teams.microsoft.com"
            && (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    /// A Teams link the user opened: its native view (chat, channel, tab,
    /// app). Never a pane, and never the default browser either: there it
    /// is the Teams web app (APPNATIVE6, R13). False = no native view.
    @discardableResult
    func openTeamsLink(_ url: URL) -> Bool {
        if isDemo { return false }
        guard let m = window else { return false }
        return DeepLinkRouter.route(url, m)
    }

    /// A page, frame or popup went for a Teams web address (the load was
    /// cancelled): a clicked link opens its native view; a page going
    /// there by itself (a "you're not in Teams" redirect) is ignored.
    func refuseTeamsWeb(_ url: URL, userInitiated: Bool) {
        refusedTeamsWeb += 1
        if userInitiated { openTeamsLink(url) }
    }

    /// Teams web loads refused this session (tests, diagnostics).
    private(set) var refusedTeamsWeb = 0

    /// Opens a URL outside the app. Never in a test process: a test run
    /// once opened a Teams address in the default browser, which saved
    /// an empty file to ~/Downloads (APPNATIVE4).
    var openExternal: (URL) -> Void = { url in
        guard !FrameHost.isTestProcess else { return }
        NSWorkspace.shared.open(url)
    }

    /// XCTest is loaded: nothing may open a browser or write to the
    /// user's folders.
    nonisolated static let isTestProcess = UserFolders.isTestProcess

    /// Where downloads land by default: ~/Downloads, or a temporary
    /// folder of its own in a test process.
    nonisolated static func defaultDownloads(test: Bool = isTestProcess) -> URL {
        UserFolders.downloads(test: test)
    }

    /// Only a real file downloads (APPNATIVE4): a response the view can
    /// show loads; one it cannot downloads only when it is the page's own
    /// navigation (or a declared attachment), succeeded, has a body, and
    /// is not a sign-in answer. Anything else is dropped, never saved.
    static func responsePolicy(_ r: URLResponse, mainFrame: Bool, canShow: Bool) -> WKNavigationResponsePolicy {
        if canShow { return .allow }
        let http = r as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        let attachment = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        guard (200..<300).contains(status), r.expectedContentLength != 0,
              let url = r.url, !isAuthHost(url), mainFrame || attachment else { return .cancel }
        return .download
    }

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
            web.frame = container.bounds
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
            // Both transports use the account's store (APPNATIVE2): the
            // app frame inside the iframe host needs the same sessions.
            h.install(into: config.userContentController)
            jsHosts[p.key.raw] = h
            js = h
        }
        instrument?(config.userContentController, p.key)
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
        if teamsLinks.contains(p.key.raw) {
            p.state = .failed(message: Self.failureMessage("teams web link"), offline: false)
            return
        }
        p.state = .loading
        p.committed = false
        p.signingIn = false
        p.hostFailed = false
        if !isDemo {
            p.watchLoad()
            loadRealm()
        }
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
        let target = p.savedURL ?? p.url
        let sp = target.host.map { SharePointSession.isSharePointHost($0) ? [$0.lowercased()] : [] } ?? []
        if spSessions.mustWait(sp) {
            // A plain SharePoint / OneDrive page (a document from Files,
            // a website tab): the same SharePoint sign-in native app pages
            // get first (APPNATIVE2), so it opens without a web sign-in.
            Task { @MainActor [weak self, weak p] in
                guard let self else { return }
                await self.spSessions.prepare(sp, broker: self.broker, store: self.dataStore)
                guard let p, let web = p.web, self.jsHosts[p.key.raw] == nil else { return }
                self.load(p, in: web)
            }
            return
        }
        web.load(URLRequest(url: target))
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

    /// Microsoft sign-in, or the tenant's federated sign-in host.
    static func isSignInHost(_ url: URL, _ signInHosts: [String]) -> Bool {
        isAuthHost(url) || url.host.map { signInHosts.contains($0.lowercased()) } ?? false
    }

    /// Where a main-frame navigation goes.
    enum MainFrameRoute: Equatable {
        /// Stays in the frame; `signingIn` = a sign-in round trip is off
        /// the allowlist (its next hops stay too).
        case frame(signingIn: Bool)
        case browser
    }

    /// Main-frame policy (APPSIGNIN): allowed hosts stay. So does every
    /// https hop of a sign-in round trip: leaving a Microsoft sign-in
    /// page for the tenant's federated IdP (WS-Fed/SAML), and that IdP's
    /// own hops (MFA), until it lands back on an allowed host. Sending
    /// them to the browser strands the frame: the browser signs in, the
    /// frame never learns.
    static func mainFrameRoute(to url: URL, allowed: Bool, from current: URL?, signingIn: Bool,
                               signInHosts: [String]) -> MainFrameRoute {
        if allowed { return .frame(signingIn: false) }
        guard url.scheme?.lowercased() == "https" else { return .browser }
        if signingIn || isSignInHost(url, signInHosts) || current.map({ isSignInHost($0, signInHosts) }) == true {
            return .frame(signingIn: true)
        }
        return .browser
    }

    /// Where a popup (`window.open`, target=_blank) goes.
    enum PopupRoute: Equatable { case sheet, frame, browser }

    /// Popup policy (APPSIGNIN): sign-in popups get an in-app child view
    /// in a sheet, so `window.opener` / postMessage / `window.close()`
    /// work (MSAL popups, TeamsJS `authentication.authenticate`): popups
    /// to sign-in hosts, scripted popup windows (a size in the window
    /// features, or a blank window the opener writes into), and popups
    /// from a sign-in page. Plain new-window links keep §7.3.
    static func popupRoute(to url: URL?, sized: Bool, allowed: Bool, fromSignIn: Bool,
                           signInHosts: [String]) -> PopupRoute {
        let scheme = url?.scheme?.lowercased() ?? ""
        let blank = url == nil || url?.absoluteString.isEmpty == true || scheme == "about"
        let web = scheme == "https" || scheme == "http"
        if let url, web, isSignInHost(url, signInHosts) { return .sheet }
        if blank || (web && (sized || fromSignIn)) { return .sheet }
        return allowed ? .frame : .browser
    }

    /// Allowed in a frame: Teams + Microsoft auth/content hosts, the
    /// standalone app hosts, and the page's own host.
    func isAllowed(_ url: URL, for p: FramePage) -> Bool {
        // Natively hosted apps: their manifest's validDomains (APPHOST).
        if let l = hosted[p.key.raw] { return TeamsJSPolicy.allowsNavigation(url, launch: l, signInHosts: signInHosts) }
        if TeamsWebGuard.isTeamsWeb(url) { return false }
        if Self.isAuthHost(url) { return true }
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
        // The popup's own navigations (every frame) pass the same Teams
        // web guard as the pane (R8): the sheet is its navigation delegate.
        sheet.guardHost = self
        guard window.presenter?.present(sheet, request: SheetRequest("webPopup", in: window.nav.section)) == true
        else { return nil }
        popup = child
        return child
    }

    /// getAuthToken consent (AADSTS65001): the Microsoft consent page for
    /// the Teams client in a sheet. True once it redirects back with a
    /// code (the user accepted); false on cancel or an error.
    private func presentConsent(_ resource: String) async -> Bool {
        guard !isDemo, popup == nil, let window, let id = identity(),
              let start = TeamsJSPolicy.consentURL(resource: resource, tenant: id.tenantId, loginHint: id.upn)
        else { return false }
        let web = makeSignInWebView()
        return await withCheckedContinuation { cont in
            let sheet = WebAuthSheet(web: web, start: start, redirectURI: TeamsJSPolicy.nativeRedirect) { [weak self] cb in
                if self?.popup === web { self?.popup = nil }
                self?.window?.dismissSheet()
                cont.resume(returning: cb.map { $0.contains("code=") } ?? false)
            }
            sheet.guardHost = self
            guard window.presenter?.present(sheet, request: SheetRequest("webPopup", in: window.nav.section)) == true
            else { return cont.resume(returning: false) }
            popup = web
        }
    }

    /// `authentication.authenticate`: the app's auth page in a sheet, as
    /// a TeamsJS auth window (frameContext "authentication") on the
    /// account store; ends on notifySuccess / notifyFailure or Cancel.
    private func presentAuthWindow(_ url: URL, opener: TeamsJSHost) async -> (Bool, String) {
        guard !isDemo, popup == nil, let window else { return (false, "CancelledByUser") }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.applicationNameForUserAgent = TeamsFrameConfig.userAgentSuffix
        var ctx = opener.context
        ctx.frameContext = "authentication"
        var l = opener.launch
        l.transport = .frameless
        let js = TeamsJSHost(transport: .frameless, launch: l, context: ctx)
        js.broker = broker
        js.install(into: config.userContentController)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 600), configuration: config)
        web.focusRingType = .none
        js.attach(web)
        final class Once { var done = false; var shown = false }
        let once = Once()
        return await withCheckedContinuation { cont in
            let finish = { [weak self] (ok: Bool, result: String) in
                guard !once.done else { return }
                once.done = true
                js.onAuthResult = nil
                js.detach()
                TeamsJSHost.uninstall(from: web.configuration.userContentController)
                if self?.popup === web { self?.popup = nil }
                if once.shown { self?.window?.dismissSheet() }
                cont.resume(returning: (ok, result))
            }
            js.onAuthResult = { ok, result in finish(ok, result) }
            let sheet = WebAuthSheet(web: web, start: url, redirectURI: "") { _ in finish(false, "CancelledByUser") }
            sheet.guardHost = self
            guard window.presenter?.present(sheet, request: SheetRequest("webPopup", in: window.nav.section)) == true
            else { return finish(false, "CancelledByUser") }
            once.shown = true
            popup = web
        }
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
        // An app page starts over in the native host (fresh bridge and
        // checks), never on another page.
        if let base = launches[key.raw] {
            failures[base.appID.lowercased()] = nil
            TeamsJSTransportChoice.forgetFailure(app: base.appID, demo: isDemo)
            rehost(key, native: nativeLaunch(base))
            return
        }
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
    /// `addingProfile`: Add Account signs in on the NEW account's own
    /// persistent store (never this account's Microsoft session), so the
    /// web session it makes is already there when that account's apps
    /// load: no second sign-in (APPNATIVE4).
    public func makeSignInWebView(addingProfile: String? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        let store: WKWebsiteDataStore
        if let addingProfile, !isDemo, storeOverride == nil {
            store = WKWebsiteDataStore(forIdentifier: Self.storeUUID(addingProfile))
        } else {
            store = dataStore
        }
        WebSessionKeeper.watch(store)
        config.websiteDataStore = store
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 600), configuration: config)
        web.focusRingType = .none
        return web
    }

    /// Settings ▸ Accounts ▸ Sign In to Web Apps: Microsoft sign-in for
    /// this account in its store, ending at the native-client redirect
    /// (the code is never redeemed): the sign-in leaves the account's web
    /// session in the store, shared by every app (§7.3 SSO). No Teams web
    /// app (APPNATIVE4).
    static let webAppsSignedInPrefix = TeamsJSPolicy.nativeRedirect

    func webSessionSignInURL() -> URL? {
        let id = identity()
        var c = URLComponents(string: "https://login.microsoftonline.com/")
        c?.path = "/\((id?.tenantId).flatMap { $0.isEmpty ? nil : $0 } ?? "organizations")/oauth2/v2.0/authorize"
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: TeamsJSPolicy.teamsClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: TeamsJSPolicy.nativeRedirect),
            URLQueryItem(name: "scope", value: "openid profile"),
        ] + ((id?.upn).flatMap { $0.isEmpty ? nil : [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        return c?.url
    }
}
