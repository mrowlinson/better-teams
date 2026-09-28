// FolderBrowsingTests.swift — om-i5-folders lane: folder flag + children envelope.
import XCTest

@testable import OstMacCore

@MainActor
final class FolderBrowsingTests: XCTestCase {
    func testOldPayloadWithoutFolderFlagDecodesAsFile() throws {
        let json = """
        {"ok":true,"chat_id":"19:x","files":[
          {"id":"i1","name":"deck.pdf","size":48211}
        ]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(SharedFilesResponse.self, from: json)
        XCTAssertEqual(resp.files.count, 1)
        XCTAssertFalse(resp.files[0].isFolder)
    }

    func testFolderItemDecodesIsFolder() throws {
        let json = """
        {"ok":true,"chat_id":"19:x","files":[
          {"id":"dir1","name":"Design","size":0,"drive_id":"D1",
           "is_folder":true,"mime":null,"download_url":null}
        ]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(SharedFilesResponse.self, from: json)
        XCTAssertTrue(resp.files[0].isFolder)
        XCTAssertEqual(resp.files[0].drive_id, "D1")
    }

    func testChildrenEnvelopeDecodesFilesAndFolders() throws {
        let json = """
        {"ok":true,"drive_id":"D1","item_id":"root",
         "files":[
           {"id":"dir1","name":"Design","size":0,"is_folder":true},
           {"id":"f1","name":"a.pdf","size":12,"is_folder":false}
         ]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(SharedFileChildrenResponse.self, from: json)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.drive_id, "D1")
        XCTAssertEqual(resp.item_id, "root")
        XCTAssertEqual(resp.files.count, 2)
        XCTAssertTrue(resp.files[0].isFolder)
        XCTAssertFalse(resp.files[1].isFolder)
    }

    func testInitDefaultsToFile() {
        XCTAssertFalse(SharedFile(id: "f1", name: "a").isFolder)
        XCTAssertTrue(SharedFile(id: "d1", name: "D", is_folder: true).isFolder)
    }
}
