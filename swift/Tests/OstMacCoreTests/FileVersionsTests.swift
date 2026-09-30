// FileVersionsTests.swift — om-i2-versions lane: model + store + FFI round-trip.
import XCTest

@testable import OstMacCore

@MainActor
final class FileVersionsTests: XCTestCase {
    func testFileVersionDecodesCoreEnvelope() throws {
        let json = """
        {"ok":true,"drive_id":"D1","item_id":"I1","versions":[
          {"id":"3.0","size":48211,
           "modified":"2026-09-20T10:00:00Z","modified_by":"Megan Harper"},
          {"id":"2.0","size":0,"modified":null,"modified_by":null}
        ]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(FileVersionsResponse.self, from: json)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.drive_id, "D1")
        XCTAssertEqual(resp.item_id, "I1")
        XCTAssertEqual(resp.versions.count, 2)
        let v = resp.versions[0]
        XCTAssertEqual(v.id, "3.0")
        XCTAssertEqual(v.size, 48211)
        XCTAssertEqual(v.modified, "2026-09-20T10:00:00Z")
        XCTAssertEqual(v.modified_by, "Megan Harper")
        XCTAssertEqual(v.sizeLabel, "48 KB")
        XCTAssertNil(resp.versions[1].modified)
    }

    func testVersionDownloadDestinationKeepsExtension() {
        let pdf = FileVersionsStore.versionDownloadDestination(filename: "deck.pdf", versionID: "3.0")
        XCTAssertTrue(pdf.hasSuffix("/Downloads/deck-v3.0.pdf"))
        let bare = FileVersionsStore.versionDownloadDestination(filename: "README", versionID: "1.0")
        XCTAssertTrue(bare.hasSuffix("/Downloads/README-v1.0"))
        // Slashes in the id never escape ~/Downloads.
        let evil = FileVersionsStore.versionDownloadDestination(filename: "a.txt", versionID: "../x")
        XCTAssertTrue(evil.hasSuffix("/Downloads/a-v.._x.txt"))
        XCTAssertFalse(evil.contains("../"))
    }

    func testShowDemoAdoptsVersions() {
        let store = FileVersionsStore()
        store.showDemo(
            driveID: "D1", itemID: "I1", filename: "deck.pdf",
            versions: [FileVersion(id: "3.0", size: 10)])
        XCTAssertEqual(store.driveID, "D1")
        XCTAssertEqual(store.itemID, "I1")
        XCTAssertEqual(store.filename, "deck.pdf")
        XCTAssertEqual(store.versions.count, 1)
        XCTAssertEqual(store.state, .loaded)
        let empty = FileVersionsStore()
        empty.showDemo(driveID: "D", itemID: "I", filename: "x", versions: [])
        XCTAssertEqual(empty.state, .empty)
    }

    func testListErrorSurfacesMessage() async {
        let store = FileVersionsStore(list: { _, _ in throw CoreCallError.failed("versions: boom") })
        store.open(driveID: "D1", itemID: "I1", filename: "deck.pdf")
        await TestWait.until(interval: 0.02) { if case .error = store.state { return true } else { return false } }
        if case let .error(m) = store.state {
            XCTAssertEqual(m, "versions: boom")
        } else {
            XCTFail("expected error state, got \(store.state)")
        }
    }

    func testRestoreMarksRestored() async {
        let store = FileVersionsStore(
            list: { _, _ in FileVersionsResponse(ok: true, versions: [FileVersion(id: "2.0")]) },
            restore: { _, _, ver in FileVersionRestoreResponse(ok: true, version_id: ver) }
        )
        store.open(driveID: "D1", itemID: "I1", filename: "deck.pdf")
        await TestWait.until(interval: 0.02) { store.state == .loaded }
        XCTAssertEqual(store.state, .loaded)
        store.restore(store.versions[0])
        await TestWait.until(interval: 0.02) { store.restoredID != nil }
        XCTAssertEqual(store.restoredID, "2.0")
    }

    /// Smoke F8: subtitle renders the stamp in chat-timestamp
    /// style, never raw ISO.
    func testSubtitleFormatsStampChatStyle() {
        let v = FileVersion(
            id: "3.0", size: 48211,
            modified: "2026-09-20T10:00:00Z",
            modified_by: "Megan Harper")
        let sub = v.subtitle
        XCTAssertTrue(sub.hasPrefix("v3.0 · Megan Harper · "))
        XCTAssertFalse(sub.contains("2026-09-20T10:00:00Z"))
        XCTAssertFalse(sub.contains("T10:00"))
        XCTAssertTrue(sub.hasSuffix(ChatMessage.shortTime("2026-09-20T10:00:00Z")))
    }

    func testSubtitleOmitsMissingParts() {
        XCTAssertEqual(FileVersion(id: "2.0").subtitle, "v2.0")
        let noBy = FileVersion(id: "2.0", modified: "2026-09-20T10:00:00Z")
        XCTAssertEqual(
            noBy.subtitle,
            "v2.0 · \(ChatMessage.shortTime("2026-09-20T10:00:00Z"))")
        let noStamp = FileVersion(id: "1.0", modified_by: "Megan Harper")
        XCTAssertEqual(noStamp.subtitle, "v1.0 · Megan Harper")
    }

    /// Live FFI round-trip: empty args rejected by core before any network.
    func testLiveFFIEmptyArgsThrow() {
        XCTAssertThrowsError(try RustCore.fileVersions(driveID: "", itemID: "I1"))
        XCTAssertThrowsError(try RustCore.fileVersionRestore(driveID: "D1", itemID: "I1", versionID: "  "))
        XCTAssertThrowsError(
            try RustCore.fileVersionDownload(driveID: "D1", itemID: "", versionID: "1.0", dest: "/tmp/x"))
    }
}
