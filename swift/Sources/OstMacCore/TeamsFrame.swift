// TeamsFrame.swift — teams-frame FULL: host teams.microsoft.com in a
// WKWebView so third-party Teams apps render on one native surface.
//
// DISPLAY ONLY (real employer account): never send messages, never click
// inside apps post-login, never drive an authenticated session. Pre-login
// automation OK. Owner completes login live.
//
// ui-purge: the frame window, switcher, popup sheet, calibrate overlay and
// the WKWebView NSViewRepresentable + its navigation/UI delegate were
// deleted with the old UI. Kept: config/escape policy, SSO cookie
// bootstrap, crop geometry + measure JS, app registry, library parser,
// downloads naming, and TeamsFrameStore (data store + lifecycle). No
// WKProcessPool: deprecated, and WebKit shares one process pool anyway.
import AppKit
import Combine
import WebKit

// MARK: - Config (pure; unit-tested)

public enum TeamsFrameConfig {
    public static let defaultURL = "https://teams.microsoft.com"
    /// Own persistent jar: Teams cookies survive relaunch, isolated from
    /// the BrowserAuthView default store. Fixed UUID = stable across runs.
    public static let dataStoreIdentifier = UUID(
        uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    public static let keepAliveMinutesKey = "teamsFrameKeepAliveMinutes"
    public static let defaultKeepAliveMinutes = 15

    /// --teams-frame-url <url>; default https://teams.microsoft.com.
    /// Owner pastes the entity deep link at test time.
    public static func launchURL(args: [String]) -> String {
        if let i = args.firstIndex(of: "--teams-frame-url"), i + 1 < args.count {
            return args[i + 1]
        }
        return defaultURL
    }

    /// Frame window opens when either flag is present.
    public static func shouldOpen(args: [String]) -> Bool {
        args.contains("--show-teams-frame") || args.contains("--teams-frame-url")
    }

    /// --teams-frame-full shows the uncropped page (fallback).
    public static func fullFrame(args: [String]) -> Bool {
        args.contains("--teams-frame-full")
    }

    /// --teams-frame-calibrate overlays draggable crop guides (debug aid;
    /// owner measures post-login, values print to stdout).
    public static func calibrate(args: [String]) -> Bool {
        args.contains("--teams-frame-calibrate")
    }

    /// --teams-frame-measure runs the JS geometry probe on every page
    /// load and prints the measured left/top insets (crop calibration).
    public static func measure(args: [String]) -> Bool {
        args.contains("--teams-frame-measure")
    }

    /// --teams-frame-library auto-opens the library sheet at appear
    /// (demo/verification; same sheet the Library button opens).
    public static func libraryOpen(args: [String]) -> Bool {
        args.contains("--teams-frame-library")
    }

    /// --teams-frame-kill-after <secs> destroys the frame N seconds after
    /// appear (kill-path verification; logs the footprint line). Garbage
    /// / missing / negative values → nil (no kill).
    public static func killAfter(args: [String]) -> TimeInterval? {
        guard let i = args.firstIndex(of: "--teams-frame-kill-after"),
              i + 1 < args.count,
              let secs = Double(args[i + 1]), secs >= 0
        else { return nil }
        return secs
    }

    /// UA suffix: stock WKWebView omits the `Version/… Safari/…` tokens
    /// and Teams serves /v2/unsupported-browser. Appending Safari tokens
    /// (truthful engine) gets the real app.
    public static let userAgentSuffix = "Version/17.4 Safari/605.1.15"

    /// Allowlist: Teams hosts + Microsoft auth/content hosts
    /// third-party apps need. Subdomains match via boundary suffix.
    public static let allowedHostSuffixes = [
        "teams.microsoft.com",
        "teams.live.com",
        "login.microsoftonline.com",
        "microsoftonline.com",
        "login.live.com",
        "live.com",
        "office.com",
        "office.net",
        "sharepoint.com",
        "onedrive.com",
    ]

    /// Host allowlist check. `about:blank` (no host, e.g. fresh webview)
    /// is allowed; every other hostless URL is not.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return url.scheme?.lowercased() == "about"
        }
        for suffix in allowedHostSuffixes {
            if host == suffix || host.hasSuffix("." + suffix) { return true }
        }
        return false
    }

    /// Escape decision matrix (pure; the coordinator executes it).
    /// Allowed → pass. Non-allowlisted top-level nav → yank (cancel +
    /// Open-in-Browser offer). Non-allowlisted subframe (app iframes,
    /// CDNs) → log + allow (yanking iframes would break apps).
    public static func escapeDecision(url: URL, isMainFrame: Bool) -> TeamsFrameEscapeDecision {
        if isAllowed(url) { return .allow }
        return isMainFrame ? .yank : .allowLogged
    }

    /// Popup intercept: only target-less opens (window.open / _blank,
    /// e.g. SSO) go to the sheet; in-frame targets stay put.
    public static func interceptsPopup(targetFrameIsNil: Bool) -> Bool {
        targetFrameIsNil
    }

    /// Unexpanded registry placeholder (the seed's `<APP_ENTITY_ID>` or
    /// any raw `<…>` token): unloadable (URL(string:) fails on angle
    /// brackets), so the window shows a guidance view instead of a
    /// blank frame. Owner pastes a real entity link via the URL entry.
    public static func isPlaceholderURL(_ raw: String) -> Bool {
        raw.contains("<") || raw.contains(">")
    }

    /// Keep-alive minutes seam (UserDefaults; default 15, 0 = instant).
    public static func keepAliveMinutes(defaults: UserDefaults) -> Int {
        if defaults.object(forKey: keepAliveMinutesKey) == nil {
            return defaultKeepAliveMinutes
        }
        return defaults.integer(forKey: keepAliveMinutesKey)
    }
}

/// Outcome of the escape decision matrix.
public enum TeamsFrameEscapeDecision: Equatable {
    case allow
    case allowLogged
    case yank
}

// MARK: - SSO bootstrap (one-way cookie copy; unit-tested filter)

/// The frame's isolated data store starts fresh (login-walled) while the
/// owner's Microsoft SSO session lives in `WKWebsiteDataStore.default()`
/// (BTBrowserAuthWebView). Same machine, same user, same app — at frame
/// activate, before the webview loads, copy the Microsoft session cookies
/// one way (default → frame). Never the reverse; nothing is written back.
public enum TeamsFrameSSO {
    /// Cookie domains eligible for the copy (boundary-suffix match).
    public static let cookieDomainSuffixes = [
        "microsoft.com",
        "microsoftonline.com",
        "live.com",
        "office.com",
        "office.net",
        "sharepoint.com",
        "onedrive.com",
    ]

    /// Pure filter: leading dots stripped, case-insensitive, boundary
    /// suffix (evil-microsoft.com does NOT match).
    public static func shouldCopyCookie(domain: String) -> Bool {
        var host = domain.lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        guard !host.isEmpty else { return false }
        for suffix in cookieDomainSuffixes {
            if host == suffix || host.hasSuffix("." + suffix) { return true }
        }
        return false
    }

    /// Copy matching cookies from the shared default store into `target`.
    /// Returns the copied count; never throws (empty session → 0).
    @MainActor
    public static func bootstrap(into target: WKWebsiteDataStore) async -> Int {
        print("[teams-frame] sso bootstrap: reading default jar…")
        let all: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies {
                cont.resume(returning: $0)
            }
        }
        var copied = 0
        for cookie in all where shouldCopyCookie(domain: cookie.domain) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                target.httpCookieStore.setCookie(cookie) { cont.resume() }
            }
            copied += 1
        }
        print("[teams-frame] sso bootstrap: \(copied)/\(all.count) cookies copied")
        return copied
    }

    /// Bootstrap with a timeout: the frame must never hang on cookie I/O
    /// (a wedged cookie store would pin the window on the spinner). Late
    /// completions still land their cookies; only the gate moves on.
    @MainActor
    public static func bootstrapWithTimeout(
        into target: WKWebsiteDataStore, seconds: Double
    ) async -> (copied: Int, timedOut: Bool) {
        final class Box: @unchecked Sendable { var done = false }
        let box = Box()
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                let n = await TeamsFrameSSO.bootstrap(into: target)
                if !box.done {
                    box.done = true
                    cont.resume(returning: (n, false))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if !box.done {
                    box.done = true
                    print("[teams-frame] sso bootstrap TIMEOUT after \(seconds)s, proceeding")
                    cont.resume(returning: (0, true))
                }
            }
        }
    }
}

// MARK: - Crop measurement (JS probe + pure result parser)

/// Live crop calibration: after the Teams page loads, probe the DOM for
/// the left app bar + top header geometry. The JS tries known Teams-web
/// selectors and returns JSON `{left,top,source}`; the Swift parser is
/// pure and unit-tested. Display-only (reads layout, clicks nothing).
public enum TeamsFrameMeasure {
    /// Probe script. Returns a JSON string, never throws (try/catch →
    /// `{"left":-1,"top":-1,"source":"error",…}` when nothing matches).
    /// `title`/`readyState`/`nodes` diagnose loads independently of paint.
    public static let script = """
    (function() {
      try {
        var left = -1, top = -1, src = "none";
        var rail = document.querySelector('[data-tid="app-bar"]')
          || document.querySelector('#app-bar')
          || document.querySelector('[aria-label="App bar"]');
        if (rail) { left = Math.round(rail.getBoundingClientRect().width); src = "app-bar"; }
        var header = document.querySelector('[data-tid="app-header"]')
          || document.querySelector('header');
        if (header) {
          var r = header.getBoundingClientRect();
          if (r.top <= 1 && r.width > window.innerWidth / 2) {
            top = Math.round(r.height); src += "+header";
          }
        }
        return JSON.stringify({left: left, top: top, source: src,
          title: document.title, readyState: document.readyState,
          nodes: document.getElementsByTagName("*").length});
      } catch (e) { return JSON.stringify({left: -1, top: -1, source: "error",
        title: "", readyState: "", nodes: -1}); }
    })()
    """

    /// Parse the probe result. Negative/zero → nil (no measurement).
    /// Caps at 400px per axis (a wider "rail" is page content, not chrome).
    public static func parseResult(_ json: String) -> TeamsFrameCrop? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let left = (obj["left"] as? NSNumber)?.doubleValue,
              let top = (obj["top"] as? NSNumber)?.doubleValue,
              left > 0, top > 0, left <= 400, top <= 400
        else { return nil }
        return TeamsFrameCrop(left: CGFloat(left), top: CGFloat(top))
    }
}

// MARK: - Crop (per-app, Codable; nil → v0 default)

/// Native clip insets hiding the Teams left rail + top header.
/// v0 (left 68, top 48 @1x) are ESTIMATES from public Teams-web layout —
/// NOT measured live until the owner calibrates post-login
/// (--teams-frame-calibrate). Per-app overrides live on TeamsFrameApp.
public struct TeamsFrameCrop: Equatable, Codable {
    public var left: CGFloat
    public var top: CGFloat

    public init(left: CGFloat, top: CGFloat) {
        self.left = left
        self.top = top
    }

    public static let v0 = TeamsFrameCrop(left: 68, top: 48)
    public static let none = TeamsFrameCrop(left: 0, top: 0)
}

// MARK: - App registry (UserDefaults JSON; unit-tested)

/// One third-party Teams app: entity deep link + optional crop override.
/// `crop == nil` → TeamsFrameCrop.v0.
public struct TeamsFrameApp: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var entityURL: String
    public var crop: TeamsFrameCrop?

    public init(id: String, label: String, entityURL: String, crop: TeamsFrameCrop? = nil) {
        self.id = id
        self.label = label
        self.entityURL = entityURL
        self.crop = crop
    }

    public var effectiveCrop: TeamsFrameCrop { crop ?? .v0 }
}

/// JSON-in-UserDefaults store. Missing/corrupt/empty → seed (one
/// placeholder entry, no real org URLs — owner pastes real entity links).
public enum TeamsFrameRegistry {
    public static let appsKey = "teamsFrameApps"
    public static let selectedAppKey = "teamsFrameSelectedAppID"

    public static let seedApps = [
        TeamsFrameApp(
            id: "sample-app",
            label: "Sample App",
            entityURL: "https://teams.microsoft.com/l/entity/<APP_ENTITY_ID>?label=Sample")
    ]

    public static func loadApps(defaults: UserDefaults) -> [TeamsFrameApp] {
        guard let data = defaults.data(forKey: appsKey),
              let apps = try? JSONDecoder().decode([TeamsFrameApp].self, from: data),
              !apps.isEmpty
        else { return seedApps }
        return apps
    }

    public static func saveApps(_ apps: [TeamsFrameApp], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        defaults.set(data, forKey: appsKey)
    }

    public static func loadSelectedID(defaults: UserDefaults) -> String? {
        defaults.string(forKey: selectedAppKey)
    }

    public static func saveSelectedID(_ id: String?, defaults: UserDefaults) {
        if let id {
            defaults.set(id, forKey: selectedAppKey)
        } else {
            defaults.removeObject(forKey: selectedAppKey)
        }
    }
}

// MARK: - Footprint (best-effort resident MB; unit-tested for safety)

/// Process resident size via task_info. Decimal MB (matches Activity
/// Monitor). Nil on any failure — destroy() logs "unknown", never crashes.
public enum TeamsFrameFootprint {
    public static func residentMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1_000_000
    }
}

// MARK: - Downloads (pure seams; unit-tested)

public enum TeamsFrameDownloads {
    /// Save-panel default directory.
    public static func defaultDirectory() -> URL {
        UserFolders.downloads()
    }

    /// Strip path separators / blank → safe save-panel filename.
    public static func sanitizedFilename(_ name: String) -> String {
        let stripped = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "download" : trimmed
    }
}

// MARK: - Popup model

/// SSO popup (window.open/_blank): the coordinator builds the WKWebView,
/// the store publishes it, the window shows it as a modal sheet.
/// `webView == nil` only in unit tests (state transitions, no live view).
public final class TeamsFramePopup: ObservableObject, Identifiable {
    public let id = UUID()
    public let webView: WKWebView?
    public let url: URL?

    public init(webView: WKWebView? = nil, url: URL? = nil) {
        self.webView = webView
        self.url = url
    }
}

// MARK: - Lifecycle store

/// Owns the frame data store + registry selection.
/// destroy() nils the store.
///
/// CPU/RAM posture (owner directive, aggressive):
/// - Lazy init: store/webview exist only after the surface appears
///   (activate on window appear). Fresh store holds NO web objects.
/// - NO process prewarm at app launch — deliberate: the frame costs zero
///   until opened. (Prewarm would trade launch latency for idle footprint;
///   the frame is a cold-start surface, so we keep it cold.)
/// - Hide (deactivate): stopLoading + drop script message handlers so a
///   hidden frame burns no CPU; keep-alive timer still honored.
/// - Destroy: logs the resident-MB footprint line, then nils everything.
/// - No polling while hidden: the ONLY Timer is the one-shot keep-alive
///   (repeats:false); no Task.sleep anywhere in this file.
/// Test seams: injectable UserDefaults, keepAliveArmed/suspended readback.
@MainActor
public final class TeamsFrameStore: ObservableObject {
    @Published public var alive = true
    // Published: activate() runs in onAppear (after first body eval) —
    // the publishes re-evaluate the body and create the webview.
    @Published public private(set) var dataStore: WKWebsiteDataStore?
    @Published public var apps: [TeamsFrameApp]
    @Published public var selectedAppID: String?
    /// Catalog URL entry override (session-only, not persisted): when set,
    /// the frame loads it instead of the selected app's entity link.
    @Published public var customURLString: String?
    @Published public var calibrationCrop = TeamsFrameCrop.v0
    @Published public var popup: TeamsFramePopup?
    /// SSO gate: webview creation waits for the one-way cookie copy.
    @Published public private(set) var ssoReady = false
    @Published public private(set) var ssoCookieCount = 0
    /// --teams-frame-measure: probe crop geometry on every page load.
    public var autoMeasure = false
    public private(set) var keepAliveArmed = false
    public private(set) var suspended = false
    /// Weak: set by the representable on creation; used for hide-suspend.
    public weak var activeWebView: WKWebView?
    private var timer: Timer?
    private var launchURLApplied = false
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.apps = TeamsFrameRegistry.loadApps(defaults: defaults)
        self.selectedAppID = TeamsFrameRegistry.loadSelectedID(defaults: defaults)
        // Clamp a stale persisted selection to the first app.
        if let id = selectedAppID, !apps.contains(where: { $0.id == id }) {
            selectedAppID = nil
        }
    }

    public var keepAliveMinutes: Int {
        TeamsFrameConfig.keepAliveMinutes(defaults: defaults)
    }

    public var selectedApp: TeamsFrameApp? {
        if let id = selectedAppID, let app = apps.first(where: { $0.id == id }) {
            return app
        }
        return apps.first
    }

    public var currentURLString: String {
        if let custom = customURLString, !custom.isEmpty { return custom }
        return selectedApp?.entityURL ?? TeamsFrameConfig.defaultURL
    }

    public var currentCrop: TeamsFrameCrop {
        if customURLString != nil { return .v0 }
        return selectedApp?.effectiveCrop ?? .v0
    }

    /// Switcher pick: persist selection, clear any custom URL override.
    /// The SAME webview navigates (updateNSView) — session kept, no re-auth.
    public func selectApp(id: String?) {
        selectedAppID = id
        customURLString = nil
        TeamsFrameRegistry.saveSelectedID(id, defaults: defaults)
        if let app = selectedApp {
            print("[teams-frame] app selected: \(app.label)")
        }
    }

    /// Catalog URL entry: validate lightly, load in the SAME frame.
    public func loadCustomURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            print("[teams-frame] BAD CUSTOM URL: \(raw)")
            return
        }
        customURLString = trimmed
        print("[teams-frame] custom URL loaded in frame: \(trimmed)")
    }

    /// Surface entry: (re)build the store, cancel pending destroy.
    /// The CLI launch URL applies once (first appear); later appears keep
    /// the user's switcher pick. The SSO bootstrap (one-way cookie copy)
    /// runs before the webview loads; the window gates creation on
    /// `ssoReady`.
    public func activate(launchURL: String? = nil) {
        timer?.invalidate()
        timer = nil
        keepAliveArmed = false
        suspended = false
        if !launchURLApplied {
            launchURLApplied = true
            if let launch = launchURL, launch != TeamsFrameConfig.defaultURL {
                customURLString = launch
            }
        }
        if dataStore == nil {
            dataStore = WKWebsiteDataStore(
                forIdentifier: TeamsFrameConfig.dataStoreIdentifier)
        }
        if !alive { alive = true }
        print("[teams-frame] activate (keepAlive \(keepAliveMinutes) min)")
        if let ds = dataStore {
            ssoReady = false
            Task { @MainActor [weak self] in
                let result = await TeamsFrameSSO.bootstrapWithTimeout(into: ds, seconds: 5)
                self?.ssoCookieCount = result.copied
                self?.ssoReady = true
            }
        }
    }

    /// Surface exit: suspend the hidden webview now, then destroy now (0)
    /// or arm the keep-alive timer.
    public func deactivate() {
        suspended = true
        activeWebView?.stopLoading()
        activeWebView?.configuration.userContentController.removeAllScriptMessageHandlers()
        let mins = keepAliveMinutes
        if mins <= 0 {
            print("[teams-frame] deactivate: keepAlive 0 → destroy")
            destroy()
            return
        }
        timer?.invalidate()
        keepAliveArmed = true
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(mins * 60), repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                print("[teams-frame] keep-alive expired → destroy")
                self?.destroy()
            }
        }
        print("[teams-frame] deactivate: destroy in \(mins) min")
    }

    /// Instant destroy: log the footprint, nil the view inputs; the
    /// web processes exit with their views. Menu "Kill App Frame" lands here.
    public func destroy() {
        if let mb = TeamsFrameFootprint.residentMB() {
            print(String(format: "[teams-frame] footprint before destroy: %.1f MB resident", mb))
        } else {
            print("[teams-frame] footprint before destroy: unknown")
        }
        timer?.invalidate()
        timer = nil
        keepAliveArmed = false
        suspended = false
        activeWebView = nil
        dataStore = nil
        popup = nil
        ssoReady = false
        ssoCookieCount = 0
        alive = false
        print("[teams-frame] DESTROYED")
    }

    // MARK: Registry mutations (persisted; seed returns when empty)

    /// Library one-tap / paste-link add. Replaces same-id entries (re-add
    /// updates the URL); selects the added app.
    public func addApp(_ app: TeamsFrameApp) {
        apps.removeAll { $0.id == app.id }
        apps.append(app)
        TeamsFrameRegistry.saveApps(apps, defaults: defaults)
        selectApp(id: app.id)
        print("[teams-frame] app added: \(app.label)")
    }

    /// Remove from the registry. Removing the last entry re-seeds the
    /// placeholder (registry is never persisted empty).
    public func removeApp(id: String) {
        apps.removeAll { $0.id == id }
        if apps.isEmpty {
            apps = TeamsFrameRegistry.seedApps
        }
        TeamsFrameRegistry.saveApps(apps, defaults: defaults)
        if selectedAppID == id {
            selectedAppID = nil
            TeamsFrameRegistry.saveSelectedID(nil, defaults: defaults)
        }
        print("[teams-frame] app removed: \(id) (\(apps.count) left)")
    }

    /// Per-app crop override (nil clears back to v0). Persisted.
    public func updateCrop(id: String, crop: TeamsFrameCrop?) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[i].crop = crop
        TeamsFrameRegistry.saveApps(apps, defaults: defaults)
        if let crop {
            print("[teams-frame] crop override \(id): left=\(Int(crop.left)) top=\(Int(crop.top))")
        } else {
            print("[teams-frame] crop override \(id) cleared (v0)")
        }
    }

    /// One-shot JS geometry probe on the live webview (Measure button /
    /// auto-measure). Display-only: reads layout, clicks nothing.
    public func measureCropOnce() {
        guard let view = activeWebView else {
            print("[teams-frame] measure: no live webview")
            return
        }
        view.evaluateJavaScript(TeamsFrameMeasure.script) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    print("[teams-frame] measure failed: \(error.localizedDescription)")
                    return
                }
                guard let json = result as? String else {
                    print("[teams-frame] measure: unexpected result type")
                    return
                }
                if let crop = TeamsFrameMeasure.parseResult(json) {
                    self.calibrationCrop = crop
                    print("[teams-frame] MEASURED: left=\(Int(crop.left)) top=\(Int(crop.top)) (\(json))")
                } else {
                    print("[teams-frame] measure: no chrome found (\(json))")
                }
            }
        }
    }

    public func presentPopup(_ popup: TeamsFramePopup) {
        self.popup = popup
        print("[teams-frame] popup presented: \(popup.url?.absoluteString ?? "?")")
    }

    public func closePopup() {
        popup = nil
        print("[teams-frame] popup closed")
    }
}
