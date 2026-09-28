// Files3Tests.swift — Files fixes (UI-SPEC §6.6): the menu-bar Delete
// (⌘⌫) needs the file table's focus; Delete / Move / Copy act on every
// selected item, Rename on one; the destination picker browses from
// the drive root; demo Copy / Move update the in-memory rows; timeline
// file chips re-measure their row.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class Files3Tests: XCTestCase {
    private func demoFiles() -> (WindowModel, FilesSection) {
        let app = AppState(args: ["--demo"])
        let m = WindowModel(graph: app, accountKey: "demo", options: LaunchOptions(args: ["--demo"]))
        let nav = Navigator(model: m)
        m.navigator = nav
        addTeardownBlock { _ = nav }
        app.unifiedFiles.showDemo(specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        nav.select(section: .files)
        return (m, m.provider(.files) as! FilesSection)
    }

    /// ⌘⌫ (menu bar, arg nil) is off without the table's focus (a search
    /// field's ⌘⌫ must delete text); the context menu's arg keeps it on.
    /// Two selected rows: Delete and Move act on both, Rename is off.
    func testDeleteNeedsTableFocusAndActsOnSelection() {
        let (m, f) = demoFiles()
        FilesSection.select(source: .recent, ids: ["demo-u-chat1", "demo-u-chat2"], m)
        XCTAssertEqual(f.items(forArg: nil, m).map(\.id).sorted(), ["demo-u-chat1", "demo-u-chat2"])
        XCTAssertFalse(f.validate(FilesCommands.delete, arg: nil, m).enabled, "no table focus")
        let ids = f.items(forArg: nil, m).map(\.id)
        let two = FilesSection.multiArg(ids)
        XCTAssertEqual(f.manageTargets(arg: two, m).count, 2)
        XCTAssertTrue(f.validate(FilesCommands.delete, arg: two, m).enabled)
        XCTAssertTrue(f.validate(FilesCommands.moveTo, arg: two, m).enabled, "same drive")
        XCTAssertFalse(f.validate(FilesCommands.rename, arg: two, m).enabled)
        XCTAssertTrue(f.validate(FilesCommands.rename, arg: ids[0], m).enabled, "control: one item")
        XCTAssertEqual(f.item(two, m)?.id, ids[0])
    }

    /// The picker opens at the drive root (a destination itself), lists
    /// subfolders by name without the moved items, and drills in / back.
    func testFolderPickerBrowsesFromRoot() {
        let p = FolderPickerStore(driveID: "d1", rootName: "OneDrive", excluding: ["demo-folder-3"], demo: true)
        XCTAssertEqual(p.current.itemID, FolderPickerStore.rootID)
        XCTAssertEqual(p.folders.map(\.name), ["Design Reviews", "Documents"])
        p.enter(p.folders[1])
        XCTAssertEqual(p.path.map(\.name), ["OneDrive", "Documents"])
        XCTAssertEqual(p.folders.map(\.name), ["Contracts", "Reports"])
        p.goTo(index: 0)
        XCTAssertEqual(p.current.name, "OneDrive")
        XCTAssertEqual(p.folders.count, 2)
    }

    /// Demo Copy adds "Name copy.ext" (then "copy 2") on the drive leg
    /// in the target; demo Move updates the flat index row in place.
    func testDemoCopyAndMoveUpdateIndex() {
        let index = UnifiedFilesStore()
        index.showDemo(specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        let n = index.rows.count
        let pdf = index.rows.first { $0.file.id == "demo-u-chat1" }!
        index.copy(pdf, toFolder: "demo-folder-3", folderName: "Archive")
        index.copy(pdf, toFolder: "demo-folder-3", folderName: "Archive")
        XCTAssertEqual(index.rows.count, n + 2)
        let copies = index.rows.filter { $0.file.name.hasPrefix("onboarding-mocks copy") }
        XCTAssertEqual(Set(copies.map(\.file.name)), ["onboarding-mocks copy.pdf", "onboarding-mocks copy 2.pdf"])
        XCTAssertTrue(copies.allSatisfy { $0.source == .drive && $0.sourceName == "Archive" })
        let drive = index.rows.first { $0.file.id == "demo-u-drive1" }!
        index.move(drive, toFolder: "root", folderName: "OneDrive")
        index.move(index.rows.first { $0.file.id == "demo-u-drive1" }!, toFolder: "demo-folder-1", folderName: "Documents")
        let moved = index.rows.first { $0.file.id == "demo-u-drive1" }
        XCTAssertEqual(moved?.sourceName, "Documents")
        XCTAssertNotEqual(moved?.file.modified, drive.file.modified)
        XCTAssertEqual(SharedFilesStore.copyName("Notes", taken: ["Notes copy"]), "Notes copy 2")
    }

    /// A chip resolving (the conversation's files loaded) changes the
    /// row's revision, so the timeline re-measures that row.
    func testFileChipsChangeRowRevision() {
        let file = DemoData.sharedFiles(for: DemoData.docsID)[0]
        let docs = InlineDocs.resolve(refs: ["doc-attach-1"], files: [file])
        XCTAssertEqual(docs.map(\.name), ["onboarding-mocks.pdf"])
        let base = MessageRowData.extraRevision(send: .none, receipt: .none, translation: nil, pinned: false, saved: false)
        XCTAssertNotEqual(base, MessageRowData.extraRevision(send: .none, receipt: .none, translation: nil,
                                                             pinned: false, saved: false, docs: docs))
    }
}
