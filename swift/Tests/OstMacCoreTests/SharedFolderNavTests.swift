// SharedFolderNavTests.swift — om-iu-foldernav lane: drill-in + crumbs + cache.
import XCTest

@testable import OstMacCore

@MainActor
final class SharedFolderNavTests: XCTestCase {
    private nonisolated func folder(_ id: String, _ name: String, drive: String? = "D1") -> SharedFile {
        SharedFile(id: id, name: name, size: 0, drive_id: drive, is_folder: true)
    }

    private nonisolated func file(_ id: String, _ name: String) -> SharedFile {
        SharedFile(id: id, name: name, size: 100, drive_id: "D1")
    }

    /// Poll until cond holds (store fetches land via detached Tasks).
    private func settle(
        _ what: String = "", timeout: Double = 5,
        file: StaticString = #filePath, line: UInt = #line,
        cond: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "settle timeout: \(what)", file: file, line: line)
    }

    private nonisolated func rootStore(
        root: [SharedFile], kids: [String: [SharedFile]] = [:]
    ) -> SharedFilesStore {
        return SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, chat_id: "19:x", files: root) },
            children: { _, item, _ in
                SharedFileChildrenResponse(ok: true, drive_id: "D1", item_id: item, files: kids[item] ?? [])
            })
    }

    final class Counter: @unchecked Sendable { var n = 0 }

    func testRootShowsFoldersWithEmptyCrumbs() async {
        let store = rootStore(root: [folder("d1", "Design"), file("f1", "a.pdf")])
        store.open(chatID: "19:x")
        await settle("root loads") { store.state == .loaded }
        XCTAssertEqual(store.files.count, 2)
        XCTAssertTrue(store.files[0].isFolder)
        XCTAssertTrue(store.crumbs.isEmpty)
        XCTAssertTrue(store.isRoot)
    }

    func testDrillPushesCrumbAndShowsChildren() async {
        let store = rootStore(
            root: [folder("d1", "Design")],
            kids: ["d1": [file("f2", "mock.png"), folder("d2", "Sub")]])
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.drill(store.files[0])
        await settle("kids") { store.files.count == 2 && !store.isRoot }
        XCTAssertEqual(store.crumbs.map(\.name), ["Design"])
        XCTAssertEqual(store.files.map(\.name), ["mock.png", "Sub"])
        XCTAssertTrue(store.files[1].isFolder)
    }

    func testDrillUsesCacheWithoutRefetch() async {
        let hits = Counter()
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, files: [self.folder("d1", "Design")]) },
            children: { _, item, _ in
                hits.n += 1
                return SharedFileChildrenResponse(ok: true, drive_id: "D1", item_id: item, files: [self.file("f2", "k")])
            })
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.drill(store.files[0])
        await settle("kids") { !store.isRoot && store.files.first?.id == "f2" }
        XCTAssertEqual(hits.n, 1)
        store.back()
        XCTAssertTrue(store.isRoot)
        XCTAssertEqual(store.files.map(\.id), ["d1"])
        store.drill(store.files[0]) // cache hit: sync, no fetch
        XCTAssertEqual(store.files.map(\.id), ["f2"])
        XCTAssertEqual(hits.n, 1)
    }

    func testBackAtRootIsNoop() async {
        let store = rootStore(root: [file("f1", "a.pdf")])
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.back()
        XCTAssertTrue(store.isRoot)
        XCTAssertEqual(store.files.count, 1)
    }

    func testBreadcrumbJumpTruncatesToDepth() async {
        let store = rootStore(
            root: [folder("d1", "Design")],
            kids: ["d1": [folder("d2", "Sub")], "d2": [file("f9", "deep.pdf")]])
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.drill(store.files[0])
        await settle("L1") { store.crumbs.count == 1 && store.files.first?.id == "d2" }
        store.drill(store.files[0])
        await settle("L2") { store.crumbs.count == 2 && store.files.first?.id == "f9" }
        XCTAssertEqual(store.crumbs.map(\.name), ["Design", "Sub"])
        store.goTo(depth: 1) // cached ancestor: sync
        XCTAssertEqual(store.crumbs.map(\.name), ["Design"])
        XCTAssertEqual(store.files.map(\.id), ["d2"])
        store.goToRoot()
        XCTAssertTrue(store.isRoot)
        XCTAssertEqual(store.files.map(\.id), ["d1"])
    }

    func testDrillGuardsNonFolderAndMissingDrive() async {
        let hits = Counter()
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, files: [
                self.file("f1", "a.pdf"),
                self.folder("d9", "NoDrive", drive: nil),
            ]) },
            children: { _, item, _ in
                hits.n += 1
                return SharedFileChildrenResponse(ok: true, files: [])
            })
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.drill(store.files[0]) // plain file: no-op
        store.drill(store.files[1]) // no drive_id: no-op (I5 edge)
        XCTAssertTrue(store.isRoot)
        XCTAssertEqual(store.files.count, 2)
        XCTAssertEqual(hits.n, 0)
    }

    func testChildrenErrorSurfacesThenBackRestores() async {
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, files: [self.folder("d1", "Design")]) },
            children: { _, _, _ in throw CoreCallError.failed("files_children: boom") })
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.drill(store.files[0])
        await settle("err") {
            if case .error = store.state { return true }
            return false
        }
        if case let .error(m) = store.state {
            XCTAssertEqual(m, "files_children: boom")
        } else {
            XCTFail("expected error, got \(store.state)")
        }
        store.back() // parent still cached
        XCTAssertTrue(store.isRoot)
        XCTAssertEqual(store.files.map(\.id), ["d1"])
        XCTAssertEqual(store.state, .loaded)
    }

    func testOpenResetsNavAndCache() async {
        let store = rootStore(
            root: [folder("d1", "Design")],
            kids: ["d1": [file("f2", "k")] ])
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.drill(store.files[0])
        await settle("kids") { !store.isRoot }
        store.open(chatID: "19:y")
        await settle("reopen root") { store.isRoot && store.state == .loaded }
        XCTAssertTrue(store.crumbs.isEmpty)
    }

    func testRefreshRefetchesCurrentLevel() async {
        let lists = Counter()
        let kids = Counter()
        let store = SharedFilesStore(
            list: { _, _ in
                lists.n += 1
                return SharedFilesResponse(ok: true, files: [self.folder("d1", "Design")])
            },
            children: { _, item, _ in
                kids.n += 1
                return SharedFileChildrenResponse(ok: true, drive_id: "D1", item_id: item, files: [self.file("f2", "k")])
            })
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        XCTAssertEqual(lists.n, 1)
        store.refresh() // root: list again
        await settle("refresh root") { lists.n == 2 }
        store.drill(store.files[0])
        await settle("kids") { !store.isRoot && store.files.first?.id == "f2" }
        XCTAssertEqual(kids.n, 1)
        store.refresh() // folder: children again (bypasses cache)
        await settle("refresh kids") { kids.n == 2 }
    }

    func testDemoDrillStaysOffline() {
        let store = SharedFilesStore(
            children: { _, _, _ in
                XCTFail("demo drill must not touch the network")
                return SharedFileChildrenResponse(ok: true, files: [])
            })
        store.showDemo(chatID: "demo", files: [folder("d1", "Design")])
        store.drill(store.files[0])
        XCTAssertEqual(store.crumbs.map(\.name), ["Design"])
        XCTAssertEqual(store.state, .empty)
        XCTAssertEqual(store.files.count, 0)
    }

    func testUploadLandsInCurrentLevel() async {
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, files: [self.folder("d1", "Design")]) },
            children: { _, item, _ in
                SharedFileChildrenResponse(ok: true, drive_id: "D1", item_id: item, files: [self.file("f2", "k")])
            },
            upload: { _, _ in SharedFileUploadResponse(ok: true, file: self.file("nu", "new.pdf")) })
        store.open(chatID: "19:x")
        await settle("root") { store.state == .loaded }
        store.drill(store.files[0])
        await settle("kids") { !store.isRoot && store.files.first?.id == "f2" }
        store.upload(path: "/tmp/new.pdf")
        await settle("upsert") { store.files.first?.id == "nu" }
        store.back()
        XCTAssertEqual(store.files.map(\.id), ["d1"]) // root untouched
        store.drill(store.files[0]) // cached kids keep the upload
        XCTAssertEqual(store.files.first?.id, "nu")
    }
}
