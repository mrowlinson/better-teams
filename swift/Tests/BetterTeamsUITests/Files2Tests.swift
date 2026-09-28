// Files2Tests.swift — Files leftovers (UI-SPEC §6.6): demo Rename /
// Move / Delete act on the in-memory rows, searching inside Files starts
// in the Files scope, timeline image saves never overwrite.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class Files2Tests: XCTestCase {
    /// Demo manage ops: rename keeps the row's leg, delete drops it
    /// (index); move drops it from a folder listing.
    func testDemoManageActsOnMemoryRows() {
        let index = UnifiedFilesStore()
        index.showDemo(specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        let chan = index.rows.first { $0.file.id == "demo-u-chan1" }!
        index.rename(chan, to: "launch-checklist-v2.xlsx")
        let renamed = index.rows.first { $0.file.id == "demo-u-chan1" }
        XCTAssertEqual(renamed?.file.name, "launch-checklist-v2.xlsx")
        XCTAssertEqual(renamed?.source, .channel)
        XCTAssertEqual(renamed?.sourceID, "demo-chan-general")
        index.delete(renamed!)
        XCTAssertNil(index.rows.first { $0.file.id == "demo-u-chan1" })
        XCTAssertEqual(index.rows.count, DemoData.unifiedDemoRows().count - 1)

        let library = SharedFilesStore()
        library.showDemo(chatID: "demo-chan-general", files: DemoData.sharedFiles(for: "demo-chan-general"))
        let file = library.files[0]
        let dest = DemoData.fileFolders(driveID: file.drive_id!)[0]
        library.move(file, toFolder: dest.itemID)
        XCTAssertFalse(library.files.contains { $0.id == file.id })
    }

    /// §6.6: searching inside Files uses the Files scope; elsewhere All.
    func testSearchInFilesStartsInFilesScope() {
        XCTAssertEqual(Navigator.initialScope(for: .files), .files)
        XCTAssertEqual(Navigator.initialScope(for: .chat), .all)
    }

    /// Image saves: .png name from the alt text, Finder-style " 2"
    /// suffix instead of overwriting.
    func testImageSaveNamesNeverOverwrite() {
        XCTAssertEqual(ImageSave.filename(alt: ""), "Image.png")
        XCTAssertEqual(ImageSave.filename(alt: "image"), "Image.png")
        XCTAssertEqual(ImageSave.filename(alt: "floor/plan.jpg"), "floor_plan.png")
        let dir = URL(fileURLWithPath: "/d")
        let taken: Set<String> = ["/d/Image.png", "/d/Image 2.png"]
        XCTAssertEqual(ImageSave.uniqueDestination(dir: dir, name: "Image.png") { taken.contains($0) }.path,
                       "/d/Image 3.png")
    }
}
