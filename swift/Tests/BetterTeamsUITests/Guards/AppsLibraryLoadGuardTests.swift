// AppsLibraryLoadGuardTests.swift — APPLIB-LOAD pins: the Apps library
// list can never render empty. Built-in rows are unconditional (five
// native apps, always present); persisted rail pins in the stored
// `{"web":{"_0":"ta…"}}` shape must decode (a decode break wipes the
// owner's pins on launch); hostable catalog manifests must resolve to
// `ta.<id>` library ids (else Pinned/Personal vanish with no error).
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class AppsLibraryLoadGuardTests: XCTestCase {
    /// The never-blank invariant: Built-in is five rows for every
    /// library state, and an empty filter never hides them.
    func testBuiltInsAlwaysPresent() {
        let lib = AppsLibrary(accountKey: "demo")
        XCTAssertEqual(lib.builtIns.count, NativeAppID.allCases.count)
        XCTAssertEqual(lib.builtIns.count, 5)
        for item in lib.builtIns {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertTrue(item.matches(""))
            XCTAssertNotNil(NativeAppID(rawValue: item.id))
            XCTAssertEqual(lib.item(item.id)?.title, item.title)
        }
    }

    /// The persisted rail-pin shape must decode: `{"web":{"_0":"ta…"}}`.
    /// A decode break drops every pin (compactMap) and `save()` then
    /// persists the wiped list — the owner's pins vanish silently.
    func testPersistedRailPinShapeDecodes() throws {
        let json = """
        [{"web":{"_0":"ta.5af6a76b-40fc-4ba1-af29-8f49b08e44fd"}},\
        {"web":{"_0":"ta.b5ab2ae-c16b-4310-8f8a-d3bcdb52f162"}},\
        {"web":{"_0":"ta.42f6c1da-a241-483a-a3cc-4f5be9185951"}},\
        {"web":{"_0":"ta.db5e5970-212f-477f-a3fc-2227dc7782bf"}}]
        """
        let pins = try JSONDecoder().decode([RailEntry].self, from: Data(json.utf8))
        XCTAssertEqual(pins.count, 4)
        XCTAssertEqual(pins, [
            .web("ta.5af6a76b-40fc-4ba1-af29-8f49b08e44fd"),
            .web("ta.b5ab2ae-c16b-4310-8f8a-d3bcdb52f162"),
            .web("ta.42f6c1da-a241-483a-a3cc-4f5be9185951"),
            .web("ta.db5e5970-212f-477f-a3fc-2227dc7782bf"),
        ])
        // Round-trip: what we save must load back identically.
        let saved = try JSONEncoder().encode(pins)
        XCTAssertEqual(try JSONDecoder().decode([RailEntry].self, from: saved), pins)
    }

    private func hostableManifest(id: String) -> TeamsAppManifest {
        TeamsAppManifest(id: id, name: "Shifts", staticTabs: [
            TeamsAppStaticTab(entityId: "shifts", name: "Shifts",
                              contentUrl: "https://example.invalid/shifts",
                              scopes: ["personal"]),
        ])
    }

    /// Hostable catalog apps resolve to `ta.<lowercased-id>` library
    /// rows in app-bar order; unhostable ones drop (no quiet dangling).
    func testHostableManifestsResolveToLibraryIDs() {
        let hostable = hostableManifest(id: "42F6C1DA-A241-483A-A3CC-4F5BE9185951")
        let websiteOnly = TeamsAppManifest(
            id: "website-only", name: "Site", staticTabs: [
                TeamsAppStaticTab(entityId: "site", name: "Site",
                                  contentUrl: nil, websiteUrl: "https://example.invalid",
                                  scopes: ["personal"]),
            ])
        let nativeEntity = TeamsAppManifest(
            id: "about-tab", name: "About", staticTabs: [
                TeamsAppStaticTab(entityId: "about", name: "About",
                                  contentUrl: "https://example.invalid/about",
                                  scopes: ["personal"]),
            ])
        XCTAssertNotNil(TeamsAppLaunch(manifest: hostable))
        XCTAssertNil(TeamsAppLaunch(manifest: websiteOnly))
        XCTAssertNil(TeamsAppLaunch(manifest: nativeEntity))

        let entry = TeamsAppCatalogCache.Entry(
            pinned: [hostable.id, websiteOnly.id], apps: [hostable, websiteOnly, nativeEntity])
        let apps = AppsLibrary.apps(from: entry)
        XCTAssertEqual(apps.map(\.id), ["ta.42f6c1da-a241-483a-a3cc-4f5be9185951"])
        // Pinned ids map to library ids only for hostable apps.
        XCTAssertEqual(AppsLibrary.pinnedIDs(entry),
                       ["ta.42f6c1da-a241-483a-a3cc-4f5be9185951"])
    }

    /// An empty catalog entry wipes Personal but never Built-in: the
    /// list always has rows.
    func testEmptyCatalogKeepsBuiltIns() {
        let lib = AppsLibrary(accountKey: "demo")
        let empty = TeamsAppCatalogCache.Entry(pinned: [], apps: [])
        XCTAssertEqual(AppsLibrary.apps(from: empty), [])
        XCTAssertEqual(AppsLibrary.pinnedIDs(empty), [])
        XCTAssertEqual(lib.builtIns.count, 5)
    }

    /// The catalog cache round-trips (pins + manifests): what feeds
    /// the library at launch survives a save/load.
    func testCatalogCacheRoundTrip() throws {
        let entry = TeamsAppCatalogCache.Entry(
            pinned: ["42f6c1da-a241-483a-a3cc-4f5be9185951"],
            apps: [hostableManifest(id: "42f6c1da-a241-483a-a3cc-4f5be9185951")])
        let data = try JSONEncoder().encode(entry)
        let loaded = try JSONDecoder().decode(TeamsAppCatalogCache.Entry.self, from: data)
        XCTAssertEqual(loaded, entry)
        XCTAssertEqual(AppsLibrary.apps(from: loaded).map(\.id),
                       ["ta.42f6c1da-a241-483a-a3cc-4f5be9185951"])
    }
}
