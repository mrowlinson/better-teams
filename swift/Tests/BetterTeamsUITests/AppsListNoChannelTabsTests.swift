// AppsListNoChannelTabsTests.swift — the Apps list shows apps only
// (built-ins, personal catalog apps, web links); channel tabs live in
// each channel's tab bar. Rail pins saved from the retired Channel Tabs
// section keep working when they name a Teams link, else are dropped.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppsListNoChannelTabsTests: XCTestCase {
    private func isChannelTab(_ a: FrameApp) -> Bool {
        if case .channelTab = a.source { return true }
        return a.id.hasPrefix("ct.")
    }

    func testDemoLibraryListsNoChannelTabs() {
        let lib = AppsLibrary(accountKey: "demo")
        let apps = lib.personalApps + lib.webLinks
        XCTAssertFalse(apps.isEmpty)
        XCTAssertEqual(apps.filter(isChannelTab), [])
        XCTAssertTrue(DemoFrameApps.webLinks.allSatisfy { $0.source == .webLink })
        // Every row the pane can show resolves to a non-channel-tab item.
        let rows = lib.builtIns + apps.map(LibraryItem.init)
        XCTAssertFalse(rows.contains { $0.id.hasPrefix("ct.") })
        XCTAssertFalse(rows.contains { $0.sourceLine.contains("›") })
    }

    /// Catalog apps (the non-demo list's only source besides web links)
    /// map to personal apps, never channel tabs.
    func testCatalogAppsAreNeverChannelTabs() {
        let cached = AppsLibrary.apps(from: TeamsAppCatalogCache.Entry(pinned: [], apps: []))
        XCTAssertEqual(cached.filter(isChannelTab), [])
    }

    private let cache = [
        ChannelTabPins.LegacyEntry(id: "Falcon IT|General|6ece32a4", team: "Falcon IT", channel: "General",
                                   label: "Order Tracker",
                                   url: "https://teams.microsoft.com/l/entity/1c256a65/x?label=Order+Tracker"),
        ChannelTabPins.LegacyEntry(id: "Falcon IT|General|19038e38", team: "Falcon IT", channel: "General",
                                   label: "Notes", url: "https://onenote.example.com/"),
    ]

    func testMigrationKeepsEveryCachedPinAndDropsUncached() {
        let link = RailEntry.web("ct.Falcon-IT.General.6ece32a4")
        let notes = RailEntry.web("ct.Falcon-IT.General.19038e38")
        let uncached = RailEntry.web("ct.Gone.General.deadbeef")
        let pins: [RailEntry] = [.native(.todo), link, notes, uncached, .web("web-demo")]

        let migrated = ChannelTabPins.migrate(pins, cache: cache)
        XCTAssertEqual(migrated.map(\.id), ["ct.Falcon-IT.General.6ece32a4", "ct.Falcon-IT.General.19038e38"])
        XCTAssertEqual(migrated.map(\.tabID), ["6ece32a4", "19038e38"])
        // A Teams link keeps its link; any other tab is a channel tab app.
        guard case .teamsLink(let url) = ChannelTabPins.app(migrated[0]).launch else { return XCTFail("not a Teams link") }
        XCTAssertEqual(url.host, "teams.microsoft.com")
        XCTAssertEqual(ChannelTabPins.app(migrated[1]).source, .channelTab(team: "Falcon IT", channel: "General"))

        // Click resolution by team + channel name; unknown channel → nil.
        let teams = [TeamItem(teamId: "t1", name: "falcon it",
                              channels: [TeamChannel(channelId: "19:c1@thread.tacv2", name: "General")])]
        XCTAssertEqual(ChannelTabPins.selection(migrated[1], teams: teams),
                       TeamsSelection(teamID: "t1", channelID: "19:c1@thread.tacv2", tab: .web("19038e38")))
        XCTAssertNil(ChannelTabPins.selection(migrated[1], teams: []))

        let suite = "apps-no-ct-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set(try? JSONEncoder().encode(cache), forKey: ChannelTabPins.legacyCacheKey)
        let out = ChannelTabPins.apply(pins, account: "acct", defaults: d)
        XCTAssertEqual(out, [.native(.todo), link, notes, .web("web-demo")])
        XCTAssertEqual(FrameAppDirectory.app("ct.Falcon-IT.General.19038e38")?.label, "Notes")
        // Read once: the recorded map answers later loads, cache gone or not.
        d.removeObject(forKey: ChannelTabPins.legacyCacheKey)
        XCTAssertEqual(ChannelTabPins.apply(pins, account: "acct", defaults: d), out)
        for p in migrated { FrameAppDirectory.remove(p.id) }
    }
}
