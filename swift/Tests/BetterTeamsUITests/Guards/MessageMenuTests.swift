// MessageMenuTests — C8c: the Conversation message-half menu works on
// the keyboard-selected message. Pure step logic plus validate/perform
// through the real section and timeline paths (demo conv, no live).
// Windows are never shown.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class MessageMenuTests: XCTestCase {
    // MARK: step logic

    func testStepFromNothing() {
        XCTAssertEqual(KeyboardMessageSelection.nextID(in: ["a", "b"], current: nil, direction: 1), "a")
        XCTAssertEqual(KeyboardMessageSelection.nextID(in: ["a", "b"], current: nil, direction: -1), "b")
    }

    func testStepMovesAndClamps() {
        XCTAssertEqual(KeyboardMessageSelection.nextID(in: ["a", "b", "c"], current: "b", direction: 1), "c")
        XCTAssertEqual(KeyboardMessageSelection.nextID(in: ["a", "b", "c"], current: "b", direction: -1), "a")
        XCTAssertNil(KeyboardMessageSelection.nextID(in: ["a", "b"], current: "b", direction: 1), "end clamps")
        XCTAssertNil(KeyboardMessageSelection.nextID(in: ["a", "b"], current: "a", direction: -1), "start clamps")
        XCTAssertNil(KeyboardMessageSelection.nextID(in: [], current: nil, direction: 1))
        XCTAssertNil(KeyboardMessageSelection.nextID(in: ["a"], current: "a", direction: 0))
        XCTAssertEqual(KeyboardMessageSelection.nextID(in: ["a", "b"], current: "gone", direction: 1), "a")
    }

    func testSelectAndClear() {
        let k = KeyboardMessageSelection()
        var changes = 0
        k.onChange = { changes += 1 }
        k.select(chatID: "c", messageID: "m")
        XCTAssertEqual(changes, 1)
        k.select(chatID: "c", messageID: "m")
        XCTAssertEqual(changes, 1, "same selection is silent")
        k.clear()
        XCTAssertNil(k.selected)
        XCTAssertEqual(changes, 2)
        k.clear()
        XCTAssertEqual(changes, 2, "clearing nothing is silent")
    }

    // MARK: harness

    private func msg(_ id: String, sender: String = "Megan Harper", own: Bool = false,
                     deleted: Bool = false) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: "2026-11-17T10:00:00.0000000",
                    content: "Hello \(id)", isOwn: own, deleted: deleted)
    }

    /// An open demo chat with three messages, the middle one selected,
    /// and the harness pointed at the timeline's real actions. Callers
    /// keep `nav` alive for the test (the navigator is weak).
    private func harness(failed: Set<String> = []) throws ->
        (model: WindowModel, nav: Navigator, section: ChatSection, actions: TimelineActions, conv: ConversationStore)
    {
        let (app, model, nav) = GuardSupport.demoModel()
        app.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        model.navigator?.select(section: .chat)
        model.navigator?.select(SectionSelection(id: "19:peer"), in: .chat)
        let conv = model.graph.conv
        conv.showDemo(chatID: "19:peer", chatName: "Ava Lindqvist",
                      messages: [msg("m1"), msg("m2"), msg("m3", own: true)], failed: failed)
        let services = ConversationServices.of(model)
        let actions = TimelineActions(conv: conv, model: model, services: services)
        services.messageActions = actions
        actions.keyboard.select(chatID: "19:peer", messageID: "m2")
        let section = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        return (model, nav, section, actions, conv)
    }

    // MARK: validate

    func testMessageMenuValidatesOnTheSelection() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, actions, conv) = (h.model, h.section, h.actions, h.conv)
        for c in [ChatCommands.reply, ChatCommands.forward, ChatCommands.react,
                  ChatCommands.save, ChatCommands.pinMessage, ChatCommands.translate] {
            XCTAssertTrue(section.validate(c, arg: nil, model).enabled, "\(c)")
        }
    }

    func testMessageMenuNeedsASelection() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, actions, conv) = (h.model, h.section, h.actions, h.conv)
        actions.keyboard.clear()
        for c in [ChatCommands.reply, ChatCommands.forward, ChatCommands.react,
                  ChatCommands.save, ChatCommands.pinMessage, ChatCommands.translate] {
            XCTAssertFalse(section.validate(c, arg: nil, model).enabled, "\(c)")
            XCTAssertFalse(section.perform(c, arg: c == ChatCommands.react ? "👍" : nil, model), "\(c)")
        }
    }

    func testMessageMenuNeedsTheOpenConversation() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, actions, conv) = (h.model, h.section, h.actions, h.conv)
        actions.keyboard.select(chatID: "19:other", messageID: "m2")
        XCTAssertFalse(section.validate(ChatCommands.reply, arg: nil, model).enabled)
        // A selection whose message left the history is off too.
        actions.keyboard.select(chatID: "19:peer", messageID: "gone")
        XCTAssertFalse(section.validate(ChatCommands.reply, arg: nil, model).enabled)
    }

    func testFailedAndDeletedStayOff() throws {
        for failed in [Set(["m2"]), Set<String>()] {
            let h = try harness(failed: failed)
            defer { withExtendedLifetime(h.nav) {} }
            let (model, section, actions, _) = (h.model, h.section, h.actions, h.conv)
            if !failed.isEmpty {
                XCTAssertFalse(section.validate(ChatCommands.reply, arg: nil, model).enabled)
                continue
            }
            actions.keyboard.select(chatID: "19:peer", messageID: "m3")
            XCTAssertTrue(section.validate(ChatCommands.reply, arg: nil, model).enabled)
        }
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, _, _) = (h.model, h.section, h.actions, h.conv)
        model.graph.conv.showDemo(chatID: "19:peer", chatName: "Ava Lindqvist",
                                  messages: [msg("m1"), msg("m2", deleted: true), msg("m3", own: true)])
        XCTAssertFalse(section.validate(ChatCommands.reply, arg: nil, model).enabled,
                       "tombstones keep the context menu's own items only")
    }

    // MARK: perform

    func testReplyStartsAQuoteReply() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, _, conv) = (h.model, h.section, h.actions, h.conv)
        let services = ConversationServices.of(model)
        let before = services.composer.focusRequest
        XCTAssertTrue(section.perform(ChatCommands.reply, arg: nil, model))
        XCTAssertEqual(conv.replyTarget?.id, "m2")
        XCTAssertEqual(services.composer.focusRequest, before + 1)
    }

    func testReactAddsTheEmoji() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, _, conv) = (h.model, h.section, h.actions, h.conv)
        XCTAssertTrue(section.perform(ChatCommands.react, arg: "👍", model))
        XCTAssertTrue(conv.messages.first { $0.id == "m2" }?.reactions.contains { $0.emoji == "👍" } == true)
    }

    func testSaveToggles() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, _, _) = (h.model, h.section, h.actions, h.conv)
        XCTAssertTrue(section.perform(ChatCommands.save, arg: nil, model))
        XCTAssertTrue(model.graph.savedMessages.isSaved(chatID: "19:peer", messageID: "m2"))
        XCTAssertEqual(section.validate(ChatCommands.save, arg: nil, model).title, "Unsave")
        XCTAssertTrue(section.perform(ChatCommands.save, arg: nil, model))
        XCTAssertFalse(model.graph.savedMessages.isSaved(chatID: "19:peer", messageID: "m2"))
    }

    func testPinToggles() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, _, _) = (h.model, h.section, h.actions, h.conv)
        XCTAssertTrue(section.perform(ChatCommands.pinMessage, arg: nil, model))
        XCTAssertTrue(model.graph.pinnedMessages.isPinned(chatID: "19:peer", messageID: "m2"))
        XCTAssertEqual(section.validate(ChatCommands.pinMessage, arg: nil, model).title, "Unpin")
    }

    func testTranslatePerforms() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, _, _) = (h.model, h.section, h.actions, h.conv)
        XCTAssertTrue(section.validate(ChatCommands.translate, arg: nil, model).enabled)
        XCTAssertTrue(section.perform(ChatCommands.translate, arg: nil, model))
    }

    func testReactSubmenuListsQuickReactions() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, section, _, _) = (h.model, h.section, h.actions, h.conv)
        let items = section.submenuItems(ChatCommands.react, model)
        XCTAssertEqual(items.count, HoverToolbarRules.quickReactions.count + 1)
        XCTAssertEqual(items.last?.arg, "more")
        XCTAssertTrue(items.allSatisfy { !$0.title.isEmpty && !$0.arg.isEmpty })
    }

    // MARK: keyboard walk on a live timeline

    func testArrowsWalkTheTimeline() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {} }
        let (model, conv) = (h.model, h.conv)
        let vc = TimelineViewController(conv: conv, model: model)
        _ = vc.view
        let actions = ConversationServices.of(model).messageActions
        XCTAssertNotNil(actions, "the timeline registers its actions on load")
        actions?.keyboard.clear()
        XCTAssertTrue(vc.moveKeyboard(1))
        XCTAssertEqual(actions?.keyboard.messageID, "m1")
        XCTAssertTrue(vc.moveKeyboard(1))
        XCTAssertEqual(actions?.keyboard.messageID, "m2")
        XCTAssertTrue(vc.moveKeyboard(-1))
        XCTAssertEqual(actions?.keyboard.messageID, "m1")
        XCTAssertFalse(vc.moveKeyboard(-1), "the top clamps")
        XCTAssertTrue(vc.clearKeyboard())
        XCTAssertNil(actions?.keyboard.messageID)
        XCTAssertFalse(vc.clearKeyboard(), "clearing nothing reports false")
    }
}
