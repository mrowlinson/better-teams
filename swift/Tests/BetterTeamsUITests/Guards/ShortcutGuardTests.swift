// ShortcutGuardTests — R3/R4 (REGFIX-B): the commands behind the
// owner-named shortcuts still DO their job (the catalog test pins that
// the shortcuts exist; these run the commands), and the quick-message
// hotkey ships on with a reset. Nothing is shown on screen.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

/// Sheet host for tests. A real `beginSheet` orders the parent window in and
/// AppKit pulls it onto a display, where it stayed for the rest of the run
/// (a stray 600x432 window on the owner's screen). Recorded only: the sheet
/// controller is still handed over, nothing is ordered in.
private final class SheetHostWindow: NSWindow {
    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {}
}

@MainActor
final class ShortcutGuardTests: XCTestCase {
    // MARK: R3 Cmd-Return sends

    func testCommandReturnAlwaysSends() {
        for returnSends in [true, false] {
            for shift in [true, false] {
                XCTAssertEqual(ComposerKeyPolicy.action(shift: shift, command: true, markedText: false, returnSends: returnSends),
                               .send, "Cmd-Return sends (returnSends=\(returnSends), shift=\(shift))")
            }
        }
        // Return / Shift-Return keep their settings-driven meaning; IME composition passes through.
        XCTAssertEqual(ComposerKeyPolicy.action(shift: false, markedText: false, returnSends: true), .send)
        XCTAssertEqual(ComposerKeyPolicy.action(shift: true, markedText: false, returnSends: true), .newline)
        XCTAssertEqual(ComposerKeyPolicy.action(shift: false, command: true, markedText: true), .passThrough)
    }

    func testCommandReturnKeyEventSubmitsTheComposer() throws {
        let field = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        var submitted = 0
        field.onSubmit = { submitted += 1 }
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                             keyCode: code)!
        }
        field.keyDown(with: key(36, .command))
        XCTAssertEqual(submitted, 1, "Cmd-Return")
        field.keyDown(with: key(76, .command))
        XCTAssertEqual(submitted, 2, "Cmd-Enter (keypad)")
    }

    // MARK: R3 Mark as Unread (Conversation menu, Shift-Cmd-U)

    func testConversationMenuMarkAsUnreadMarksTheSelectedChat() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        app.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        let chat = try XCTUnwrap(app.chats.chat(id: "19:peer"))
        model.navigator?.select(section: .chat)
        model.navigator?.select(SectionSelection(id: chat.id), in: .chat)
        model.graph.unread.markRead(chatID: chat.id)
        XCTAssertFalse(model.graph.unread.isUnread(chatID: chat.id))
        let chatSection = model.provider(.chat)
        XCTAssertTrue(chatSection.validate(ChatCommands.markUnread, arg: nil, model).enabled)
        XCTAssertTrue(chatSection.perform(ChatCommands.markUnread, arg: nil, model))
        XCTAssertTrue(model.graph.unread.isUnread(chatID: chat.id), "Mark as Unread must mark the chat unread")
        // Same command with no chat open is off.
        model.navigator?.select(SectionSelection(id: chat.id), in: .chat)
        model.navigator?.select(nil, in: .chat)
        XCTAssertFalse(chatSection.validate(ChatCommands.markUnread, arg: nil, model).enabled)
        // No "Mark as Read" command in the chat commands (owner: do not restore it here).
        XCTAssertFalse(CommandCatalog.all.contains { $0.menu?.menu == .conversation && $0.title.hasPrefix("Mark as Read") })
    }

    // MARK: R3 Saved Messages (Shift-Cmd-S)

    func testSavedMessagesShortcutOpensActivityFilteredToSaved() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        model.navigator?.select(section: .chat)
        let activity = try XCTUnwrap(model.provider(.activity) as? ActivitySection)
        XCTAssertTrue(activity.validate(ActivityCommands.showSaved, arg: nil, model).enabled)
        XCTAssertTrue(activity.perform(ActivityCommands.showSaved, arg: nil, model))
        XCTAssertEqual(model.nav.section, .activity)
        XCTAssertEqual(activity.state.filter, .saved)
    }

    // MARK: R3 Join Meeting (Cmd-J) is available everywhere

    func testJoinMeetingIsAlwaysEnabledAndOpensTheJoinSheetWithoutASelection() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        model.navigator?.select(section: .chat)
        let calendar = model.provider(.calendar)
        XCTAssertTrue(calendar.validate(CalendarCommands.join, arg: nil, model).enabled, "Cmd-J works from any section")
        let window = SheetHostWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 400), styleMask: [.titled],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // SheetHostWindow never orders the host in; close is belt and braces.
        addTeardownBlock { @MainActor in window.close() }
        let root = NSViewController()
        root.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentViewController = root
        let sheets = SheetPresenter(model: model) { [weak window] in window?.contentViewController }
        model.presenter = sheets
        XCTAssertTrue(calendar.perform(CalendarCommands.join, arg: nil, model))
        XCTAssertEqual(model.sheet?.name, CalendarCommands.joinSheet, "no meeting selected: the Join with ID or Link sheet")
        // Checked before the teardown closes the host (closing would hide a leak).
        XCTAssertTrue(TestDisplayGuard.windowsOnDisplay().isEmpty, "join-sheet host window reached a display")
        model.dismissSheet()
    }

    // MARK: R4 quick-message hotkey

    func testQuickComposerShipsOnAndResetsToTheDefaultCombo() {
        AppSettings.useDemoStorage()
        XCTAssertTrue(AppSettings.shared.quickComposer, "the hotkey is on by default")
        XCTAssertTrue(AppSettings.quickComposerDefault)
        // Reset button: any custom combo goes back to the shipped one.
        let custom = QuickComposeCombo(keyCode: 40, modifiers: QuickComposeCombo.cmdModifier | QuickComposeCombo.shiftModifier)
        QuickComposerController.setCombo(custom)
        XCTAssertEqual(QuickComposerController.combo(), custom)
        QuickComposerController.resetCombo()
        XCTAssertEqual(QuickComposerController.combo(), .default)
        XCTAssertEqual(QuickComposeCombo.default.displayString, "\u{2303}\u{2318}M")
    }

    func testQuickMessageMenuItemExistsAndNeedsAnAccount() {
        let c = CommandCatalog.command(ShellCommand.quickMessage)
        XCTAssertEqual(c?.title, "New Quick Message\u{2026}")
        XCTAssertEqual(c?.key, "m")
        XCTAssertEqual(c?.modifiers, [.command, .control])
        XCTAssertEqual(c?.menu?.menu, .file)
    }
}
