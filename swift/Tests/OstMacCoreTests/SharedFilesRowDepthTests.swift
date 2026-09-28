// SharedFilesRowDepthTests.swift — om-iu-rowdepth lane: multi-upload,
// 4 MB pre-gate, Save-as, sort + type filter (all Swift, no core change).
import XCTest

@testable import OstMacCore

@MainActor
final class SharedFilesRowDepthTests: XCTestCase {
    private nonisolated static let cap = 4 * 1024 * 1024 as UInt64

    private func openedStore(
        files: [SharedFile] = [],
        upload: SharedFilesStore.UploadFetcher? = nil,
        download: SharedFilesStore.DownloadFetcher? = nil,
        sizeProbe: SharedFilesStore.SizeProbe? = nil
    ) async -> SharedFilesStore {
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, files: files) },
            upload: upload ?? { _, path in
                SharedFileUploadResponse(
                    ok: true,
                    file: SharedFile(id: "up-\(path)", name: (path as NSString).lastPathComponent, size: 10))
            },
            download: download ?? { _, _, dest in
                SharedFileDownloadResponse(ok: true, path: dest, bytes: 10)
            },
            sizeProbe: sizeProbe ?? { _ in 100 })
        store.open(chatID: "19:x")
        for _ in 0 ..< 50 {
            if store.state == .loaded || store.state == .empty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return store
    }

    private func waitForUploads(_ store: SharedFilesStore, count: Int) async {
        for _ in 0 ..< 100 {
            if !store.uploading, store.files.count >= count { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Multi-upload (match composer)

    func testMultiUploadCallsInPickOrder() async {
        let callsBox = LockedBox<[(String, String)]>([])
        let store = await openedStore(
            upload: { chat, path in
                callsBox.mutate { $0.append((chat, path)) }
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "up-\(path)", name: "n", size: 10))
            })
        store.upload(paths: ["/tmp/a.pdf", "/tmp/b.pdf"])
        await waitForUploads(store, count: 2)
        let calls = callsBox.value
        XCTAssertEqual(calls.map(\.0), ["19:x", "19:x"])
        XCTAssertEqual(calls.map(\.1), ["/tmp/a.pdf", "/tmp/b.pdf"])
        XCTAssertEqual(store.files.count, 2)
        XCTAssertFalse(store.uploading)
    }

    func testUploadPathsEmptyIsNoop() async {
        let calls = LockedBox(0)
        let store = await openedStore(
            upload: { _, _ in
                calls.mutate { $0 += 1 }
                throw CoreCallError.failed("must not be called")
            })
        store.upload(paths: [])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(store.uploading)
    }

    // MARK: - 4 MB pre-gate (match composer)

    func testPreGateSkipsOverCapWithoutCalling() async {
        let calls = LockedBox<[String]>([])
        let store = await openedStore(
            upload: { _, path in
                calls.mutate { $0.append(path) }
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f-ok", name: "ok.pdf", size: 100))
            },
            sizeProbe: { $0 == "/tmp/big.mov" ? Self.cap + 1 : 100 })
        store.upload(paths: ["/tmp/ok.pdf", "/tmp/big.mov"])
        await waitForUploads(store, count: 1)
        XCTAssertEqual(calls.value, ["/tmp/ok.pdf"])
        XCTAssertEqual(store.gatedUploads, ["/tmp/big.mov"])
        XCTAssertEqual(
            store.uploadError,
            "File is 4.2 MB; large files use resumable upload")
        XCTAssertFalse(store.files.map(\.name).contains("big.mov"))
    }

    func testGateBoundaryExactly4MBStillUploads() async {
        let calls = LockedBox(0)
        let store = await openedStore(
            upload: { _, _ in
                calls.mutate { $0 += 1 }
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f-edge", name: "edge.bin", size: Self.cap))
            },
            sizeProbe: { _ in Self.cap })
        store.upload(paths: ["/tmp/edge.bin"])
        await waitForUploads(store, count: 1)
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(store.gatedUploads.isEmpty)
        XCTAssertNil(store.uploadError)
    }

    func testClearUploadErrorDismissesBanner() async {
        let store = await openedStore(sizeProbe: { _ in Self.cap + 1 })
        store.upload(paths: ["/tmp/big.mov"])
        for _ in 0 ..< 100 {
            if !store.gatedUploads.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(store.uploadError)
        store.clearUploadError()
        XCTAssertNil(store.uploadError)
        XCTAssertTrue(store.gatedUploads.isEmpty)
    }

    // MARK: - Save-as

    func testSaveAsDefaultsToDownloadsName() {
        XCTAssertEqual(
            SharedFilesStore.saveAsName(for: SharedFile(id: "f", name: "a b.pdf")),
            "a b.pdf")
        XCTAssertEqual(
            SharedFilesStore.saveAsDirectory().lastPathComponent, "Downloads")
        XCTAssertEqual(
            SharedFilesStore.saveAsDestination(for: SharedFile(id: "f", name: "a b.pdf")),
            SharedFilesStore.downloadDestination(filename: "a b.pdf"))
    }

    func testSaveAsPassesExplicitDestToCore() async {
        let dests = LockedBox<[String]>([])
        let store = await openedStore(
            files: [SharedFile(id: "f1", name: "deck.pdf", drive_id: "D1")],
            download: { _, _, dest in
                dests.mutate { $0.append(dest) }
                return SharedFileDownloadResponse(ok: true, path: dest, bytes: 10)
            })
        store.saveAs(store.files[0], to: "/tmp/picked/deck.pdf")
        for _ in 0 ..< 100 {
            if store.savedPath != nil { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(dests.value, ["/tmp/picked/deck.pdf"])
        XCTAssertEqual(store.savedPath, "/tmp/picked/deck.pdf")
    }

    // MARK: - Sort (name/date/size)

    private static let sortFiles = [
        SharedFile(id: "b", name: "bravo.pdf", size: 300, modified: "2026-09-20T10:00:00Z"),
        SharedFile(id: "a", name: "Alpha.pdf", size: 100, modified: "2026-09-22T10:00:00Z"),
        SharedFile(id: "c", name: "charlie.pdf", size: 200, modified: "2026-09-21T10:00:00Z"),
    ]

    func testSortByNameCaseInsensitiveAscending() {
        let out = SharedFilesStore.sorted(Self.sortFiles, by: .name)
        XCTAssertEqual(out.map(\.id), ["a", "b", "c"])
    }

    func testSortByDateNewestFirst() {
        let out = SharedFilesStore.sorted(Self.sortFiles, by: .date)
        XCTAssertEqual(out.map(\.id), ["a", "c", "b"])
    }

    func testSortBySizeLargestFirst() {
        let out = SharedFilesStore.sorted(Self.sortFiles, by: .size)
        XCTAssertEqual(out.map(\.id), ["b", "c", "a"])
    }

    func testSortDateFallsBackToCreatedThenLast() {
        let files = [
            SharedFile(id: "noclobber", name: "x", size: 1),
            SharedFile(id: "created", name: "y", size: 1, created: "2026-09-23T10:00:00Z"),
        ]
        let out = SharedFilesStore.sorted(files, by: .date)
        XCTAssertEqual(out.map(\.id), ["created", "noclobber"])
    }

    // MARK: - Type filter chips

    func testTypeFilterMatchesMimeAndExtension() {
        let docs = SharedFile(id: "d", name: "memo.docx")
        let pdf = SharedFile(id: "p", name: "deck.pdf", mime: "application/pdf")
        let img = SharedFile(id: "i", name: "shot.png", mime: "image/png")
        let sheet = SharedFile(id: "s", name: "budget.xlsx")
        let slide = SharedFile(id: "t", name: "pitch.key")
        let other = SharedFile(id: "o", name: "archive.zip")
        XCTAssertTrue(SharedFilesTypeFilter.docs.matches(docs))
        XCTAssertTrue(SharedFilesTypeFilter.docs.matches(pdf))
        XCTAssertTrue(SharedFilesTypeFilter.images.matches(img))
        XCTAssertTrue(SharedFilesTypeFilter.sheets.matches(sheet))
        XCTAssertTrue(SharedFilesTypeFilter.slides.matches(slide))
        XCTAssertTrue(SharedFilesTypeFilter.other.matches(other))
        XCTAssertFalse(SharedFilesTypeFilter.images.matches(pdf))
        XCTAssertTrue(SharedFilesTypeFilter.all.matches(other))
    }

    func testFilteredKeepsOnlyChipKind() {
        let files = [
            SharedFile(id: "d", name: "memo.docx"),
            SharedFile(id: "i", name: "shot.png"),
            SharedFile(id: "s", name: "budget.xlsx"),
        ]
        XCTAssertEqual(
            SharedFilesStore.filtered(files, by: .all).map(\.id), ["d", "i", "s"])
        XCTAssertEqual(
            SharedFilesStore.filtered(files, by: .docs).map(\.id), ["d"])
        XCTAssertEqual(
            SharedFilesStore.filtered(files, by: .images).map(\.id), ["i"])
    }

    func testDisplayedCombinesFilterAndSort() {
        let files = [
            SharedFile(id: "b", name: "bravo.pdf", size: 300),
            SharedFile(id: "a", name: "alpha.pdf", size: 100),
            SharedFile(id: "i", name: "shot.png", size: 999),
        ]
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, files: []) })
        store.showDemo(chatID: "demo", files: files)
        store.sort = .size
        store.filter = .docs
        XCTAssertEqual(store.displayedFiles.map(\.id), ["b", "a"])
    }
}
