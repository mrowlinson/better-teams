// DropQuickTests.swift — om-iu-dropquick lane: drop mapping + preview model + upload queue.
import XCTest

@testable import OstMacCore

@MainActor
final class DropQuickTests: XCTestCase {
    func testDropTypesIncludeFileURL() {
        XCTAssertTrue(FileDrop.dropTypes.contains(.fileURL))
    }

    func testLocalPathsKeepsFileURLsOnly() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(string: "https://example.com/x")!,
            URL(fileURLWithPath: "/tmp/b b.png"),
        ]
        XCTAssertEqual(FileDrop.localPaths(from: urls), ["/tmp/a.pdf", "/tmp/b b.png"])
    }

    func testCanPreviewNeedsExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropquick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(QuickLookPreview.canPreview(path: file.path))
        XCTAssertFalse(QuickLookPreview.canPreview(path: dir.appendingPathComponent("missing.txt").path))
        XCTAssertFalse(QuickLookPreview.canPreview(path: dir.path))
    }

    func testPreviewTitleIsBasename() {
        XCTAssertEqual(QuickLookPreview.previewTitle(path: "/tmp/a b.pdf"), "a b.pdf")
    }

    func testUploadWithoutChatNoops() {
        let store = SharedFilesStore()
        store.upload(paths: ["/tmp/a.pdf"])
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertFalse(store.uploading)
    }

    func testMultiUploadQueuesInOrder() async {
        let seen = LockedBox<[String]>([])
        let store = SharedFilesStore(
            list: { _, _ in SharedFilesResponse(ok: true, chat_id: "c", files: []) },
            upload: { _, path in
                seen.mutate { $0.append(path) }
                return try JSONDecoder().decode(
                    SharedFileUploadResponse.self,
                    from: """
                    {"ok":true,"file":{"id":"u-\(path)","name":"\(URL(fileURLWithPath: path).lastPathComponent)","size":1}}
                    """.data(using: .utf8)!)
            })
        store.open(chatID: "c")
        store.upload(paths: ["/tmp/a.pdf", "/tmp/b.pdf"])
        for _ in 0 ..< 100 {
            if seen.value.count == 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(seen.value, ["/tmp/a.pdf", "/tmp/b.pdf"])
        XCTAssertEqual(store.files.count, 2)
    }
}
