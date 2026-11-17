// ShortcutsHelpTests — C8a: the Help window's topics and the Keyboard
// Shortcuts table. The table is generated from CommandCatalog, so these
// pin that every binding is listed (with the ⌘E Teams note) and that
// Help ▸ items validate. Windows are never shown here (demo verifies).
import AppKit
import XCTest

@testable import BetterTeamsUI

@MainActor
final class ShortcutsHelpTests: XCTestCase {
    func testEveryBindingIsListedOnce() {
        let keyed = CommandCatalog.all.filter { !$0.key.isEmpty }
        XCTAssertFalse(keyed.isEmpty)
        var listed = 0
        for section in HelpContent.shortcutSections() {
            listed += section.rows.filter { !$0.keys.isEmpty }.count
        }
        XCTAssertEqual(listed, keyed.count, "every keyed command appears once")
    }

    func testListedKeysMatchTheCatalog() {
        var byTitle: [String: String] = [:]
        for s in HelpContent.shortcutSections() {
            for r in s.rows { byTitle[r.title] = r.keys }
        }
        XCTAssertEqual(byTitle["Use Selection for Find"], "⌘E")
        XCTAssertEqual(byTitle["Search"], "⌥⌘F")
        XCTAssertEqual(byTitle["Keyboard Shortcuts"], "⇧⌘?")
        XCTAssertEqual(byTitle["Better Teams Help"], "⌘?")
    }

    func testTeamsDifferencesAreDocumented() {
        var notes: [String: String] = [:]
        for s in HelpContent.shortcutSections() {
            for r in s.rows { if let n = r.note { notes[r.title] = n } }
        }
        let find = notes["Use Selection for Find"] ?? ""
        XCTAssertTrue(find.contains("⌘E"), "names the Teams search key")
        XCTAssertTrue(find.contains("⌥⌘F"), "points at this app's search")
    }

    func testShortcutDisplay() {
        XCTAssertEqual(ShortcutDisplay.string(key: "", modifiers: [.command]), "")
        XCTAssertEqual(ShortcutDisplay.string(key: "e", modifiers: [.command]), "⌘E")
        XCTAssertEqual(ShortcutDisplay.string(key: "?", modifiers: [.command, .shift]), "⇧⌘?")
        XCTAssertEqual(ShortcutDisplay.string(key: "\u{1b}", modifiers: [.shift]), "⇧Esc")
        XCTAssertEqual(ShortcutDisplay.string(key: " ", modifiers: [.option]), "⌥Space")
        XCTAssertEqual(ShortcutDisplay.string(
            key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [.command, .option]), "⌥⌘↓")
        XCTAssertEqual(ShortcutDisplay.string(key: "\u{8}", modifiers: [.command]), "⌘⌫")
    }

    func testSectionsHoldTheirOwnMenus() {
        let sections = HelpContent.shortcutSections()
        let file = sections.first { $0.menu == "File" }
        XCTAssertEqual(file?.rows.first?.title, "New Chat")
        XCTAssertTrue(file?.rows.contains { $0.title == "New Meeting…" && $0.keys == "⌥⇧⌘N" } == true)
        let conv = sections.first { $0.menu == "Conversation" }
        XCTAssertTrue(conv?.rows.contains { $0.title == "Reply" && $0.keys == "⌥⌘R" } == true)
        let call = sections.first { $0.menu == "Call" }
        XCTAssertTrue(call?.rows.contains { $0.title == "Accept Call" && $0.keys == "⇧⌘A" } == true)
        let edit = sections.first { $0.menu == "Edit" }
        XCTAssertTrue(edit?.rows.contains { $0.title == "Start Speaking" } == true)
        // Row ids are unique across the whole table (two commands share
        // the View ▸ Today title, so title alone is not an id).
        var seen: Set<String> = []
        for s in sections {
            for r in s.rows {
                XCTAssertTrue(seen.insert(r.id).inserted, "duplicate id: \(r.id)")
            }
        }
    }

    func testPlannedBindingsAreFootnoteOnly() {
        XCTAssertFalse(HelpContent.planned.isEmpty)
        XCTAssertTrue(HelpContent.planned.contains { $0.title == "Mark as Important" })
        // A planned binding has no catalog entry, so it can never fire.
        XCTAssertNil(CommandCatalog.command("message.important"))
        XCTAssertNil(CommandCatalog.command("teams.markImportant"))
    }

    func testHelpTopicsAreComplete() {
        XCTAssertFalse(HelpContent.topics.isEmpty)
        for t in HelpContent.topics {
            XCTAssertFalse(t.title.isEmpty, t.id)
            XCTAssertFalse(t.sections.isEmpty, t.id)
            for s in t.sections {
                XCTAssertFalse(s.heading.isEmpty, t.id)
                XCTAssertFalse(s.body.isEmpty, t.id)
            }
        }
        XCTAssertTrue(HelpContent.topics.contains { $0.id == "accessibility" })
    }

    func testHelpMenuItemsValidate() {
        let (app, _, _) = GuardSupport.demoModel()
        let wc = ShellWindowController(graph: app, options: LaunchOptions(args: ["--demo", "--evidence"]))
        wc.showShell() // off-display: validation answers only once the shell is installed
        addTeardownBlock { @MainActor in wc.close() }
        XCTAssertTrue(wc.validate(ShellCommand.help).enabled)
        XCTAssertTrue(wc.validate(ShellCommand.shortcuts).enabled)
        XCTAssertEqual(CommandCatalog.command(ShellCommand.shortcuts)?.menu?.menu, .help)
        XCTAssertTrue(TestDisplayGuard.windowsOnDisplay().isEmpty, "validating never shows a window")
    }
}
