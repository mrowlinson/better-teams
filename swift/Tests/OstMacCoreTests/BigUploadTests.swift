// BigUploadTests.swift — om-i4-bigup lane: resumable uploads >4 MB.
import XCTest

@testable import OstMacCore

@MainActor
final class BigUploadTests: XCTestCase {
    func testProgressResponseDecodesCoreEnvelope() throws {
        let json = """
        {"ok":true,"uploaded":25,"total":100,"percent":25,"active":true}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(UploadProgressResponse.self, from: json)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.uploaded, 25)
        XCTAssertEqual(resp.total, 100)
        XCTAssertEqual(resp.percent, 25)
        XCTAssertTrue(resp.active)
    }

    func testProgressFractionBoundaries() {
        XCTAssertNil(SharedFilesStore.progressFraction(uploaded: 0, total: 0))
        XCTAssertEqual(SharedFilesStore.progressFraction(uploaded: 0, total: 100), 0.0)
        XCTAssertEqual(SharedFilesStore.progressFraction(uploaded: 25, total: 100), 0.25)
        XCTAssertEqual(SharedFilesStore.progressFraction(uploaded: 100, total: 100), 1.0)
        XCTAssertEqual(SharedFilesStore.progressFraction(uploaded: 200, total: 100), 1.0)
    }

    func testPendingUploadsIncludesLargeFiles() {
        let cap = ComposeAttachments.maxUploadBytes
        let store = ComposeAttachmentsStore(sizeProbe: { path in
            path == "/tmp/b.mov" ? cap + 1 : 100
        })
        store.stage(paths: ["/tmp/a.pdf", "/tmp/b.mov"])
        XCTAssertEqual(store.pendingUploads.map(\.path), ["/tmp/a.pdf", "/tmp/b.mov"])
        XCTAssertTrue(store.hasStaged)
    }

    /// Spinner stays up while % streams in from the progress poll.
    func testSharedUploadStreamsPercentWhileSpinning() async {
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, files: []) },
            upload: { _, _ in
                Thread.sleep(forTimeInterval: 0.6) // hold the spinner open
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f-big", name: "b.mov", size: 9))
            },
            progress: {
                UploadProgressResponse(ok: true, uploaded: 50, total: 100, percent: 50, active: true)
            })
        store.open(chatID: "19:x")
        for _ in 0 ..< 50 {
            if case .empty = store.state { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        store.upload(path: "/tmp/b.mov")
        var sawProgress = false
        for _ in 0 ..< 100 {
            if store.uploadProgress != nil {
                sawProgress = true
                XCTAssertTrue(store.uploading) // spinner stays while % streams
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sawProgress)
        XCTAssertEqual(store.uploadProgress, 0.5)
        for _ in 0 ..< 100 {
            if !store.uploading { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(store.uploading)
        XCTAssertNil(store.uploadProgress)
        XCTAssertEqual(store.files.first?.id, "f-big")
    }

    /// Live FFI: progress gauge reads idle without network.
    func testLiveProgressGaugeIdlesWithoutNetwork() throws {
        let resp = try RustCore.sharedUploadProgress()
        XCTAssertTrue(resp.ok)
        XCTAssertFalse(resp.active)
        XCTAssertEqual(resp.percent, 0)
    }
}
