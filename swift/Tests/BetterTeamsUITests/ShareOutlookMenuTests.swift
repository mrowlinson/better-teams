// ShareOutlookMenuTests — SHAREOUTLOOK R1: the Share to Outlook…
// message action validates on the keyboard-selected message and
// performs (presents the share sheet). Demo conv, no live network,
// windows are never shown. (The menu-bar catalog guard is untouched:
// the command carries no menu placement until the owner approves the
// guard edit for Conversation-menu placement.)
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ShareOutlookMenuTests: XCTestCase {
    private func msg(_ id: String, sender: String = "Megan Harper", own: Bool = false) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: "2026-11-18T10:00:00.0000000",
                    content: "Hello \(id)", isOwn: own)
    }

    private func harness() throws ->
        (model: WindowModel, nav: Navigator, section: ChatSection, actions: TimelineActions)
    {
        let (app, model, nav) = GuardSupport.demoModel()
        app.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        model.navigator?.select(section: .chat)
        model.navigator?.select(SectionSelection(id: "19:peer"), in: .chat)
        let conv = model.graph.conv
        conv.showDemo(chatID: "19:peer", chatName: "Ava Lindqvist",
                      messages: [msg("m1"), msg("m2")])
        let services = ConversationServices.of(model)
        let actions = TimelineActions(conv: conv, model: model, services: services)
        services.messageActions = actions
        actions.keyboard.select(chatID: "19:peer", messageID: "m2")
        let section = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        return (model, nav, section, actions)
    }

    func testShareOutlookValidatesOnTheSelection() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {}; withExtendedLifetime(h.actions) {} }
        XCTAssertTrue(h.section.validate(ChatCommands.shareOutlook, arg: nil, h.model).enabled)
    }

    func testShareOutlookNeedsTheSelection() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {}; withExtendedLifetime(h.actions) {} }
        let services = ConversationServices.of(h.model)
        services.messageActions?.keyboard.clear()
        XCTAssertFalse(h.section.validate(ChatCommands.shareOutlook, arg: nil, h.model).enabled)
        XCTAssertFalse(h.section.perform(ChatCommands.shareOutlook, arg: nil, h.model))
    }

    func testShareOutlookPerforms() throws {
        let h = try harness()
        defer { withExtendedLifetime(h.nav) {}; withExtendedLifetime(h.actions) {} }
        XCTAssertTrue(h.section.perform(ChatCommands.shareOutlook, arg: nil, h.model))
    }

    func testPrefillReachesTheSheet() {
        let d = ShareOutlookDraft.prefill(from: msg("m9", sender: "Megan Harper"))
        XCTAssertEqual(d.subject, "Message from Megan Harper")
        XCTAssertTrue(d.body.contains("Hello m9"))
        XCTAssertFalse(d.canSend, "To starts empty — the user types it")
    }
}
