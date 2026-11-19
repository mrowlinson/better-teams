// WhiteboardSharedTests.swift — WHITEBOARD-BUILD: the shared-board
// store behind a whiteboard tab (live-gated record + share +
// snapshot; local ink stays the offline fallback).
import Foundation
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class WhiteboardSharedTests: XCTestCase {
    private nonisolated func board(_ id: String = "b1") -> WhiteboardBoard {
        WhiteboardBoard(id: id, title: "Sprint", ownerID: "o1", isShared: true)
    }

    private nonisolated func responses() -> (
        WhiteboardBoardResponse, WhiteboardPermsResponse, WhiteboardContentResponse
    ) {
        (WhiteboardBoardResponse(ok: true, board: board()),
         WhiteboardPermsResponse(ok: true, perms: WhiteboardPerms(canEdit: true, canRead: true)),
         WhiteboardContentResponse(ok: true, ops: 12, hasNext: false))
    }

    func testDemoSeedsBothUIStates() async {
        let store = WhiteboardSharedStore()
        await store.load(boardID: "demo-tab-wb", demo: true)
        guard case .loaded(let shared) = store.load else {
            return XCTFail("group demo should seed a loaded board")
        }
        XCTAssertEqual(shared.board.title, "Sprint board")
        XCTAssertTrue(shared.board.isShared)
        XCTAssertEqual(shared.ops, 12)
        XCTAssertNotNil(shared.share?.shareURI)

        await store.load(boardID: "demo-tab-wb3", demo: true)
        guard case .unavailable(let reason) = store.load else {
            return XCTFail("meeting demo should seed the gated state")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testLiveLoadDegradesPermsAndSnapshot() async {
        let (boardResp, _, contentResp) = responses()
        let store = WhiteboardSharedStore(
            show: { _ in boardResp },
            perms: { _ in throw CoreCallError.failed("perms down") },
            content: { _, _ in contentResp })
        await store.load(boardID: "b1", demo: false)
        guard case .loaded(let shared) = store.load else {
            return XCTFail("board read gates, not perms")
        }
        XCTAssertNil(shared.perms)
        XCTAssertEqual(shared.ops, 12)
        XCTAssertNil(shared.snapshotError)
    }

    func testLiveLoadFailureGatesWithReason() async {
        let store = WhiteboardSharedStore(
            show: { _ in throw CoreCallError.failed("WB 401 Unauthorized") })
        await store.load(boardID: "b1", demo: false)
        guard case .unavailable(let reason) = store.load else {
            return XCTFail("board failure must gate the pane")
        }
        XCTAssertEqual(reason, "WB 401 Unauthorized")
    }

    func testShareKeepsBoardOnFailure() async {
        let (boardResp, permsResp, contentResp) = responses()
        final class Box: @unchecked Sendable { var fail = false }
        let box = Box()
        let store = WhiteboardSharedStore(
            show: { _ in boardResp },
            share: { _ in
                if box.fail { throw CoreCallError.failed("share down") }
                return WhiteboardShareResponse(
                    ok: true, share: WhiteboardShareLink(shareURI: "https://example.com/s"))
            },
            perms: { _ in permsResp },
            content: { _, _ in contentResp })
        await store.load(boardID: "b1", demo: false)
        await store.share(boardID: "b1", demo: false)
        guard case .loaded(let shared) = store.load else { return XCTFail("lost board") }
        XCTAssertEqual(shared.share?.shareURI, "https://example.com/s")
        box.fail = true
        await store.share(boardID: "b1", demo: false)
        guard case .loaded(let failed) = store.load else { return XCTFail("lost board") }
        XCTAssertEqual(failed.share?.shareURI, "https://example.com/s")
        XCTAssertEqual(failed.shareError, "share down")
    }

    func testLoadMoreAccumulatesOps() async {
        let (boardResp, permsResp, _) = responses()
        let store = WhiteboardSharedStore(
            show: { _ in boardResp },
            perms: { _ in permsResp },
            content: { _, cursor in
                cursor == nil
                    ? WhiteboardContentResponse(ok: true, ops: 12, hasNext: true, nextCursor: "C")
                    : WhiteboardContentResponse(ok: true, ops: 3, hasNext: false)
            })
        await store.load(boardID: "b1", demo: false)
        await store.loadMore(boardID: "b1", demo: false)
        guard case .loaded(let shared) = store.load else { return XCTFail("lost board") }
        XCTAssertEqual(shared.ops, 15)
        XCTAssertFalse(shared.hasMoreOps)
    }

    func testCreateReplacesState() async {
        let store = WhiteboardSharedStore(
            create: { _ in WhiteboardBoardResponse(ok: true, board: self.board("b9")) })
        await store.create(title: "Fresh", demo: false)
        guard case .loaded(let shared) = store.load else { return XCTFail("no board") }
        XCTAssertEqual(shared.board.id, "b9")
        await store.create(title: nil, demo: true)
        guard case .loaded(let demo) = store.load else { return XCTFail("no demo board") }
        XCTAssertEqual(demo.board.title, "Untitled board")
    }

    func testResponseDecodes() throws {
        let board = try JSONDecoder().decode(
            WhiteboardBoardResponse.self,
            from: Data(
                """
                {"ok":true,"board":{"id":"b1","title":"Sprint","owner_id":"o1",\
                "owner_tenant_id":"t1","is_shared":true,"fluid_file_id":"f1","meeting_id":null}}
                """.utf8)).board
        XCTAssertEqual(board.ownerTenantID, "t1")
        XCTAssertTrue(board.isShared)
        XCTAssertNil(board.meetingID)
        let share = try JSONDecoder().decode(
            WhiteboardShareResponse.self,
            from: Data("{\"ok\":true,\"share\":{\"share_uri\":\"https://example.com/s\",\"token\":\"tok\"}}".utf8)).share
        XCTAssertEqual(share.token, "tok")
        let content = try JSONDecoder().decode(
            WhiteboardContentResponse.self,
            from: Data("{\"ok\":true,\"ops\":12,\"has_next\":true,\"next_cursor\":\"C\"}".utf8))
        XCTAssertTrue(content.hasNext)
        XCTAssertEqual(content.nextCursor, "C")
        let join = try JSONDecoder().decode(
            WhiteboardJoinResponse.self,
            from: Data("{\"ok\":true,\"socket_url\":\"wss://example.com/s\",\"has_socket_token\":true}".utf8))
        XCTAssertTrue(join.hasSocketToken)
        XCTAssertNil(join.refreshSecs)
        let urls = try JSONDecoder().decode(
            WhiteboardTabURLsResponse.self,
            from: Data("{\"ok\":true,\"azure\":{\"content\":\"c\",\"website\":\"w\"}}".utf8))
        XCTAssertEqual(urls.azure?.content, "c")
        XCTAssertNil(urls.fluid)
        let fluid = try JSONDecoder().decode(
            WhiteboardFluidResponse.self, from: Data("{\"ok\":true,\"enabled\":false}".utf8))
        XCTAssertFalse(fluid.enabled)
    }

    func testCaptionsStayHonest() {
        XCTAssertTrue(WhiteboardUnavailable.fallbackCaption.localizedCaseInsensitiveContains("offline"))
        XCTAssertTrue(WhiteboardLoadedBoard.syncStatus.localizedCaseInsensitiveContains("unavailable"))
        XCTAssertTrue(WhiteboardSketchView.localOnlyCaption.localizedCaseInsensitiveContains("not shared"))
    }
}
