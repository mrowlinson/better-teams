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
    /// Personal apps from the Teams app catalog (APPHOST): hosted
    /// natively over TeamsJS. App bar (userpinned) order first.
    private(set) var personalApps: [FrameApp] = []
    /// A catalog fetch is running (Personal Apps shows a quiet spinner
    /// over its cached rows, never a blank list).
    private(set) var catalogLoading = false
    private(set) var catalogError: String?
    /// Teams app bar order, catalog app ids mapped to library ids.
    private(set) var catalogPinned: [FrameAppID] = []
    /// Called once per successful catalog fetch with `catalogPinned`.
    @ObservationIgnored var onCatalogPinned: (([FrameAppID]) -> Void)?
    private(set) var scanning = false
    private(set) var scanError: String?
    /// A scan result (or cache) exists.
    private(set) var scanned = false
    /// "Scanning 12 of 22 channels" is not reported by teams-cli; the
    /// scan is one call, so progress is indeterminate.
    @ObservationIgnored let demo: Bool
    @ObservationIgnored private let accountKey: String
    /// The Apps store (APPHOST-B2): browse, search, detail, install.
    @ObservationIgnored let store: AppStoreModel
    /// Installed catalog manifests (store "Installed", tab matching).
    @ObservationIgnored private var catalogManifests: [TeamsAppManifest] = []

    init(accountKey: String) {
        self.accountKey = accountKey
        demo = accountKey == "demo"
        store = AppStoreModel(accountKey: accountKey)
        if demo {
            channelTabs = DemoFrameApps.channelTabs
            webLinks = DemoFrameApps.webLinks
            let installed = DemoAppStore.apps.filter { DemoAppStore.installedIDs.contains($0.id) }
            personalApps = DemoTeamsJSApp.apps + installed.compactMap(DemoAppStore.hosted)
            catalogManifests = installed + DemoAppStore.apps.filter { $0.id == DemoTeamsJSApp.appID }
            scanned = true
            FrameAppDirectory.register(DemoFrameApps.seeded)
        } else {
            let cache = TeamsFrameLibrary.loadCache(defaults: .standard)
            channelTabs = Self.apps(from: cache)
            scanned = !cache.isEmpty
            webLinks = Self.loadLinks(accountKey).compactMap(Self.app(from:))
            if let cached = TeamsAppCatalogCache.load(account: accountKey) {
                personalApps = Self.apps(from: cached)
                catalogPinned = Self.pinnedIDs(cached)
                catalogManifests = cached.apps
            }
        }
        store.setInstalled(catalogManifests)
        FrameAppDirectory.register([FrameBuiltIns.teamsWeb] + channelTabs + webLinks + personalApps)
        store.onDemoInstall = { [weak self] m in self?.demoInstall(m) }
        store.onInstalled = { [weak self] in self?.refreshCatalog() }
        if !demo {
            refreshCatalog()
            store.refresh()
        }
    }

    /// The hosted library app for a catalog app id (`ta.<id>`, or a demo
    /// app registered under its own id).
    func hostedApp(forCatalogApp id: String) -> FrameApp? {
        app(Self.appID(forCatalogApp: id)) ?? personalApps.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Demo "Add to Teams": in memory only, never the network.
    private func demoInstall(_ m: TeamsAppManifest) {
        guard demo, !catalogManifests.contains(where: { $0.id == m.id }) else { return }
        catalogManifests.append(m)
        store.setInstalled(catalogManifests)
        if let a = DemoAppStore.hosted(m) {
            personalApps.append(a)
            FrameAppDirectory.register([a])
        }
    }

    var builtIns: [LibraryItem] {
        NativeAppID.allCases.map(LibraryItem.init(native:)) + [LibraryItem(FrameBuiltIns.teamsWeb)]
    }

    func app(_ id: FrameAppID) -> FrameApp? {
        if id == FrameBuiltIns.teamsWebID { return FrameBuiltIns.teamsWeb }
        if let a = channelTabs.first(where: { $0.id == id }) ?? webLinks.first(where: { $0.id == id })
            ?? personalApps.first(where: { $0.id == id }) {
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
        refreshCatalog()
        store.refresh()
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

    // MARK: Teams app catalog (APPHOST; read-only)

    /// Background fetch of installed/pinned apps + manifests. A failure
    /// keeps the cached rows (stable UI) and records a quiet error.
    func refreshCatalog() {
        guard !demo, !catalogLoading else { return }
        catalogLoading = true
        let profile = accountKey
        Task { @MainActor [weak self] in
            let result = await TeamsAppService.catalog(profile: profile)
            guard let self else { return }
            self.catalogLoading = false
            switch result {
            case .success(let r):
                let entry = TeamsAppCatalogCache.Entry(pinned: r.pinned, apps: r.apps)
                TeamsAppCatalogCache.save(entry, account: self.accountKey)
                let apps = Self.apps(from: entry)
                if apps != self.personalApps { self.personalApps = apps }
                self.catalogPinned = Self.pinnedIDs(entry)
                self.catalogError = nil
                self.catalogManifests = r.apps
                self.store.setInstalled(r.apps)
                FrameAppDirectory.register(apps)
                self.onCatalogPinned?(self.catalogPinned)
            case .failure(let e):
                if case CoreCallError.failed(let m) = e {
                    self.catalogError = String(m.split(separator: "\n").first ?? "")
                } else {
                    self.catalogError = e.localizedDescription
                }
            }
        }
    }

    static func appID(forCatalogApp id: String) -> FrameAppID { "ta." + id.lowercased() }

    /// Hostable catalog apps (a personal static tab with a content page),
    /// app bar order first, then by name.
    static func apps(from entry: TeamsAppCatalogCache.Entry) -> [FrameApp] {
        let order = entry.pinned.map { $0.lowercased() }
        return entry.apps.compactMap { m -> FrameApp? in
            guard let l = TeamsAppLaunch(manifest: m) else { return nil }
            return FrameApp(id: appID(forCatalogApp: m.id), label: m.name, symbol: "square.grid.2x2",
                            source: .personal, launch: .teamsApp(l))
        }
        .sorted { a, b in
            let ia = order.firstIndex(of: String(a.id.dropFirst(3))) ?? Int.max
            let ib = order.firstIndex(of: String(b.id.dropFirst(3))) ?? Int.max
            return ia != ib ? ia < ib : a.label.localizedStandardCompare(b.label) == .orderedAscending
        }
    }

    /// Pinned catalog apps that are hostable, as library ids.
    static func pinnedIDs(_ entry: TeamsAppCatalogCache.Entry) -> [FrameAppID] {
        let hostable = Set(apps(from: entry).map(\.id))
        return entry.pinned.map { appID(forCatalogApp: $0) }.filter(hostable.contains)
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
