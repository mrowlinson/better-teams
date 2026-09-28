// AppStore.swift — the native Apps store (APPHOST-B2): browse and
// search the Teams app catalog, app detail, personal install. Data is
// the apps-platform middle tier (store home + search, read-only) plus
// the installed catalog; install is a REMOTE WRITE behind a confirm.
// Demo: a deterministic local catalog, no network, no user defaults.
import AppKit
import Foundation
import Observation
import OstMacCore

/// Store selections inside the Apps section: `[<appID>, "store"]` is an
/// app's detail page, `["cat:<name>", "store"]` a category (routes
/// `apps/detail?id=<appID>`, `apps/store?category=<name>`).
enum AppStoreRoute {
    static let group = "store"
    static let categoryPrefix = "cat:"
    static let all = "All Apps"

    static func detail(_ appID: String) -> SectionSelection { SectionSelection([appID, group]) }
    static func category(_ name: String) -> SectionSelection { SectionSelection([categoryPrefix + name, group]) }

    /// The store page a selection shows: nil = not a store page.
    enum Page: Equatable { case home(category: String?), detail(String) }

    static func page(_ sel: SectionSelection?) -> Page? {
        guard let sel else { return .home(category: nil) }
        guard sel.path.count > 1, sel.path[1] == group, let id = sel.id else { return nil }
        if id.hasPrefix(categoryPrefix) {
            let c = String(id.dropFirst(categoryPrefix.count))
            return .home(category: c == all ? nil : c)
        }
        return .detail(id)
    }
}

@Observable
@MainActor
final class AppStoreModel {
    private(set) var sections: [TeamsAppStoreSection] = []
    private(set) var apps: [TeamsAppManifest] = []
    /// Installed catalog apps (lowercased ids), from the library.
    private(set) var installed: Set<String> = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var searchResults: [TeamsAppManifest]?
    private(set) var searching = false
    private(set) var installing: Set<String> = []
    private(set) var installError: String?
    @ObservationIgnored let demo: Bool
    @ObservationIgnored private let accountKey: String
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let searchDelay = Debounce(milliseconds: 300)
    /// Installed catalog manifests (set by the library).
    @ObservationIgnored private var catalog: [TeamsAppManifest] = []
    /// Demo installs land here (in memory only).
    @ObservationIgnored var onDemoInstall: ((TeamsAppManifest) -> Void)?
    @ObservationIgnored var onInstalled: (() -> Void)?

    init(accountKey: String) {
        self.accountKey = accountKey
        demo = accountKey == "demo"
        if demo {
            sections = DemoAppStore.sections
            apps = DemoAppStore.apps
        } else if let cached = TeamsAppStoreCache.load(account: accountKey) {
            sections = cached.sections
            apps = cached.apps
        }
    }

    /// Installed catalog changed (library): ids + manifests.
    func setInstalled(_ manifests: [TeamsAppManifest]) {
        catalog = manifests
        let ids = Set(manifests.map { $0.id.lowercased() })
        if ids != installed { installed = ids }
    }

    func isInstalled(_ id: String) -> Bool { installed.contains(id.lowercased()) }

    /// Store listing, else the installed definition (richer), by id.
    func manifest(_ id: String) -> TeamsAppManifest? {
        let installedDef = (catalog + teamApps).first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        let listed = (searchResults ?? []).first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
            ?? apps.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
        return installedDef ?? listed
    }

    /// Every app the window knows about (store + installed), for tab matching.
    var allManifests: [TeamsAppManifest] {
        var seen = Set<String>()
        return (catalog + apps + teamApps).filter { seen.insert($0.id.lowercased()).inserted }
    }

    /// Apps installed in a team but not for the user (APPHOST-B3): their
    /// channel tabs need the manifest to be matched.
    private(set) var teamApps: [TeamsAppManifest] = []
    @ObservationIgnored private var teamAppsAsked: Set<String> = []

    /// Loads (once per team) the manifests of the team's installed apps
    /// and of `tabAppIDs` the catalog doesn't know. Read-only; idempotent.
    func ensureTeamApps(teamID: String, tabAppIDs: [String]) {
        guard !demo else { return }
        let known = Set(allManifests.map { $0.id.lowercased() })
        let missing = tabAppIDs.filter { !known.contains($0.lowercased()) }
        let key = teamID.lowercased()
        guard !teamAppsAsked.contains(key), !missing.isEmpty else { return }
        teamAppsAsked.insert(key)
        let profile = accountKey
        Task { @MainActor [weak self] in
            let result = await TeamsAppService.teamApps(profile: profile, teamID: teamID, ids: missing)
            guard let self, case .success(let found) = result else { return }
            let have = Set(self.allManifests.map { $0.id.lowercased() })
            let add = found.filter { !have.contains($0.id.lowercased()) }
            if !add.isEmpty { self.teamApps += add }
        }
    }

    /// Categories present in the listing, sorted.
    var categories: [String] {
        Array(Set(allManifests.flatMap { $0.categories ?? [] })).sorted()
    }

    /// Home shelves: "Installed" first, then the store's own shelves
    /// (or one "Popular" shelf of the whole listing when it has none).
    var shelves: [(title: String, apps: [TeamsAppManifest])] {
        var out: [(String, [TeamsAppManifest])] = []
        let mine = allManifests.filter { isInstalled($0.id) }
        if !mine.isEmpty { out.append(("Installed", mine)) }
        if sections.isEmpty {
            if !apps.isEmpty { out.append(("Popular Apps", apps)) }
        } else {
            for s in sections {
                let list = s.appIds.compactMap(manifest)
                if !list.isEmpty { out.append((s.title, list)) }
            }
        }
        return out
    }

    func apps(inCategory c: String) -> [TeamsAppManifest] {
        allManifests.filter { ($0.categories ?? []).contains(c) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: refresh (background, diffed; failures keep the cached rows)

    /// `GET beta/users/apps/store` and `/search` answer 405 live
    /// (APPLIVE 2026-09-28; method/body unknown): the store lists the
    /// organization's catalog locally and search filters it locally.
    static let serverStore = false

    func refresh() {
        guard !demo, !loading, Self.serverStore else { return }
        loading = true
        let profile = accountKey
        Task { @MainActor [weak self] in
            let result = await TeamsAppService.store(profile: profile)
            guard let self else { return }
            self.loading = false
            switch result {
            case .success(let r):
                let entry = TeamsAppStoreCache.Entry(sections: r.sections, apps: r.apps)
                TeamsAppStoreCache.save(entry, account: self.accountKey)
                if r.sections != self.sections { self.sections = r.sections }
                if r.apps != self.apps { self.apps = r.apps }
                self.error = nil
            case .failure(let e):
                self.error = Self.message(e)
            }
        }
    }

    // MARK: search (demo: local match; live: store search, debounced)

    func search(_ raw: String) {
        searchTask?.cancel()
        searchDelay.cancel()
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = nil
            searching = false
            return
        }
        let local = allManifests.filter { Self.matches($0, q) }
        if demo || !Self.serverStore {
            searchResults = local
            return
        }
        // Local hits at once; the server's answer replaces them when it lands.
        searchResults = local
        searching = true
        let profile = accountKey
        searchDelay.schedule { [weak self] in
            self?.searchTask = Task { @MainActor [weak self] in
                let result = await TeamsAppService.search(profile: profile, query: q)
                guard !Task.isCancelled, let self else { return }
                self.searching = false
                if case .success(let found) = result {
                    var seen = Set(found.map { $0.id.lowercased() })
                    let merged = found + local.filter { seen.insert($0.id.lowercased()).inserted }
                    if merged != self.searchResults { self.searchResults = merged }
                }
            }
        }
    }

    static func matches(_ m: TeamsAppManifest, _ q: String) -> Bool {
        [m.name, m.developer ?? "", m.shortDescription ?? "", (m.categories ?? []).joined(separator: " ")]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }

    // MARK: install (REMOTE WRITE, confirmed by the caller)

    func install(_ m: TeamsAppManifest) {
        guard !installing.contains(m.id) else { return }
        installError = nil
        if demo {
            onDemoInstall?(m)
            return
        }
        installing.insert(m.id)
        let profile = accountKey
        Task { @MainActor [weak self] in
            let result = await TeamsAppService.install(profile: profile, appID: m.id)
            guard let self else { return }
            self.installing.remove(m.id)
            switch result {
            case .success: self.onInstalled?()
            case .failure(let e): self.installError = Self.message(e)
            }
        }
    }

    static func message(_ e: any Error) -> String {
        if case CoreCallError.failed(let m) = e { return String(m.split(separator: "\n").first ?? "") }
        return e.localizedDescription
    }
}

// MARK: - Channel tabs hosted natively

extension AppStoreModel {
    /// The catalog app behind a channel tab: its `teamsAppId`, else the
    /// app whose validDomains / configurable tab host serve the tab's
    /// content page. Nil = unmatched (the tab keeps its Teams-shell page).
    func app(forTab t: ChannelTab) -> TeamsAppManifest? {
        let all = allManifests
        if let id = t.appID, let m = all.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return m
        }
        guard let content = t.contentURL, let host = Self.templateHost(content),
              !FramePolicy.hostMatches(host, FramePolicy.standaloneHosts),
              !FramePolicy.hostMatches(host, TeamsDeepLink.hosts) else { return nil }
        return all.first { m in
            m.validDomains.contains { Self.domain($0, matches: host) }
                || m.configurableTabs.contains { Self.templateHost($0.configurationUrl) == host }
        }
    }

    /// Host of a URL template (placeholders make `URL(string:)` unsafe).
    static func templateHost(_ s: String) -> String? {
        guard let r = s.range(of: "://") else { return nil }
        let rest = s[r.upperBound...]
        let end = rest.firstIndex { "/?#:{".contains($0) } ?? rest.endIndex
        let h = rest[..<end].lowercased()
        return h.isEmpty ? nil : h
    }

    /// Manifest validDomains entry (`host`, `*.host`, `host/path`) vs a host.
    static func domain(_ pattern: String, matches host: String) -> Bool {
        var p = pattern.lowercased()
        if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
        p = String(p.prefix { $0 != "/" && $0 != ":" })
        if p.hasPrefix("*.") { return FramePolicy.hostMatches(host, [String(p.dropFirst(2))]) }
        return host == p
    }

    /// Native launch for a matched channel tab, with channel context.
    func launch(forTab t: ChannelTab, team: TeamItem, channel: TeamChannel) -> TeamsAppLaunch? {
        guard let m = app(forTab: t), let content = t.contentURL else { return nil }
        let original = t.target
        guard case .web(let url) = original else { return nil }
        var domains = m.validDomains
        if let h = Self.templateHost(content), !domains.contains(where: { Self.domain($0, matches: h) }) {
            domains.append(h)
        }
        let fallback = FramePolicy.launch(url: url.absoluteString, label: t.name)?.url ?? url
        return TeamsAppLaunch(
            appID: m.id, entityID: t.entityID ?? t.id, contentTemplate: content, fallback: fallback,
            resource: m.webApplicationInfo?.resource, webAppID: m.webApplicationInfo?.id, validDomains: domains,
            demoHTML: demo ? DemoTeamsJSApp.html(title: t.name) : nil,
            channel: TeamsAppChannelContext(teamID: team.teamId, channelID: channel.id,
                                            groupID: UUID(uuidString: team.teamId) != nil ? team.teamId : nil,
                                            teamName: team.name, channelName: channel.name))
    }
}

// MARK: - Host mode (Teams web page vs native), per app

/// How an app is hosted. Automatic keeps every app on its Teams web page
/// (the Teams-shell app frame) unless it is on the verified native list
/// (`TeamsJSNativeAllowlist`); a verified app runs natively, starts
/// frameless, and gets one try in the iframe transport if it never
/// initializes. A native page that fails (sign-in page, AADSTS error,
/// app-reported failure, blank page) switches to the Teams web page and
/// Automatic remembers that. Direct / In a Frame force the native host.
enum TeamsJSHostMode: String, CaseIterable, Identifiable {
    case automatic, frameless, iframe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .frameless: "Direct"
        case .iframe: "In a Frame"
        }
    }
}

/// Apps proven to work end to end in the native host (APPLIVE live
/// read-only check, 2026-09-28): getAuthToken + nested-app-auth 1P apps.
/// Everything else stays on its Teams web page in Automatic mode.
enum TeamsJSNativeAllowlist {
    /// Catalog app ids, lowercased.
    static let verified: Set<String> = [
        "7c316234-ded0-4f95-8a83-8453d0876592", // Approvals
    ]

    /// Demo apps are local sample pages (no network): always native.
    static func contains(_ l: TeamsAppLaunch) -> Bool {
        l.demoHTML != nil || verified.contains(l.appID.lowercased())
    }
}

@MainActor
enum TeamsJSTransportChoice {
    /// Demo: in memory only (evidence runs never write defaults).
    private static var memory: [String: String] = [:]

    private static func modeKey(_ app: String) -> String { "bt.apphost.mode.\(app.lowercased())" }
    private static func learnedKey(_ app: String) -> String { "bt.apphost.learned.\(app.lowercased())" }
    private static func failedKey(_ app: String) -> String { "bt.apphost.failed.\(app.lowercased())" }

    private static func get(_ key: String, demo: Bool) -> String? {
        demo ? memory[key] : UserDefaults.standard.string(forKey: key)
    }

    private static func set(_ v: String?, _ key: String, demo: Bool) {
        if demo { memory[key] = v } else { UserDefaults.standard.set(v, forKey: key) }
    }

    static func mode(_ app: String, demo: Bool) -> TeamsJSHostMode {
        get(modeKey(app), demo: demo).flatMap(TeamsJSHostMode.init(rawValue:)) ?? .automatic
    }

    /// A changed mode starts over: the learned transport and any
    /// remembered native failure are forgotten.
    static func setMode(_ m: TeamsJSHostMode, app: String, demo: Bool) {
        guard m != mode(app, demo: demo) else { return }
        set(m == .automatic ? nil : m.rawValue, modeKey(app), demo: demo)
        learn(nil, app: app, demo: demo)
        forgetFailure(app: app, demo: demo)
    }

    static func learned(_ app: String, demo: Bool) -> TeamsJSTransport? {
        switch get(learnedKey(app), demo: demo) {
        case "iframe": .iframe
        case "frameless": .frameless
        default: nil
        }
    }

    static func learn(_ t: TeamsJSTransport?, app: String, demo: Bool) {
        let v: String? = switch t {
        case .iframe: "iframe"
        case .frameless: "frameless"
        case nil: nil
        }
        set(v, learnedKey(app), demo: demo)
    }

    /// Why the native host failed this app (Automatic then keeps it on
    /// its Teams web page). A short reason, never page content.
    static func failure(_ app: String, demo: Bool) -> String? { get(failedKey(app), demo: demo) }

    static func rememberFailure(_ why: String, app: String, demo: Bool) {
        set(String(why.prefix(80)), failedKey(app), demo: demo)
    }

    static func forgetFailure(app: String, demo: Bool) { set(nil, failedKey(app), demo: demo) }

    /// The transport to host `l` with, nil = its Teams web page: the
    /// user's choice, else (Automatic) native only for a verified app
    /// with no remembered failure, on the remembered or default transport.
    static func resolve(_ l: TeamsAppLaunch, demo: Bool) -> TeamsJSTransport? {
        switch mode(l.appID, demo: demo) {
        case .frameless: .frameless
        case .iframe: .iframe
        case .automatic:
            TeamsJSNativeAllowlist.contains(l) && failure(l.appID, demo: demo) == nil
                ? learned(l.appID, demo: demo) ?? l.transport : nil
        }
    }
}
