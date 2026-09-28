// ComposeAttachmentsTests.swift — om-attach lane: picker model, cap gate,
// upload call shape, states.
import XCTest

@testable import OstMacCore

@MainActor
final class ComposeAttachmentsTests: XCTestCase {
    private nonisolated static let cap = 4 * 1024 * 1024 as UInt64

    // MARK: - Cap gate (pure)

    func testMaxUploadMatchesCore4MB() {
        XCTAssertEqual(ComposeAttachments.maxUploadBytes, Self.cap)
    }

    func testCapGateBoundary() {
        XCTAssertFalse(ComposeAttachments.isTooLarge(size: 0))
        XCTAssertFalse(ComposeAttachments.isTooLarge(size: Self.cap))
        XCTAssertTrue(ComposeAttachments.isTooLarge(size: Self.cap + 1))
    }

    func testCapMessageSurfacesSessionPathBeforeUpload() {
        let msg = ComposeAttachments.capMessage(actual: 5 * 1024 * 1024)
        XCTAssertEqual(msg, "File is 5.2 MB; large files use resumable upload")
    }

    // MARK: - Picker model (pure)

    func testDisplayNameIsLastComponent() {
        XCTAssertEqual(ComposeAttachments.displayName(path: "/tmp/a b.pdf"), "a b.pdf")
        XCTAssertEqual(ComposeAttachments.displayName(path: "plain.txt"), "plain.txt")
    }

    func testStagedModelKeepsNameSizeAndGatesCap() {
        let ok = ComposeAttachments.staged(path: "/tmp/a.pdf", size: 100)
        XCTAssertEqual(ok.name, "a.pdf")
        XCTAssertEqual(ok.size, 100)
        XCTAssertEqual(ok.state, .staged)
        let over = ComposeAttachments.staged(path: "/tmp/b.mov", size: Self.cap + 1)
        XCTAssertEqual(over.name, "b.mov")
        XCTAssertEqual(over.state, .tooLarge(actual: Self.cap + 1))
    }

    // MARK: - Stage (store + size probe seam)

    func testStageProbesSizesAndGatesCap() {
        let sizes: [String: UInt64] = ["/tmp/a.pdf": 100, "/tmp/b.mov": Self.cap + 1]
        let store = ComposeAttachmentsStore(sizeProbe: { sizes[$0] })
        store.stage(paths: ["/tmp/a.pdf", "/tmp/b.mov"])
        XCTAssertEqual(store.attachments.count, 2)
        XCTAssertEqual(store.attachments[0].state, .staged)
        XCTAssertEqual(store.attachments[1].state, .tooLarge(actual: Self.cap + 1))
        XCTAssertTrue(store.hasStaged)
        XCTAssertEqual(store.staged.map(\.path), ["/tmp/a.pdf"])
    }

    func testStageURLsUsesPaths() {
        let store = ComposeAttachmentsStore(sizeProbe: { _ in 10 })
        store.stage(urls: [URL(fileURLWithPath: "/tmp/a.pdf")])
        XCTAssertEqual(store.attachments.map(\.name), ["a.pdf"])
        XCTAssertEqual(store.attachments.first?.state, .staged)
    }

    func testUnreadableSizeStagesAsZero() {
        let store = ComposeAttachmentsStore(sizeProbe: { _ in nil })
        store.stage(paths: ["/tmp/gone.bin"])
        XCTAssertEqual(store.attachments.first?.size, 0)
        XCTAssertEqual(store.attachments.first?.state, .staged)
    }

    // MARK: - Upload call shape

    func testUploadCallsChatIDAndPathInPickOrder() async {
        let callsBox = LockedBox<[(String, String)]>([])
        let store = ComposeAttachmentsStore(
            upload: { chat, path in
                callsBox.mutate { $0.append((chat, path)) }
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f-\(path)", name: "n", size: 1))
            },
            sizeProbe: { _ in 100 })
        store.stage(paths: ["/tmp/a.pdf", "/tmp/b.pdf"])
        let done = await store.uploadPending(chatID: "19:chat@thread.v2")
        let calls = callsBox.value
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, "19:chat@thread.v2")
        XCTAssertEqual(calls.map(\.1), ["/tmp/a.pdf", "/tmp/b.pdf"])
        XCTAssertEqual(done.count, 2)
    }

    func testUploadSendsLargeFilesViaSessionPath() async {
        let callsBox = LockedBox<[(String, String)]>([])
        let store = ComposeAttachmentsStore(
            upload: { chat, path in
                callsBox.mutate { $0.append((chat, path)) }
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f-big", name: "b.mov", size: Self.cap + 1))
            },
            sizeProbe: { _ in Self.cap + 1 })
        store.stage(paths: ["/tmp/b.mov"])
        XCTAssertEqual(store.attachments.first?.state, .tooLarge(actual: Self.cap + 1))
        let done = await store.uploadPending(chatID: "19:chat@thread.v2")
        let calls = callsBox.value
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "19:chat@thread.v2")
        XCTAssertEqual(calls.first?.1, "/tmp/b.mov")
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(store.attachments.first?.state, .uploaded)
        XCTAssertFalse(store.uploading)
        XCTAssertNil(store.error)
    }

    // MARK: - States

    func testUploadSuccessMarksUploadedAndResetsFlag() async {
        let store = ComposeAttachmentsStore(
            upload: { _, path in
                SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f1", name: "a.pdf", size: 100))
            },
            sizeProbe: { _ in 100 })
        store.stage(paths: ["/tmp/a.pdf"])
        XCTAssertFalse(store.uploading)
        let done = await store.uploadPending(chatID: "19:x")
        XCTAssertEqual(done.first?.id, "f1")
        XCTAssertEqual(store.attachments.first?.state, .uploaded)
        XCTAssertFalse(store.uploading)
        XCTAssertNil(store.error)
    }

    func testUploadFailureMarksRowAndContinues() async {
        let store = ComposeAttachmentsStore(
            upload: { _, path in
                if path == "/tmp/a.pdf" { throw CoreCallError.failed("net down") }
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f2", name: "b.pdf", size: 100))
            },
            sizeProbe: { _ in 100 })
        store.stage(paths: ["/tmp/a.pdf", "/tmp/b.pdf"])
        let done = await store.uploadPending(chatID: "19:x")
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(store.attachments[0].state, .failed("net down"))
        XCTAssertEqual(store.attachments[1].state, .uploaded)
        XCTAssertEqual(store.error, "net down")
        XCTAssertFalse(store.uploading)
    }

    func testDemoFabricatesWithoutCore() async {
        let calls = LockedBox(0)
        let store = ComposeAttachmentsStore(
            upload: { _, _ in
                calls.mutate { $0 += 1 }
                throw CoreCallError.failed("must not be called")
            },
            sizeProbe: { _ in 100 })
        store.stage(paths: ["/tmp/a.pdf"])
        let done = await store.uploadPending(chatID: "demo", isDemo: true)
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(done.first?.name, "a.pdf")
        XCTAssertEqual(store.attachments.first?.state, .uploaded)
    }

    // MARK: - Row management

    func testRetryRearmsFailedOnly() {
        let store = ComposeAttachmentsStore(sizeProbe: { _ in 100 })
        store.stage(paths: ["/tmp/a.pdf"])
        let id = store.attachments[0].id
        store.retry(id: id) // staged: no-op
        XCTAssertEqual(store.attachments[0].state, .staged)
        store.retry(id: "unknown") // unknown: no-op
        XCTAssertEqual(store.attachments.count, 1)
    }

    func testRetryAfterFailure() async {
        let fail = LockedBox(true)
        let store = ComposeAttachmentsStore(
            upload: { _, _ in
                if fail.value { throw CoreCallError.failed("flaky") }
                return SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f1", name: "a.pdf", size: 100))
            },
            sizeProbe: { _ in 100 })
        store.stage(paths: ["/tmp/a.pdf"])
        let id = store.attachments[0].id
        _ = await store.uploadPending(chatID: "19:x")
        XCTAssertEqual(store.attachments[0].state, .failed("flaky"))
        store.retry(id: id)
        XCTAssertEqual(store.attachments[0].state, .staged)
        fail.value = false
        let done = await store.uploadPending(chatID: "19:x")
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(store.attachments[0].state, .uploaded)
    }

    func testRemoveAndClearFinished() async {
        let store = ComposeAttachmentsStore(
            upload: { _, _ in
                SharedFileUploadResponse(
                    ok: true, file: SharedFile(id: "f1", name: "a.pdf", size: 100))
            },
            sizeProbe: { path in path == "/tmp/big.mov" ? Self.cap + 1 : 100 })
        store.stage(paths: ["/tmp/a.pdf", "/tmp/big.mov"])
        let done = await store.uploadPending(chatID: "19:x")
        XCTAssertEqual(done.count, 2) // large files ride the session path
        store.clearFinished()
        XCTAssertTrue(store.attachments.isEmpty)
        XCTAssertFalse(store.hasStaged)
    }

    func testClearErrorDismissesBanner() async {
        let store = ComposeAttachmentsStore(
            upload: { _, _ in throw CoreCallError.failed("boom") },
            sizeProbe: { _ in 100 })
        store.stage(paths: ["/tmp/a.pdf"])
        _ = await store.uploadPending(chatID: "19:x")
        XCTAssertEqual(store.error, "boom")
        store.clearError()
        XCTAssertNil(store.error)
    }
}
