// SharedFilesTests.swift — om-shared lane: model + store + FFI round-trip.
import XCTest

@testable import OstMacCore

@MainActor
final class SharedFilesTests: XCTestCase {
    func testSharedFileDecodesCoreEnvelope() throws {
        let json = """
        {"ok":true,"chat_id":"19:x","files":[
          {"id":"i1","name":"deck.pdf","size":48211,
           "mime":"application/pdf","web_url":"https://w/deck",
           "download_url":"https://d/deck","drive_id":"D1",
           "created":"2026-09-20T10:00:00Z","modified":null,
           "sender":"Megan Harper"}
        ]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(SharedFilesResponse.self, from: json)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.chat_id, "19:x")
        XCTAssertEqual(resp.files.count, 1)
        let f = resp.files[0]
        XCTAssertEqual(f.id, "i1")
        XCTAssertEqual(f.name, "deck.pdf")
        XCTAssertEqual(f.size, 48211)
        XCTAssertEqual(f.mime, "application/pdf")
        XCTAssertEqual(f.web_url, "https://w/deck")
        XCTAssertEqual(f.download_url, "https://d/deck")
        XCTAssertEqual(f.drive_id, "D1")
        XCTAssertEqual(f.sender, "Megan Harper")
        XCTAssertNil(f.modified)
    }

    func testSizeLabelBoundaries() {
        XCTAssertEqual(SharedFile.sizeLabel(0), "0 bytes")
        XCTAssertEqual(SharedFile.sizeLabel(1023), "1 KB")
        XCTAssertEqual(SharedFile.sizeLabel(1024), "1 KB")
        XCTAssertEqual(SharedFile.sizeLabel(48211), "48 KB")
        XCTAssertEqual(SharedFile.sizeLabel(5 * 1024 * 1024), "5.2 MB")
        XCTAssertEqual(SharedFile.sizeLabel(3 * 1024 * 1024 * 1024), "3.22 GB")
    }

    func testIconNameMimeAndExtension() {
        XCTAssertEqual(SharedFile.iconName(mime: "image/png", filename: "x"), "photo")
        XCTAssertEqual(SharedFile.iconName(mime: "video/mp4", filename: "x"), "film")
        XCTAssertEqual(SharedFile.iconName(mime: "audio/mpeg", filename: "x"), "music.note")
        XCTAssertEqual(SharedFile.iconName(mime: "application/pdf", filename: "x"), "doc.richtext")
        XCTAssertEqual(SharedFile.iconName(mime: "application/zip", filename: "x"), "archivebox")
        XCTAssertEqual(SharedFile.iconName(mime: nil, filename: "a.png"), "photo")
        XCTAssertEqual(SharedFile.iconName(mime: nil, filename: "a.pdf"), "doc.richtext")
        XCTAssertEqual(SharedFile.iconName(mime: nil, filename: "a.docx"), "doc.text")
        XCTAssertEqual(SharedFile.iconName(mime: nil, filename: "a.xlsx"), "tablecells")
        XCTAssertEqual(SharedFile.iconName(mime: nil, filename: "a.pptx"), "rectangle.on.rectangle")
        XCTAssertEqual(SharedFile.iconName(mime: nil, filename: "a.bin"), "doc")
    }

    func testUpsertPrependsNewReplacesKnown() {
        let list = [SharedFile(id: "f1", name: "a")]
        let out = SharedFilesStore.upsert(SharedFile(id: "f2", name: "b"), into: list)
        XCTAssertEqual(out.map(\.id), ["f2", "f1"])
        let edit = SharedFilesStore.upsert(SharedFile(id: "f1", name: "a2"), into: out)
        XCTAssertEqual(edit.map(\.id), ["f2", "f1"])
        XCTAssertEqual(edit[1].name, "a2")
    }

    func testDownloadDestinationIsDownloads() {
        let dest = SharedFilesStore.downloadDestination(filename: "a b.pdf")
        XCTAssertTrue(dest.hasSuffix("/Downloads/a b.pdf"))
    }

    func testShowDemoAdoptsFiles() {
        let store = SharedFilesStore()
        store.showDemo(chatID: "demo", files: DemoData.sharedFiles(for: "demo"))
        XCTAssertEqual(store.chatID, "demo")
        XCTAssertEqual(store.files.count, 3)
        XCTAssertEqual(store.state, .loaded)
        let empty = SharedFilesStore()
        empty.showDemo(chatID: "demo-3", files: DemoData.sharedFiles(for: "demo-3"))
        XCTAssertEqual(empty.state, .empty)
    }

    func testDemoUploadFabricatesRow() {
        let store = SharedFilesStore()
        store.showDemo(chatID: "demo", files: [])
        store.upload(path: "/tmp/report.pdf")
        XCTAssertEqual(store.files.first?.name, "report.pdf")
        XCTAssertEqual(store.state, .loaded)
    }

    func testOpenReturnsNilWithoutURL() {
        let opened = LockedBox<[URL]>([])
        let store = SharedFilesStore(openURL: { url in opened.mutate { $0.append(url) }; return true })
        XCTAssertNil(store.open(SharedFile(id: "f", name: "x")))
        XCTAssertTrue(opened.value.isEmpty)
        let got = store.open(SharedFile(id: "f", name: "x", web_url: "https://w/x"))
        XCTAssertEqual(got?.absoluteString, "https://w/x")
        XCTAssertEqual(opened.value.count, 1)
    }

    func testListErrorSurfacesMessage() async {
        let store = SharedFilesStore(list: { _, _ in throw CoreCallError.failed("files: boom") })
        store.open(chatID: "19:x")
        // Poll until the detached fetch lands (fast, no network).
        for _ in 0 ..< 50 {
            if case .error = store.state { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case let .error(m) = store.state {
            XCTAssertEqual(m, "files: boom")
        } else {
            XCTFail("expected error state, got \(store.state)")
        }
    }

    /// Default opener must no-op under XCTest (regression: tests launching
    /// the owner's real browser).
    func testDefaultOpenURLNoopsUnderXCTest() {
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        XCTAssertFalse(
            SharedFilesStore.defaultOpenURL(URL(string: "https://example.com/shared")!))
    }

    /// Live FFI round-trip: empty args rejected by core before any network.
    func testLiveFFIEmptyArgsThrow() {
        XCTAssertThrowsError(try RustCore.sharedFiles(chatID: ""))
        XCTAssertThrowsError(try RustCore.sharedUpload(chatID: "19:x", path: "  "))
        XCTAssertThrowsError(try RustCore.sharedDownload(driveID: "", itemID: "i", dest: "/tmp/x"))
    }

    // MARK: - om-i3-manage

    func testManageResponsesDecode() throws {
        let item = """
        {"id":"i1","name":"plan v2.docx","size":99,"mime":null,"web_url":null,\
        "download_url":null,"drive_id":"D1","created":null,"modified":null,\
        "sender":null,"attachment_id":null}
        """
        let ren = try JSONDecoder().decode(
            SharedFileManageResponse.self,
            from: #"{"ok":true,"file":\#(item)}"#.data(using: .utf8)!)
        XCTAssertTrue(ren.ok)
        XCTAssertEqual(ren.file.name, "plan v2.docx")
        let mov = try JSONDecoder().decode(
            SharedFileManageResponse.self,
            from: #"{"ok":true,"file":\#(item)}"#.data(using: .utf8)!)
        XCTAssertEqual(mov.file.id, "i1")
        let cpy = try JSONDecoder().decode(
            SharedFileCopyResponse.self,
            from: #"{"ok":true,"monitor":"https://m/1"}"#.data(using: .utf8)!)
        XCTAssertEqual(cpy.monitor, "https://m/1")
        let del = try JSONDecoder().decode(
            SharedFileDeleteResponse.self,
            from: #"{"ok":true,"id":"i1"}"#.data(using: .utf8)!)
        XCTAssertEqual(del.id, "i1")
    }

    func testRemovedDropsID() {
        let list = [SharedFile(id: "f1", name: "a"), SharedFile(id: "f2", name: "b")]
        XCTAssertEqual(
            SharedFilesStore.removed("f1", from: list).map(\.id), ["f2"])
        XCTAssertEqual(
            SharedFilesStore.removed("zz", from: list).map(\.id), ["f1", "f2"])
    }

    func testRenameUpsertsRow() async {
        let file = SharedFile(id: "f1", name: "a", drive_id: "D1")
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, chat_id: "19:x", files: [file]) },
            rename: { _, _, name in
                SharedFileManageResponse(
                    ok: true,
                    file: SharedFile(id: "f1", name: name, drive_id: "D1"))
            }
        )
        store.open(chatID: "19:x")
        for _ in 0 ..< 50 {
            if store.state == .loaded { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        store.rename(file, to: "b")
        for _ in 0 ..< 50 {
            if store.files.first?.name == "b" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.files.first?.name, "b")
        XCTAssertEqual(store.files.count, 1)
    }

    func testDeleteRemovesRow() async {
        let f1 = SharedFile(id: "f1", name: "a", drive_id: "D1")
        let f2 = SharedFile(id: "f2", name: "b", drive_id: "D1")
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, chat_id: "19:x", files: [f1, f2]) },
            delete: { _, _ in SharedFileDeleteResponse(ok: true, id: "f1") }
        )
        store.open(chatID: "19:x")
        for _ in 0 ..< 50 {
            if store.files.count == 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        store.delete(f1)
        for _ in 0 ..< 50 {
            if store.files.count == 1 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.files.map(\.id), ["f2"])
    }

    func testDemoDeleteRemovesRowLocally() {
        let store = SharedFilesStore()
        store.showDemo(chatID: "demo", files: [SharedFile(id: "f1", name: "a")])
        store.delete(SharedFile(id: "f1", name: "a"))
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertEqual(store.state, .empty)
    }

    func testManageFFIEmptyArgsThrow() {
        XCTAssertThrowsError(try RustCore.sharedRename(driveID: "", itemID: "i", newName: "n"))
        XCTAssertThrowsError(try RustCore.sharedMove(driveID: "d", itemID: "i", destFolderID: ""))
        XCTAssertThrowsError(
            try RustCore.sharedCopy(driveID: "d", itemID: "", destFolderID: "f", newName: nil))
        XCTAssertThrowsError(try RustCore.sharedDelete(driveID: "d", itemID: "  "))
    }

}
