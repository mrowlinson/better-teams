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

    /// New Folder: catalog presence (title, Finder shortcut, menu +
    /// toolbar + context-menu placement) and the demo create flow
    /// (appears in the listing, blank names no-op).
    func testNewFolderCommandInCatalog() {
        let cmd = CommandCatalog.command(FilesCommands.newFolder)
        XCTAssertNotNil(cmd)
        XCTAssertTrue(cmd?.title.hasPrefix("New Folder") == true)
        XCTAssertEqual(cmd?.symbol, "folder.badge.plus")
        // Shift-Command-N: no clash with New Chat (Command-N).
        XCTAssertEqual(cmd?.key, "n")
        XCTAssertTrue(cmd?.modifiers.contains(.shift) == true)
        XCTAssertNotEqual(cmd?.shortcut, CommandCatalog.command("chat.new")?.shortcut)
        XCTAssertEqual(cmd?.menu?.group, 2)
        XCTAssertEqual(cmd?.toolbar, .detail)
        XCTAssertTrue(FilesCommands.contextGroups.flatMap { $0 }.contains(FilesCommands.newFolder))
        XCTAssertTrue(FilesSection().allToolbarItems.contains(FilesCommands.newFolder))
        XCTAssertEqual(FilesCommands.newFolderSheet, "newFolder")
    }

    func testDemoMkdirAppearsInListings() {
        let index = UnifiedFilesStore()
        index.showDemo(specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        let before = index.rows.count
        index.mkdir("Plans")
        XCTAssertEqual(index.rows.count, before + 1)
        let folder = index.rows.first { $0.file.name == "Plans" }
        XCTAssertNotNil(folder)
        XCTAssertTrue(folder?.file.isFolder == true)
        XCTAssertEqual(folder?.source, .drive)
        index.mkdir("   ")
        XCTAssertEqual(index.rows.count, before + 1)
        index.mkdir("Plans")
        XCTAssertEqual(index.rows.filter { $0.file.name == "Plans" }.count, 2)

        let library = SharedFilesStore()
        library.showDemo(chatID: "demo-chan-general", files: DemoData.sharedFiles(for: "demo-chan-general"))
        let filesBefore = library.files.count
        library.mkdir("Sketches")
        XCTAssertEqual(library.files.count, filesBefore + 1)
        let created = library.files.first { $0.name == "Sketches" }
        XCTAssertNotNil(created)
        XCTAssertTrue(created?.isFolder == true)
        library.mkdir("")
        XCTAssertEqual(library.files.count, filesBefore + 1)
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
