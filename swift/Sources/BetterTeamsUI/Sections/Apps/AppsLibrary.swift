// AppsLibrary.swift — the app library for one account window (UI-SPEC
// §7.2): Built-in (native apps + Teams on the Web, always present),
// Channel Tabs (teams-cli `tabs-all` scan, cached), Personal Apps (gap
// G2), Web Links (user-added, per account). Demo: deterministic
// fixtures, no CLI, no user defaults.
import Foundation
import Observation
import OstMacCore

/// One library row: a native app or a web app.
struct LibraryItem: Identifiable, Equatable {
    let entry: RailEntry
    let title: String
    let symbol: String
    let sourceLine: String
    /// Nil for native apps.
    let launch: FrameLaunch?
    let isWebLink: Bool

    /// Selection id: a native app's raw value or the web app id (routes
    /// `apps/<id>`, `app/<id>`).
    var id: String {
        switch entry {
        case .native(let n): n.rawValue
        case .web(let id): id
        }
    }

    var runsInApp: Bool { launch?.runsInApp ?? true }

    init(native n: NativeAppID) {
        entry = .native(n)
        title = n.title
        symbol = n.symbol
        sourceLine = "Built-in"
        launch = nil
        isWebLink = false
    }

    init(_ app: FrameApp) {
        entry = .web(app.id)
        title = app.label
        symbol = app.symbol
        sourceLine = app.source == .teamsWeb ? "Built-in" : app.sourceLine
        launch = app.launch
        isWebLink = app.source == .webLink
    }

    func matches(_ filter: String) -> Bool {
        filter.isEmpty || title.localizedCaseInsensitiveContains(filter)
            || sourceLine.localizedCaseInsensitiveContains(filter)
    }
}

@Observable
@MainActor
final class AppsLibrary {
    private(set) var channelTabs: [FrameApp] = []
    private(set) var webLinks: [FrameApp] = []
    private(set) var scanning = false
    private(set) var scanError: String?
    /// A scan result (or cache) exists.
    private(set) var scanned = false
    /// "Scanning 12 of 22 channels" is not reported by teams-cli; the
    /// scan is one call, so progress is indeterminate.
    @ObservationIgnored let demo: Bool
    @ObservationIgnored private let accountKey: String

    init(accountKey: String) {
        self.accountKey = accountKey
        demo = accountKey == "demo"
        if demo {
            channelTabs = DemoFrameApps.channelTabs
            webLinks = DemoFrameApps.webLinks
            scanned = true
            FrameAppDirectory.register(DemoFrameApps.seeded)
        } else {
            let cache = TeamsFrameLibrary.loadCache(defaults: .standard)
            channelTabs = Self.apps(from: cache)
            scanned = !cache.isEmpty
            webLinks = Self.loadLinks(accountKey).compactMap(Self.app(from:))
        }
        FrameAppDirectory.register([FrameBuiltIns.teamsWeb] + channelTabs + webLinks)
    }

    var builtIns: [LibraryItem] {
        NativeAppID.allCases.map(LibraryItem.init(native:)) + [LibraryItem(FrameBuiltIns.teamsWeb)]
    }

    func app(_ id: FrameAppID) -> FrameApp? {
        if id == FrameBuiltIns.teamsWebID { return FrameBuiltIns.teamsWeb }
        if let a = channelTabs.first(where: { $0.id == id }) ?? webLinks.first(where: { $0.id == id }) {
            return a
        }
        return demo ? DemoFrameApps.seeded.first { $0.id == id } : nil
    }

    func item(_ id: String) -> LibraryItem? {
        if let n = NativeAppID(rawValue: id) { return LibraryItem(native: n) }
        return app(id).map(LibraryItem.init)
    }

    func item(for e: RailEntry) -> LibraryItem? {
        switch e {
        case .native(let n): LibraryItem(native: n)
        case .web(let id): app(id).map(LibraryItem.init)
        }
    }

    // MARK: channel tab scan (teams-cli, absolute path only)

    /// Refresh Library (toolbar) and the inline Retry share this answer.
    func canRefresh(offline: Bool) -> Bool { !demo && !scanning && !offline }

    func refresh() {
        guard !demo, !scanning else { return }
        scanning = true
        scanError = nil
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<String, Error> in
                guard let cli = TeamsFrameLibrary.resolveCLI() else {
                    return .failure(TeamsFrameLibraryError.cliNotFound)
                }
                return Result { try TeamsFrameLibrary.runTabsAll(cli: cli) }
            }.value
            self?.finish(result.map(TeamsFrameLibrary.parseTabsAll))
        }
    }

    private func finish(_ result: Result<[TeamsFrameLibraryEntry], Error>) {
        scanning = false
        switch result {
        case .success(let entries):
            TeamsFrameLibrary.saveCache(entries, defaults: .standard)
            channelTabs = Self.apps(from: entries)
            scanned = true
            FrameAppDirectory.register(channelTabs)
        case .failure(let e):
            if case TeamsFrameLibraryError.cliNotFound = e {
                scanError = "The channel scanner isn't included in this build."
            } else if case TeamsFrameLibraryError.cliFailed(let msg) = e, !msg.isEmpty {
                scanError = msg
            } else {
                scanError = e.localizedDescription
            }
        }
    }

    static func apps(from entries: [TeamsFrameLibraryEntry]) -> [FrameApp] {
        entries.compactMap { e in
            guard let launch = FramePolicy.launch(url: e.url, label: e.label) else { return nil }
            let id = "ct." + e.id.replacingOccurrences(of: "|", with: ".").replacingOccurrences(of: " ", with: "-")
            return FrameApp(id: id, label: e.label, symbol: "globe",
                            source: .channelTab(team: e.team, channel: e.channel), launch: launch)
        }
        .sorted { ($0.sourceLine, $0.label) < ($1.sourceLine, $1.label) }
    }

    // MARK: web links (per account; demo in memory)

    private static func linksKey(_ account: String) -> String { "bt.webLinks.\(account)" }

    private static func loadLinks(_ account: String) -> [WebLink] {
        guard let data = UserDefaults.standard.data(forKey: linksKey(account)),
              let list = try? JSONDecoder().decode([WebLink].self, from: data) else { return [] }
        return list
    }

    private static func app(from l: WebLink) -> FrameApp? {
        guard let launch = FramePolicy.launch(url: l.url) else { return nil }
        return FrameApp(id: l.id, label: l.name, symbol: l.symbol ?? "link", source: .webLink, launch: launch)
    }

    /// Returns the new app, nil for an unusable URL.
    @discardableResult
    func addWebLink(name: String, url: String, symbol: String = "link") -> FrameApp? {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard let u = URL(string: raw), u.host != nil else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = WebLink(id: "wl." + UUID().uuidString.prefix(8).lowercased(),
                           name: title.isEmpty ? (u.host ?? raw) : title, url: raw, symbol: symbol)
        guard let app = Self.app(from: link) else { return nil }
        webLinks.append(app)
        FrameAppDirectory.register([app])
        saveLinks()
        return app
    }

    func removeWebLink(_ id: FrameAppID) {
        webLinks.removeAll { $0.id == id }
        FrameAppDirectory.remove(id)
        saveLinks()
    }

    private func saveLinks() {
        guard !demo else { return }
        let list = webLinks.map {
            WebLink(id: $0.id, name: $0.label, url: $0.launch.url.absoluteString, symbol: $0.symbol)
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.linksKey(accountKey))
        }
    }
}
