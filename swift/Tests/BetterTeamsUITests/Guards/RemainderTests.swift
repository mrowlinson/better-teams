// RemainderTests — C8d: Undo Delete, Read Aloud, feed search, and
// settings search. Pure matchers plus validate/perform through the
// real paths (demo conv/stores, no live, no audio, no windows).
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class RemainderTests: XCTestCase {
    // MARK: harness

    private func chat() throws -> (model: WindowModel, nav: Navigator, conv: ConversationStore) {
        let (app, model, nav) = GuardSupport.demoModel()
        app.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        model.navigator?.select(section: .chat)
        model.navigator?.select(SectionSelection(id: "19:peer"), in: .chat)
        let conv = model.graph.conv
        conv.showDemo(chatID: "19:peer", chatName: "Ava Lindqvist", messages: [
            ChatMessage(id: "m1", sender: "Megan Harper", timestamp: "2026-11-17T10:00:00.0000000",
                        content: "Hello there", isOwn: false),
            ChatMessage(id: "m2", sender: "Me", timestamp: "2026-11-17T10:01:00.0000000",
                        content: "On my way", isOwn: true),
        ])
        return (model, nav, conv)
    }

    // MARK: Undo Delete

    func testUndoDeleteRestoresTheDraft() throws {
        let h = try chat()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, _, conv) = (h.model, h.nav, h.conv)
        let wc = ShellWindowController(graph: model.graph, options: LaunchOptions(args: ["--demo", "--evidence"]))
        wc.showShell()
        addTeardownBlock { @MainActor in wc.close() }
        XCTAssertFalse(wc.validate(ShellCommand.undoDelete).enabled, "nothing deleted yet")
        conv.deleteMessage(id: "m2")
        XCTAssertTrue(wc.validate(ShellCommand.undoDelete).enabled)
        wc.perform(ShellCommand.undoDelete, arg: nil)
        XCTAssertEqual(ConversationServices.of(wc.model).composer.draft("19:peer"), "On my way")
        XCTAssertFalse(wc.validate(ShellCommand.undoDelete).enabled, "one undo per delete")
        XCTAssertTrue(TestDisplayGuard.windowsOnDisplay().isEmpty)
    }

    func testUndoDeleteTakesTheStoreDraft() throws {
        let h = try chat()
        defer { withExtendedLifetime(h.nav) {} }
        h.conv.deleteMessage(id: "m2")
        let d = h.conv.takeUndoDelete()
        XCTAssertEqual(d?.chatID, "19:peer")
        XCTAssertEqual(d?.text, "On my way")
        XCTAssertNil(h.conv.takeUndoDelete(), "consumed")
    }

    // MARK: Read Aloud

    func testReadAloudSpeaksTheSelection() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        _ = app
        app.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        model.navigator?.select(section: .chat)
        model.navigator?.select(SectionSelection(id: "19:peer"), in: .chat)
        let conv = model.graph.conv
        conv.showDemo(chatID: "19:peer", chatName: "Ava Lindqvist", messages: [
            ChatMessage(id: "m1", sender: "Megan Harper", timestamp: "2026-11-17T10:00:00.0000000",
                        content: "Hello there", isOwn: false),
        ])
        let services = ConversationServices.of(model)
        let actions = TimelineActions(conv: conv, model: model, services: services)
        services.messageActions = actions
        let section = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        XCTAssertFalse(section.validate(ChatCommands.speakStart, arg: nil, model).enabled)
        actions.keyboard.select(chatID: "19:peer", messageID: "m1")
        XCTAssertTrue(section.validate(ChatCommands.speakStart, arg: nil, model).enabled)
        var heard: [String] = []
        SpeechReader.testHook = { heard.append($0) }
        defer {
            SpeechReader.testHook = nil
            SpeechReader.stop()
        }
        XCTAssertTrue(section.perform(ChatCommands.speakStart, arg: nil, model))
        XCTAssertEqual(heard, ["Hello there"])
        XCTAssertTrue(section.validate(ChatCommands.speakStop, arg: nil, model).enabled)
        XCTAssertTrue(section.perform(ChatCommands.speakStop, arg: nil, model))
        XCTAssertFalse(section.validate(ChatCommands.speakStop, arg: nil, model).enabled)
    }

    // MARK: feed search (ACT-04)

    private func feedRows() -> [ActivityRowModel] {
        let items = [
            ActivityItem(kind: .mention, chatID: "c1", actor: "Megan Harper", chatName: "Launch",
                         snippet: "please review the deck", at: 1, reviewed: false),
            ActivityItem(kind: .reply, chatID: "c2", actor: "Marco Chen", chatName: "Launch",
                         snippet: "looks good to me", at: 2, reviewed: false),
            ActivityItem(kind: .missedCall, chatID: "c3", actor: "Priya Nair", chatName: "",
                         snippet: "", at: 3, reviewed: false),
        ]
        return ActivityRowModel.rows(items, saved: [], filter: .all, place: { _ in "Launch" })
    }

    func testFeedSearchMatchesPersonHeadlineSnippetKind() {
        let rows = feedRows()
        XCTAssertEqual(ActivityRowModel.matching(rows, query: "").count, 3)
        XCTAssertEqual(ActivityRowModel.matching(rows, query: "harper").count, 1)
        XCTAssertEqual(ActivityRowModel.matching(rows, query: "DECK").count, 1, "case-insensitive")
        XCTAssertEqual(ActivityRowModel.matching(rows, query: "missed call").count, 1, "kind matches")
        XCTAssertEqual(ActivityRowModel.matching(rows, query: "replied").count, 1, "headline matches")
        XCTAssertTrue(ActivityRowModel.matching(rows, query: "zzz").isEmpty)
    }

    // MARK: settings search (SET-13)

    func testSettingsSearchFindsPanes() {
        XCTAssertEqual(SettingsSearch.matching("").count, 9, "every pane but Search itself")
        XCTAssertEqual(SettingsSearch.matching("mic").map(\.pane), ["calls"])
        XCTAssertEqual(SettingsSearch.matching("push talk").map(\.pane), ["calls"])
        XCTAssertEqual(SettingsSearch.matching("quiet hours").map(\.pane), ["notifications"])
        XCTAssertEqual(SettingsSearch.matching("TEXT size").map(\.pane), ["appearance"])
        XCTAssertTrue(SettingsSearch.matching("zzz").isEmpty)
    }
}
