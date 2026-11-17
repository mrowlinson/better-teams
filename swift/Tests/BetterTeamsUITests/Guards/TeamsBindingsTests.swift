// TeamsBindingsTests — C8b: the Teams binding set. Data pins every new
// key equivalent; behavior drives the real validate/perform paths with
// the demo core (no live calls). Windows are never shown.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class TeamsBindingsTests: XCTestCase {
    // MARK: keys

    func testTeamsBindingKeys() {
        func key(_ id: CommandID) -> (String, NSEvent.ModifierFlags)? {
            guard let c = CommandCatalog.command(id) else { return nil }
            return (c.key, c.modifiers)
        }
        XCTAssertEqual(key(CallCommands.accept)?.0, "a")
        XCTAssertEqual(key(CallCommands.accept)?.1, [.command, .shift])
        XCTAssertEqual(key(CallCommands.decline)?.0, "d")
        XCTAssertEqual(key(CallCommands.hand)?.0, "k")
        XCTAssertEqual(key(CallCommands.hand)?.1, [.command, .shift])
        XCTAssertEqual(key(CallCommands.pushToTalk)?.0, " ")
        XCTAssertEqual(key(CallCommands.pushToTalk)?.1, [.option])
        XCTAssertEqual(key(CallCommands.showChat)?.0, "r")
        XCTAssertEqual(key(CallCommands.showChat)?.1, [.command, .shift])
        XCTAssertEqual(key(ActivityCommands.markAllRead)?.0, "\u{1b}")
        XCTAssertEqual(key(ActivityCommands.markAllRead)?.1, [.shift])
        XCTAssertEqual(key(CalendarCommands.newMeeting)?.0, "n")
        XCTAssertEqual(key(CalendarCommands.newMeeting)?.1, [.command, .option, .shift])
        XCTAssertEqual(key(ChatCommands.compose)?.0, "x")
        XCTAssertEqual(key(ChatCommands.compose)?.1, [.command, .shift])
    }

    // MARK: accept / decline

    func testAcceptDeclineNeedARing() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let section = try XCTUnwrap(model.provider(.call) as? CallSection)
        XCTAssertFalse(section.validate(CallCommands.accept, arg: nil, model).enabled)
        XCTAssertFalse(section.perform(CallCommands.accept, arg: nil, model))
        XCTAssertFalse(section.validate(CallCommands.decline, arg: nil, model).enabled)
        XCTAssertFalse(section.perform(CallCommands.decline, arg: nil, model))
    }

    func testAcceptAnswersTheRing() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        app.call.seedDemo(state: "incoming")
        let section = try XCTUnwrap(model.provider(.call) as? CallSection)
        XCTAssertTrue(section.validate(CallCommands.accept, arg: nil, model).enabled)
        XCTAssertTrue(section.validate(CallCommands.decline, arg: nil, model).enabled)
        XCTAssertTrue(section.perform(CallCommands.accept, arg: nil, model))
        XCTAssertEqual(app.call.call?.state, "connected")
        XCTAssertEqual(app.call.lastAction, "demo:accept-live")
    }

    func testDeclineEndsTheRing() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        app.call.seedDemo(state: "incoming")
        let section = try XCTUnwrap(model.provider(.call) as? CallSection)
        XCTAssertTrue(section.perform(CallCommands.decline, arg: nil, model))
        XCTAssertNil(app.call.call)
    }

    // MARK: hand

    func testHandTogglesLocally() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let store = CallStore(demo: true)
        let session = CallSession(kind: .person(name: "Ava Lindqvist", thread: "19:peer"),
                                  presentation: .mainWindow, model: model, store: store)
        model.call = session
        let section = try XCTUnwrap(model.provider(.call) as? CallSection)
        XCTAssertEqual(section.validate(CallCommands.hand, arg: nil, model).title, "Raise Hand")
        XCTAssertTrue(section.perform(CallCommands.hand, arg: nil, model))
        XCTAssertTrue(session.handRaised)
        XCTAssertEqual(section.validate(CallCommands.hand, arg: nil, model).title, "Lower Hand")
        model.call = nil
        _ = app
    }

    // MARK: push-to-talk

    func testPushToTalkNeedsTheSetting() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let old = AppSettings.shared.pushToTalk
        AppSettings.shared.pushToTalk = false
        defer { AppSettings.shared.pushToTalk = old }
        let store = CallStore(demo: true)
        let session = CallSession(kind: .person(name: "Ava Lindqvist", thread: "19:peer"),
                                  presentation: .mainWindow, model: model, store: store)
        model.call = session
        let section = try XCTUnwrap(model.provider(.call) as? CallSection)
        XCTAssertFalse(section.validate(CallCommands.pushToTalk, arg: nil, model).enabled)
        model.call = nil
    }

    func testPushToTalkHoldRestoresMute() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let old = AppSettings.shared.pushToTalk
        AppSettings.shared.pushToTalk = true
        defer { AppSettings.shared.pushToTalk = old }
        let store = CallStore(demo: true)
        store.setMuted(true)
        let session = CallSession(kind: .person(name: "Ava Lindqvist", thread: "19:peer"),
                                  presentation: .mainWindow, model: model, store: store)
        model.call = session
        let section = try XCTUnwrap(model.provider(.call) as? CallSection)
        XCTAssertTrue(section.validate(CallCommands.pushToTalk, arg: nil, model).enabled)
        session.setPushToTalkHeld(true)
        XCTAssertTrue(session.pushToTalkHeld)
        XCTAssertFalse(store.muted, "the hold opens the mic")
        session.setPushToTalkHeld(false)
        XCTAssertFalse(session.pushToTalkHeld)
        XCTAssertTrue(store.muted, "release restores the mute")
        model.call = nil
    }

    func testTalkBurstOpensTheMic() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let old = AppSettings.shared.pushToTalk
        AppSettings.shared.pushToTalk = true
        defer { AppSettings.shared.pushToTalk = old }
        let store = CallStore(demo: true)
        store.setMuted(true)
        let session = CallSession(kind: .person(name: "Ava Lindqvist", thread: "19:peer"),
                                  presentation: .mainWindow, model: model, store: store)
        model.call = session
        let section = try XCTUnwrap(model.provider(.call) as? CallSection)
        XCTAssertTrue(section.perform(CallCommands.pushToTalk, arg: nil, model))
        XCTAssertTrue(session.pushToTalkHeld)
        model.call = nil
    }

    // MARK: compose

    func testGoToComposeBoxNeedsAConversation() throws {
        let (_, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let section = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        model.navigator?.select(section: .chat)
        model.navigator?.select(nil, in: .chat)
        XCTAssertFalse(section.validate(ChatCommands.compose, arg: nil, model).enabled)
    }

    func testGoToComposeBoxFocusesTheComposer() throws {
        let (app, model, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        app.chats.insertLocally(ChatItem(chatId: "19:peer", name: "Ava Lindqvist"))
        model.navigator?.select(section: .chat)
        model.navigator?.select(SectionSelection(id: "19:peer"), in: .chat)
        let section = try XCTUnwrap(model.provider(.chat) as? ChatSection)
        XCTAssertTrue(section.validate(ChatCommands.compose, arg: nil, model).enabled)
        let services = ConversationServices.of(model)
        let before = services.composer.focusRequest
        XCTAssertTrue(section.perform(ChatCommands.compose, arg: nil, model))
        XCTAssertEqual(services.composer.focusRequest, before + 1)
    }
}
