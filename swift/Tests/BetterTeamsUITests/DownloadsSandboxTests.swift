// DownloadsSandboxTests.swift — guard: no test resolves the user's real
// ~/Downloads for writing, nothing opens a browser from a test, and only
// real files download (APPNATIVE4: a test run once left an empty
// "harness" file in the owner's Downloads).
import WebKit
import XCTest
import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class DownloadsSandboxTests: XCTestCase {
    private let real = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true).standardizedFileURL.path

    private func assertNotReal(_ path: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        XCTAssertFalse(p == real || p.hasPrefix(real + "/"), "\(what) writes into the real ~/Downloads", file: file, line: line)
    }

    func testNoTestResolvesTheRealDownloadsFolder() {
        XCTAssertTrue(UserFolders.isTestProcess)
        XCTAssertTrue(FrameHost.isTestProcess)
        assertNotReal(UserFolders.downloads().path, "UserFolders")
        assertNotReal(FrameHost.defaultDownloads().path, "FrameHost default")
        assertNotReal(FrameHost(accountKey: "demo").downloadsFolder.path, "demo FrameHost")
        assertNotReal(FrameHost(accountKey: "dl-guard").downloadsFolder.path, "account FrameHost")
        assertNotReal(TeamsFrameDownloads.defaultDirectory().path, "TeamsFrameDownloads")
        assertNotReal(SharedFilesStore.downloadDestination(filename: "a.pdf"), "Shared files")
        assertNotReal(SharedFilesStore.saveAsDirectory().path, "Shared save-as")
        assertNotReal(FileVersionsStore.versionDownloadDestination(filename: "a.pdf", versionID: "1"), "File versions")
        // Control: outside tests the real folder is the destination.
        XCTAssertEqual(UserFolders.downloads(test: false).standardizedFileURL.path, real)
    }

    /// Only a real file downloads: the page's own (or a declared
    /// attachment's) successful, non-empty, non-sign-in response.
    func testOnlyRealFilesDownload() {
        func r(_ url: String, status: Int = 200, length: String? = "10", disposition: String? = nil) -> URLResponse {
            var h = ["Content-Type": "application/octet-stream"]
            if let length { h["Content-Length"] = length }
            if let disposition { h["Content-Disposition"] = disposition }
            return HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!
        }
        let file = "https://contoso.sharepoint.com/sites/x/deck.zip"
        XCTAssertEqual(FrameHost.responsePolicy(r(file), mainFrame: true, canShow: false), .download, "control: a real file")
        XCTAssertEqual(FrameHost.responsePolicy(r(file), mainFrame: true, canShow: true), .allow, "a page loads")
        XCTAssertEqual(FrameHost.responsePolicy(r(file, length: "0"), mainFrame: true, canShow: false), .cancel, "empty")
        XCTAssertEqual(FrameHost.responsePolicy(r(file, status: 404), mainFrame: true, canShow: false), .cancel, "error page")
        XCTAssertEqual(FrameHost.responsePolicy(r(file), mainFrame: false, canShow: false), .cancel, "a frame's odd answer")
        XCTAssertEqual(FrameHost.responsePolicy(r(file, disposition: "attachment; filename=deck.zip"), mainFrame: false,
                                                canShow: false), .download, "a frame's declared attachment")
        XCTAssertEqual(FrameHost.responsePolicy(r("https://login.microsoftonline.com/common/oauth2/authorize"),
                                                mainFrame: true, canShow: false), .cancel, "sign-in answer")
    }
}
