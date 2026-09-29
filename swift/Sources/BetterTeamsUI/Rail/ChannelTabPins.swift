// ChannelTabPins.swift — rail pins saved from the retired Apps-list
// "Channel Tabs" section (ids "ct.<team>.<channel>.<tab>"). The Apps list
// shows apps only; a channel's tabs live in that channel's tab bar. Every
// pin with a cached tab keeps its rail item and opens that channel + tab
// natively (a Teams link through the deep-link router, any other tab by
// team + channel name); a pin with no cached tab is dropped.
import Foundation
import OstMacCore

@MainActor
enum ChannelTabPins {
    /// Migrated pins by rail id (filled on rail load).
    private(set) static var loaded: [FrameAppID: Pin] = [:]

    /// The retired teams-cli `tabs-all` cache: read once per account,
    /// never written.
    static let legacyCacheKey = "teamsFrameLibraryCache"

    static func key(_ account: String) -> String { "bt.rail.channelTabPins.\(account)" }

    /// A migrated pin: where it goes and what the rail calls it.
    struct Pin: Codable, Equatable {
        var id: FrameAppID
        var team: String
        var channel: String
        var tabID: String
        var label: String
        var url: String
    }

    /// One row of the retired cache (`id` = "<team>|<channel>|<tab id>").
    struct LegacyEntry: Codable, Equatable {
        var id: String
        var team: String
        var channel: String
        var label: String
        var url: String
    }

    /// The rail id the retired library gave a cached tab.
    static func pinID(_ entryID: String) -> FrameAppID {
        "ct." + entryID.replacingOccurrences(of: "|", with: ".").replacingOccurrences(of: " ", with: "-")
    }

    static func isChannelTab(_ e: RailEntry) -> Bool {
        if case .web(let id) = e { return id.hasPrefix("ct.") }
        return false
    }

    /// The "ct." pins that name a cached tab.
    static func migrate(_ pins: [RailEntry], cache: [LegacyEntry]) -> [Pin] {
        let byID = Dictionary(cache.map { (pinID($0.id), $0) }, uniquingKeysWith: { a, _ in a })
        return pins.compactMap { e -> Pin? in
            guard isChannelTab(e), case .web(let id) = e, let c = byID[id] else { return nil }
            return Pin(id: id, team: c.team, channel: c.channel,
                       tabID: String(c.id.split(separator: "|").last ?? ""), label: c.label, url: c.url)
        }
    }

    /// The rail's app for a migrated pin (never listed in the Apps list).
    /// A Teams link keeps `.teamsLink`; any other address is only a
    /// label: Navigator opens the channel tab natively, never a pane.
    static func app(_ p: Pin) -> FrameApp {
        let launch: FrameLaunch = switch FramePolicy.launch(url: p.url) {
        case .teamsLink(let u)?: .teamsLink(u)
        default: .external(URL(string: p.url) ?? URL(string: "about:blank")!)
        }
        return FrameApp(id: p.id, label: p.label, symbol: "rectangle.split.3x1",
                        source: .channelTab(team: p.team, channel: p.channel), launch: launch)
    }

    /// The channel + tab a pin names, by team and channel name.
    static func selection(_ p: Pin, teams: [TeamItem]) -> TeamsSelection? {
        let same = { (a: String, b: String) in a.caseInsensitiveCompare(b) == .orderedSame }
        guard let t = teams.first(where: { same($0.name, p.team) }),
              let c = t.channels.first(where: { same($0.name, p.channel) }) else { return nil }
        return TeamsSelection(teamID: t.teamId, channelID: c.channelId, tab: .web(p.tabID))
    }

    /// Rail click on a migrated pin. False: not a migrated pin.
    static func open(_ id: FrameAppID, _ m: WindowModel) -> Bool {
        guard let p = loaded[id] else { return false }
        if case .teamsLink(let url) = app(p).launch, m.frameHost.openTeamsLink(url) {
            return true
        }
        // Channel not found (renamed, left): the Teams section only.
        m.navigator?.select(section: .teams)
        if let sel = selection(p, teams: m.app?.teams.teams ?? []) {
            m.navigator?.select(sel.selection, in: .teams)
        }
        return true
    }

    /// Rail load: registers the kept "ct." pins with the directory and
    /// returns the pin list without the unresolvable ones. The first load
    /// per account reads the retired cache and records the result.
    static func apply(_ pins: [RailEntry], account: String, defaults: UserDefaults) -> [RailEntry] {
        guard pins.contains(where: isChannelTab) else { return pins }
        let saved: [Pin]
        if let data = defaults.data(forKey: key(account)),
           let list = try? JSONDecoder().decode([Pin].self, from: data) {
            saved = list
        } else {
            let cache = defaults.data(forKey: legacyCacheKey)
                .flatMap { try? JSONDecoder().decode([LegacyEntry].self, from: $0) } ?? []
            saved = migrate(pins, cache: cache)
            if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key(account)) }
        }
        for p in saved { loaded[p.id] = p }
        FrameAppDirectory.register(saved.map(app))
        let kept = Set(saved.map(\.id))
        return pins.filter { e in
            guard isChannelTab(e), case .web(let id) = e else { return true }
            return kept.contains(id)
        }
    }
}
