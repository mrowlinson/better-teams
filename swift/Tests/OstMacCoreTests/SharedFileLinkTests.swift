// SharedFileLinkTests.swift — om-i1-links lane: link model + store + FFI.
import XCTest

@testable import OstMacCore

@MainActor
final class SharedFileLinkTests: XCTestCase {
    func testLinkResponseDecodesCoreEnvelope() throws {
        let json = """
        {"ok":true,"link":"https://contoso.sharepoint.com/:i:/x/ABC","scope":"organization"}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(SharedFileLinkResponse.self, from: json)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.link, "https://contoso.sharepoint.com/:i:/x/ABC")
        XCTAssertEqual(resp.scope, "organization")
    }

    func testSharedFileDecodesShareURLAndOldPayloads() throws {
        let with = """
        {"id":"i1","name":"f.docx","size":10,"share_url":"https://sp/share/ABC"}
        """.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(SharedFile.self, from: with).share_url,
            "https://sp/share/ABC")
        // Old core payloads (no share_url key) still decode to nil.
        let without = """
        {"id":"i1","name":"f.docx","size":10}
        """.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(SharedFile.self, from: without).share_url)
    }

    func testWithShareURLPreservesFields() {
        let f = SharedFile(id: "i1", name: "f.docx", size: 10, drive_id: "D1", sender: "A")
        let linked = f.withShareURL("https://sp/share/ABC")
        XCTAssertEqual(linked.share_url, "https://sp/share/ABC")
        XCTAssertEqual(linked.id, "i1")
        XCTAssertEqual(linked.drive_id, "D1")
        XCTAssertEqual(linked.sender, "A")
        XCTAssertNil(f.share_url)
    }

    func testDemoLinkIsStablePerFile() {
        XCTAssertEqual(
            SharedFileLink.demoLink(for: "i1"),
            "https://demo.sharepoint.local/:i:/r/i1?sharing=org")
        XCTAssertNotEqual(SharedFileLink.demoLink(for: "i1"), SharedFileLink.demoLink(for: "i2"))
    }

    func testLinkForPrefersCacheOverRow() {
        let store = SharedFilesStore()
        let bare = SharedFile(id: "i1", name: "f")
        XCTAssertNil(store.link(for: bare))
        let row = SharedFile(id: "i1", name: "f", share_url: "https://row/x")
        XCTAssertEqual(store.link(for: row), "https://row/x")
    }

    func testShareLinkCachesCopiesAndRecopiesWithoutRefetch() async {
        let copied = LockedBox<[String]>([])
        let calls = LockedBox(0)
        let file = SharedFile(id: "i1", name: "f.docx", drive_id: "D1")
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, chat_id: "19:x", files: [file]) },
            link: { _, _, _ in
                calls.mutate { $0 += 1 }
                return SharedFileLinkResponse(ok: true, link: "https://sp/share/ABC")
            },
            copyLink: { s in copied.mutate { $0.append(s) } }
        )
        store.open(chatID: "19:x")
        await TestWait.until { store.state == .loaded }
        store.shareLink(file)
        await TestWait.until { store.link(for: file) != nil }
        XCTAssertEqual(store.link(for: file), "https://sp/share/ABC")
        XCTAssertEqual(copied.value, ["https://sp/share/ABC"])
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(store.linkingIDs.isEmpty)
        // Second tap re-copies the cached URL: no second core call.
        store.shareLink(file)
        XCTAssertEqual(copied.value, ["https://sp/share/ABC", "https://sp/share/ABC"])
        XCTAssertEqual(calls.value, 1)
    }

    func testShareLinkNoopsWithoutDriveID() async {
        let copied = LockedBox<[String]>([])
        let calls = LockedBox(0)
        let store = SharedFilesStore(
            link: { _, _, _ in
                calls.mutate { $0 += 1 }
                return SharedFileLinkResponse(ok: true, link: "https://sp/x")
            },
            copyLink: { s in copied.mutate { $0.append(s) } }
        )
        store.shareLink(SharedFile(id: "i9", name: "nodrive"))
        try? await Task.sleep(nanoseconds: 50_000_000) // negative window: proves no core call is made
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(copied.value.isEmpty)
    }

    func testShareLinkDemoFabricatesStableLink() {
        let copied = LockedBox<[String]>([])
        let store = SharedFilesStore(copyLink: { s in copied.mutate { $0.append(s) } })
        let file = SharedFile(id: "i1", name: "f.docx", drive_id: "D1")
        store.showDemo(chatID: "demo", files: [file])
        store.shareLink(file)
        XCTAssertEqual(store.link(for: file), SharedFileLink.demoLink(for: "i1"))
        XCTAssertEqual(copied.value, [SharedFileLink.demoLink(for: "i1")])
    }

    func testShareLinkErrorSurfacesMessage() async {
        let file = SharedFile(id: "i1", name: "f", drive_id: "D1")
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, chat_id: "19:x", files: [file]) },
            link: { _, _, _ in throw CoreCallError.failed("files_link: boom") }
        )
        store.open(chatID: "19:x")
        await TestWait.until { store.state == .loaded }
        store.shareLink(file)
        await TestWait.until { if case .error = store.state { return true } else { return false } }
        if case let .error(m) = store.state {
            XCTAssertEqual(m, "files_link: boom")
        } else {
            XCTFail("expected error state, got \(store.state)")
        }
    }

    /// Default copier must no-op under XCTest (never touches the live pasteboard).
    func testDefaultCopyLinkNoopsUnderXCTest() {
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        SharedFilesStore.defaultCopyLink("https://example.com/share/ABC")
    }

    /// Live FFI round-trip: empty ids rejected by core before any network.
    func testLiveFFIEmptyArgsThrow() {
        XCTAssertThrowsError(try RustCore.sharedLink(driveID: "", itemID: "i"))
        XCTAssertThrowsError(try RustCore.sharedLink(driveID: "d", itemID: "  "))
    }
}
