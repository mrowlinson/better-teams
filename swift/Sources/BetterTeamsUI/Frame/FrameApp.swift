// FrameApp.swift — the web-app model (UI-SPEC §7.1), the pure frame
// policy (launch resolution, eviction), and the process-wide directory
// that names web apps for the rail, menus and titles.
import Foundation
import OstMacCore
import os

/// How an app loads (§7.1 `launch`).
public enum FrameLaunch: Equatable, Sendable {
    /// Teams-hosted entity page (`/_#/l/entity/…`).
    case teamsHosted(URL)
    /// Standalone allow-listed page, no Teams chrome.
    case direct(URL)
    /// Opens in the default browser (the only "not otherwise possible" case).
    case external(URL)
    /// A Teams app with a manifest, hosted natively over TeamsJS (no
    /// Teams web shell); `fallback` is its Teams-shell page.
    case teamsApp(TeamsAppLaunch)

    public var url: URL {
        switch self {
        case .teamsHosted(let u), .direct(let u), .external(let u): u
        case .teamsApp(let l): l.fallback
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
    /// Teams-shell page for the same tab (per-app fallback).
    public var fallback: URL
    /// `webApplicationInfo`: SSO token audience for getAuthToken.
    public var resource: String?
    public var webAppID: String?
    public var validDomains: [String]
    public var transport: TeamsJSTransport
    /// Demo: local sample page, no network.
    public var demoHTML: String?
    /// Channel tab context (APPHOST-B2): nil for personal apps.
    public var channel: TeamsAppChannelContext?

    public init(appID: String, entityID: String, contentTemplate: String, fallback: URL,
                resource: String? = nil, webAppID: String? = nil, validDomains: [String] = [],
                transport: TeamsJSTransport = .frameless, demoHTML: String? = nil,
                channel: TeamsAppChannelContext? = nil) {
        self.channel = channel
        self.appID = appID
        self.entityID = entityID
        self.contentTemplate = contentTemplate
        self.fallback = fallback
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
                  fallback: Self.teamsEntityURL(appID: m.id, entityID: tab.entityId),
                  resource: m.webApplicationInfo?.resource, webAppID: m.webApplicationInfo?.id,
                  validDomains: m.validDomains)
    }

    /// `https://teams.microsoft.com/_#/l/entity/<app>/<entity>`: the
    /// app's personal tab inside Teams on the web.
    public static func teamsEntityURL(appID: String, entityID: String) -> URL {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? s }
        return FramePolicy.hashRoute(URL(string: "https://teams.microsoft.com/l/entity/\(enc(appID))/\(enc(entityID))")!)
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
        if hostMatches(host, ["teams.microsoft.com", "teams.live.com"]) {
            return .teamsHosted(hashRoute(url))
        }
        return .external(url)
    }

    /// `/l/entity/…` → `/_#/l/entity/…`, which skips the launcher
    /// interstitial (FRAME-LIVE-PROOF). Other paths unchanged.
    static func hashRoute(_ url: URL) -> URL {
        guard url.path.hasPrefix("/l/entity/"), var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        let tail = c.path + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        c.path = "/_"
        c.percentEncodedQuery = nil
        c.fragment = tail
        return c.url ?? url
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
    /// "Teams on the Web": full Teams, no crop (§7.2 Built-in).
    public static let teamsWebID: FrameAppID = "teams-web"

    public static let teamsWeb = FrameApp(
        id: teamsWebID, label: "Teams on the Web", symbol: "globe",
        source: .teamsWeb, launch: .direct(URL(string: TeamsFrameConfig.defaultURL)!))
}

/// Deterministic demo apps (no network: demo pages are local HTML).
public enum DemoFrameApps {
    static func tab(_ id: String, _ label: String, _ symbol: String, _ url: String) -> FrameApp {
        FrameApp(id: id, label: label, symbol: symbol,
                 source: .channelTab(team: "Marketing", channel: "Launch Plan"),
                 launch: FramePolicy.launch(url: url, label: label)!)
    }

    public static let channelTabs: [FrameApp] = [
        tab("web-demo", "Wiki", "doc.richtext", "https://contoso.sharepoint.com/sites/marketing/wiki"),
        tab("web-demo-board", "Release Board", "rectangle.split.3x1",
            "https://tasks.office.com/contoso/board"),
        tab("web-demo-roadmap", "Roadmap", "map", "https://contoso.sharepoint.com/sites/marketing/roadmap"),
        tab("web-demo-status", "Status Page", "waveform.path.ecg", "https://status.example.com"),
    ]

    public static let webLinks: [FrameApp] = [
        FrameApp(id: "web-demo-handbook", label: "Employee Handbook", symbol: "book",
                 source: .webLink,
                 launch: .direct(URL(string: "https://contoso.sharepoint.com/sites/hr/handbook")!)),
    ]

    /// `pins=<n>` seeds (rail overflow evidence).
    public static let seeded: [FrameApp] = (1...20).map { i in
        FrameApp(id: "web-demo-\(i)", label: "Web App \(i)", symbol: "globe", source: .webLink,
                 launch: .direct(URL(string: "https://contoso.sharepoint.com/sites/app\(i)")!))
    }
}
