// P3cFilesTests.swift — P3c pins (UI-SPEC §6.6): the fixed source
// order, empty/loading/error inside the table area, the Location link's
// route, and the transfers popover route.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P3cFilesTests: XCTestCase {
    /// §6.6: Recent · My Files · Shared in Chats · Teams (team ›
    /// channel) · Downloads; keys round-trip (route `files/<source>`).
    func testSourcesFixedOrder() {
        let keys = FilesSource.listOrder(teams: DemoData.teams).map(\.key)
        XCTAssertEqual(Array(keys.prefix(3)), ["recent", "onedrive", "shared"])
        XCTAssertEqual(keys.last, "downloads")
        let channels = DemoData.teams.flatMap(\.channels).map { "channel:" + $0.channelId }
        XCTAssertEqual(Array(keys.dropFirst(3).dropLast()), channels)
        XCTAssertEqual(FilesSource.listOrder(teams: []).map(\.key), ["recent", "onedrive", "shared", "downloads"])
        for k in keys { XCTAssertEqual(FilesSource(key: k)?.key, k) }
    }

    /// §6 + R12: an empty source is the table's empty state ("No Files"
    /// + Upload…, drawn inside the table area), not a pane swap; rows on
    /// screen win over loading and error; offline wording.
    func testEmptyStateInsideTable() {
        XCTAssertEqual(FilesPaneState.resolve(.loaded, count: 0, forced: nil, forcedOffline: false, offline: false),
                       .empty)
        XCTAssertEqual(FilesPaneState.resolve(.empty, count: 0, forced: nil, forcedOffline: false, offline: false),
                       .empty)
        XCTAssertEqual(FilesPaneState.resolve(.loading, count: 2, forced: nil, forcedOffline: false, offline: false),
                       .files)
        XCTAssertEqual(FilesPaneState.resolve(.error("x"), count: 0, forced: nil, forcedOffline: false, offline: true),
                       .error(message: FilesPaneState.offlineMessage))
        XCTAssertEqual(FilesPaneState.resolve(.loaded, count: 3, forced: nil, forcedOffline: true, offline: false),
                       .error(message: FilesPaneState.offlineMessage))
        XCTAssertEqual(FilesPaneState.resolve(.loaded, count: 3, forced: .empty, forcedOffline: false, offline: false),
                       .empty)
        XCTAssertTrue(FilesSource.recent.acceptsUpload)
        XCTAssertFalse(FilesSource.downloads.acceptsUpload)
    }

    /// Location = the source conversation (core-b `source_id`): a
    /// channel opens in Teams under its team, a chat opens in Chat.
    func testSourceLinkRoutes() {
        let rows = DemoData.unifiedDemoRows().map(FileItem.remote)
        let chan = rows.first { $0.id == "demo-u-chan1" }
        XCTAssertEqual(chan?.locationID, "demo-chan-general")
        XCTAssertEqual(chan?.location, "Engineering > #General")
        XCTAssertNil(rows.first { $0.id == "demo-u-drive1" }?.locationID)

        let (s1, sel1) = FilesSection.sourceTarget("demo-chan-general", teams: DemoData.teams)
        XCTAssertEqual(s1, .teams)
        XCTAssertEqual(sel1, TeamsSelection(teamID: "demo-team-eng", channelID: "demo-chan-general").selection)
        let (s2, sel2) = FilesSection.sourceTarget(DemoData.demoID, teams: DemoData.teams)
        XCTAssertEqual(s2, .chat)
        XCTAssertEqual(sel2, SectionSelection(id: DemoData.demoID))
    }

    /// `files?popover=transfers` is a Files route that requests the
    /// Transfers popover (presented once the table is on screen);
    /// `files?select=<id>` selects in Recent; aliases resolve.
    func testTransfersRouteRequestsPopover() {
        let files = FilesSection()
        XCTAssertNil(files.selection(for: Route(string: "files?popover=transfers")!))
        XCTAssertEqual(Route(string: "files?popover=transfers")?.section, .files)
        XCTAssertEqual(files.evidence.popover, FilesCommands.transfersPopover)
        XCTAssertEqual(files.selection(for: Route(string: "files?select=demo-u-chat1")!)?.path,
                       ["recent", "demo-u-chat1"])
        XCTAssertNil(files.evidence.popover)
        XCTAssertEqual(files.selection(for: Route(string: "files/recent/demo-file")!)?.path,
                       ["recent", FilesSection.demoFileID])
        XCTAssertTrue(files.selection(for: Route(string: "files?state=offline")!) == nil && files.evidence.offline)
        XCTAssertTrue(CommandCatalog.command(FilesCommands.transfers)?.toolbar == .trailing)
    }
}
