// Guard: a list refresh that lands after an upload must not drop the uploaded row.
import XCTest

@testable import OstMacCore

@MainActor
final class UploadRefreshGuardTests: XCTestCase {
    func testSlowListRefreshKeepsRowUploadedMeanwhile() async {
        let gate = DispatchSemaphore(value: 0)
        let store = SharedFilesStore(
            list: { _, _ in
                gate.wait() // list answers only after the upload finished
                return SharedFilesResponse(ok: true, chat_id: "c", files: [])
            },
            upload: { _, path in
                try JSONDecoder().decode(
                    SharedFileUploadResponse.self,
                    from: #"{"ok":true,"file":{"id":"u1","name":"a.pdf","size":1}}"#.data(using: .utf8)!)
            })
        store.open(chatID: "c")
        store.upload(paths: ["/tmp/a.pdf"])
        for _ in 0 ..< 500 where store.files.count != 1 || store.uploading {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.files.map(\.id), ["u1"], "control: upload landed before the list")
        gate.signal()
        for _ in 0 ..< 500 where store.state != .loaded && store.state != .empty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.files.map(\.id), ["u1"], "refresh must merge, not overwrite")
    }
}
