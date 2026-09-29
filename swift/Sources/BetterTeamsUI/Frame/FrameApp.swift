// FrameApp.swift — the web-app model (UI-SPEC §7.1), the pure frame
// policy (launch resolution, eviction), and the process-wide directory
// that names web apps for the rail, menus and titles.
import Foundation
import OstMacCore
import os

/// How an app loads (§7.1 `launch`).
public enum FrameLaunch: Equatable, Sendable {
    /// A Teams link (`/l/entity/…`, `/l/channel/…`): opens its native view
    /// (the app host, a channel tab, a chat). Never loaded as a page: the
    /// Teams web app does not run in Better Teams (APPNATIVE4).
    case teamsLink(URL)
    /// Standalone allow-listed page, no Teams chrome.
    case direct(URL)
    /// Opens in the default browser (the only "not otherwise possible" case).
    case external(URL)
    /// A Teams app with a manifest, hosted natively over TeamsJS (no
    /// Teams web shell, and no Teams web page to fall back to).
    case teamsApp(TeamsAppLaunch)

    /// The address this launch shows or links to. A hosted app: its own
    /// content page (placeholders empty), never a Teams web page.
    public var url: URL {
        switch self {
        case .teamsLink(let u), .direct(let u), .external(let u): u
        case .teamsApp(let l):
            URL(string: TeamsJSPolicy.expand(l.contentTemplate, TeamsJSAppContext())) ?? URL(string: "about:blank")!
        }
    }

    public var runsInApp: Bool {
        if case .external = self { return false }
        return true
    }
}

/// How a manifest app opens in the native TeamsJS host (APPHOST).
public struct TeamsAppLaunch: Equatable, Sendable {
    public var appID: String
    public var entityID: String
    /// Manifest contentUrl, placeholders unexpanded (`{tid}`, `{locale}`…).
    public var contentTemplate: String
    /// `webApplicationInfo`: SSO token audience for getAuthToken.
    public var resource: String?
    public var webAppID: String?
    public var validDomains: [String]
    public var transport: TeamsJSTransport
    /// Demo: local sample page, no network.
    public var demoHTML: String?
    /// Channel tab context (APPHOST-B2): nil for personal apps.
    public var channel: TeamsAppChannelContext?
    /// Manifest / tab websiteUrl, placeholders unexpanded: the app's own
    /// web page. Tried once, on its own host only, when the Teams-embedded
    /// page stays blank (APPNATIVE3).
    public var websiteTemplate: String?

    public init(appID: String, entityID: String, contentTemplate: String,
                resource: String? = nil, webAppID: String? = nil, validDomains: [String] = [],
                transport: TeamsJSTransport = .frameless, demoHTML: String? = nil,
                channel: TeamsAppChannelContext? = nil, website: String? = nil) {
        self.channel = channel
        self.websiteTemplate = website
        self.appID = appID
        self.entityID = entityID
        self.contentTemplate = contentTemplate
        self.resource = resource
        self.webAppID = webAppID
        self.validDomains = validDomains
        self.transport = transport
        self.demoHTML = demoHTML
    }

    /// From a catalog manifest: its first personal static tab. Nil when
    /// the app has no hostable personal page.
    public init?(manifest m: TeamsAppManifest) {
        guard let tab = m.personalTab, let content = tab.contentUrl else { return nil }
        self.init(appID: m.id, entityID: tab.entityId, contentTemplate: content,
                  resource: m.webApplicationInfo?.resource, webAppID: m.webApplicationInfo?.id,
                  validDomains: m.validDomains, website: tab.websiteUrl)
    }
}

/// Team/channel a configurable tab runs in (TeamsJS context
/// `teamId`/`channelId`/`groupId`, placeholders `{teamId}`/`{channelId}`).
public struct TeamsAppChannelContext: Equatable, Sendable {
    public var teamID: String
    public var channelID: String
    public var groupID: String?
    public var teamName: String
    public var channelName: String

    public init(teamID: String, channelID: String, groupID: String? = nil, teamName: String, channelName: String) {
        self.teamID = teamID
        self.channelID = channelID
        self.groupID = groupID
        self.teamName = teamName
        self.channelName = channelName
    }
}

/// Where an app came from (§7.1 `source`).
public enum FrameSource: Equatable, Sendable {
    case channelTab(team: String, channel: String)
    case personal
    case webLink
    case teamsWeb
}

/// One web app (§7.1).
public struct FrameApp: Equatable, Sendable, Identifiable {
    public var id: FrameAppID
    public var label: String
    public var symbol: String
    public var source: FrameSource
    public var launch: FrameLaunch

    public init(id: FrameAppID, label: String, symbol: String, source: FrameSource, launch: FrameLaunch) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.source = source
        self.launch = launch
    }

    /// Library source line ("Marketing › Launch Plan", "Web Link", …).
    public var sourceLine: String {
        switch source {
        case .channelTab(let team, let channel): "\(team) › \(channel)"
        case .personal: "Personal App"
        case .webLink: "Web Link"
        case .teamsWeb: "Microsoft Teams"
        }
    }
}

/// A user-added web link (persisted per account).
public struct WebLink: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var url: String
    /// SF Symbol picked in Add Web Link (nil on links saved before the
    /// picker = `link`).
    public var symbol: String?
}

// MARK: - Policy (pure; unit-tested)

/// The Teams web app. No pane, tab, popup or fallback ever loads it
/// (APPNATIVE4: "we should never be loading the full webapp"): Teams
/// links route to native views instead. App pages Microsoft hosts on
/// the Teams hosts (Shifts, …) are apps, not the web app.
public enum TeamsWebGuard {
    public static let hosts = ChatTabCatalog.teamsHosts

    public static func isTeamsWeb(_ url: URL) -> Bool {
        ChatTabCatalog.isTeamsWebApp(url)
    }

    /// Whether a navigation is refused: any Teams web address, in the
    /// main frame, a subframe or a popup. The single exception is the
    /// iframe transport's own host document (a local HTML string at the
    /// Teams origin, no network), and only as the main frame.
    public static func refuses(_ url: URL, mainFrame: Bool, iframeHostDocument: Bool) -> Bool {
        guard isTeamsWeb(url) else { return false }
        return !(mainFrame && iframeHostDocument)
    }
}

public enum FramePolicy {
    /// Allow-listed standalone hosts: load directly, no Teams chrome (§7.1 rule 2).
    public static let standaloneHosts = [
        "sharepoint.com", "onedrive.com", "office.com", "office.net", "powerbi.com", "onenote.com",
    ]

    /// Channel tabs that are native views, never frames (§7.1 rule 1).
    public static let nativeTabNames: Set<String> = ["Posts", "Files", "Notes"]

    /// Launch resolution, first match wins (§7.1). Nil = not an app
    /// (native tab or unparseable URL).
    public static func launch(url raw: String, label: String = "") -> FrameLaunch? {
        if nativeTabNames.contains(label) { return nil }
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http" else { return .external(url) }
        guard let host = url.host?.lowercased() else { return nil }
        if hostMatches(host, standaloneHosts) { return .direct(url) }
        if TeamsWebGuard.isTeamsWeb(url) { return .teamsLink(url) }
        return .external(url)
    }

    static func hostMatches(_ host: String, _ suffixes: [String]) -> Bool {
        suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: eviction (§7.3)

    /// Settings ▸ Apps ▸ Keep apps in memory: Low 1 / Balanced 3 / High 6.
    public static let keepInMemoryKey = "bt.frame.keepInMemory"

    public static func keepInMemory(_ defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: keepInMemoryKey)
        return [1, 3, 6].contains(v) ? v : 3
    }

    public enum Pressure: Sendable { case normal, warning, critical }

    public struct Resident: Equatable, Sendable {
        public var key: String
        public var visible: Bool
        public var lastUsed: Date
        public var suspended: Bool

        public init(key: String, visible: Bool, lastUsed: Date, suspended: Bool = false) {
            self.key = key
            self.visible = visible
            self.lastUsed = lastUsed
            self.suspended = suspended
        }
    }

    /// Keys to evict: never a visible view; beyond `cap` non-visible
    /// views, least recently used first. `.warning` also evicts every
    /// suspended view, `.critical` every non-visible view.
    public static func evict(_ residents: [Resident], cap: Int, pressure: Pressure = .normal) -> [String] {
        let hidden = residents.filter { !$0.visible }.sorted { $0.lastUsed > $1.lastUsed }
        switch pressure {
        case .critical:
            return hidden.map(\.key)
        case .warning, .normal:
            var out = hidden.dropFirst(max(0, cap)).map(\.key)
            if pressure == .warning {
                out += hidden.prefix(max(0, cap)).filter(\.suspended).map(\.key)
            }
            return out
        }
    }

    /// Warm views past the keep-alive (§7.3 `suspended`).
    public static func suspend(_ residents: [Resident], now: Date, keepAlive: TimeInterval) -> [String] {
        residents.filter { !$0.visible && !$0.suspended && now.timeIntervalSince($0.lastUsed) >= keepAlive }
            .map(\.key)
    }
}

// MARK: - Directory

/// Names every known web app, process-wide (rail titles, Go menu,
/// window titles are nonisolated lookups). Filled by the Apps library.
public enum FrameAppDirectory {
    private static let apps = OSAllocatedUnfairLock<[FrameAppID: FrameApp]>(initialState: [:])

    public static func register(_ list: [FrameApp]) {
        apps.withLock { d in for a in list { d[a.id] = a } }
    }

    public static func remove(_ id: FrameAppID) {
        _ = apps.withLock { $0.removeValue(forKey: id) }
    }

    public static func app(_ id: FrameAppID) -> FrameApp? {
        apps.withLock { $0[id] }
    }

    public static func title(_ id: FrameAppID) -> String {
        if let a = app(id) { return a.label }
        if id.hasPrefix("web-demo-") { return "Web App \(id.dropFirst(9))" }
        return "Web App"
    }

    public static func symbol(_ id: FrameAppID) -> String {
        app(id)?.symbol ?? "globe"
    }
}

// MARK: - Built-ins and demo fixtures

public enum FrameBuiltIns {
    /// The retired "Teams on the Web" built-in (APPNATIVE4: the Teams web
    /// app never loads); a rail pin saved under this id is dropped.
    public static let retiredTeamsWebID: FrameAppID = "teams-web"
}

/// Deterministic demo apps (no network: demo pages are local HTML).
public enum DemoFrameApps {
    static func link(_ id: String, _ label: String, _ symbol: String, _ url: String) -> FrameApp {
        FrameApp(id: id, label: label, symbol: symbol, source: .webLink,
                 launch: FramePolicy.launch(url: url, label: label)!)
    }

    /// Demo web links (the Apps list shows apps only, never channel tabs).
    public static let webLinks: [FrameApp] = [
        link("web-demo", "Wiki", "doc.richtext", "https://contoso.sharepoint.com/sites/marketing/wiki"),
        link("web-demo-board", "Release Board", "rectangle.split.3x1", "https://tasks.office.com/contoso/board"),
        link("web-demo-roadmap", "Roadmap", "map", "https://contoso.sharepoint.com/sites/marketing/roadmap"),
        link("web-demo-status", "Status Page", "waveform.path.ecg", "https://status.example.com"),
        link("web-demo-handbook", "Employee Handbook", "book", "https://contoso.sharepoint.com/sites/hr/handbook"),
    ]

    /// `pins=<n>` seeds (rail overflow evidence).
    public static let seeded: [FrameApp] = (1...20).map { i in
        FrameApp(id: "web-demo-\(i)", label: "Web App \(i)", symbol: "globe", source: .webLink,
                 launch: .direct(URL(string: "https://contoso.sharepoint.com/sites/app\(i)")!))
    }
}
