// ServerStateGuardTests — C6 SERVER-STATE: the logic behind the new
// Settings controls, driven directly (SwiftUI buttons are not
// inspectable under xctest — ChatSurfaceGuardTests precedent). Nothing
// is shown on screen. A control or copy change that breaks one of
// these must be made on purpose.
// - Priority Access toggle (chat Notifications menu + Settings section):
//   RulesStore isPriority/setPriority round-trip, orthogonal to levels,
//   surviving a rules.json reload; priority breaks DND/quiet only.
// - Privacy toggles (Chats Privacy section): PrivacyStore defaults on,
//   keys stable, gates drop the outbound signal.
// - Pin-for-all pane copy: the refused-pin sentence is stable.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ServerStateGuardTests: XCTestCase {
    // MARK: Priority Access toggle logic

    func testPriorityToggleRoundTripsThroughDemoApp() {
        let (app, _, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let rules = app.rules
        XCTAssertFalse(rules.isPriority(chatID: "demo-priority"))
        rules.setPriority(chatID: "demo-priority", priority: true)
        XCTAssertTrue(rules.isPriority(chatID: "demo-priority"))
        rules.setPriority(chatID: "demo-priority", priority: false)
        XCTAssertFalse(rules.isPriority(chatID: "demo-priority"))
    }

    func testPriorityStaysOutOfLevels() {
        let (app, _, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        let rules = app.rules
        rules.setLevel(chatID: "demo-level", level: .muted)
        rules.setPriority(chatID: "demo-level", priority: true)
        XCTAssertEqual(rules.level(chatID: "demo-level"), .muted)
        XCTAssertTrue(rules.isPriority(chatID: "demo-level"))
    }

    func testPriorityBreaksOnlyDNDAndQuiet() {
        var c = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        c.priorityChatIDs = ["19:p@thread.v2"]
        c.applyRules()
        let m = RealtimeMessage(
            chatID: "19:p@thread.v2", msgId: "m1", sender: "Megan",
            senderID: "8:orgid:megan", text: "hello",
            time: "2026-09-23T10:00:00Z", isEdit: false,
            messageType: "Text")
        for flag in [true, false] {
            let dnd = ChatFilter.decide(
                message: m, chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me",
                rules: c, dndActive: flag)
            let quiet = ChatFilter.decide(
                message: m, chatDisplayName: "Team Chat", ownerMRI: "8:orgid:me",
                rules: c, quietActive: flag)
            if flag {
                if case .notify = dnd {} else { XCTFail("priority breaks DND") }
                if case .notify = quiet {} else { XCTFail("priority breaks quiet") }
            } else {
                if case .notify = dnd {} else { XCTFail("plain message notifies") }
                if case .notify = quiet {} else { XCTFail("plain message notifies") }
            }
        }
    }

    // MARK: Privacy toggle logic

    func testPrivacyStoreDefaultsAndKeysAreStable() {
        XCTAssertEqual(PrivacyStore.receiptsKey, "privacy.sendReadReceipts")
        XCTAssertEqual(PrivacyStore.presenceKey, "privacy.broadcastPresence")
        let (app, _, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        XCTAssertTrue(app.privacy.sendReadReceipts, "receipts stay on unless turned off")
        XCTAssertTrue(app.privacy.broadcastPresence, "presence stays on unless turned off")
    }

    func testPrivacyOffDropsBothOutboundSignals() async {
        let (app, _, nav) = GuardSupport.demoModel()
        defer { withExtendedLifetime(nav) {} }
        app.privacy.sendReadReceipts = false
        app.privacy.broadcastPresence = false
        // Both gates fire before any sender/fetch: zero network here.
        app.receipts.sendReadPosition(chatID: "c1", latestID: "m1")
        let before = app.presence.own?.availability
        app.presence.set(status: .busy)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(app.receipts.sent["c1"], "gated receipt stays retryable")
        XCTAssertEqual(app.presence.own?.availability, before, "gated set adopts no echo")
        XCTAssertFalse(app.presence.setting, "gated set shows no spinner")
    }

    // MARK: Pin-for-all copy

    func testPinForAllRefusalCopyIsStable() {
        XCTAssertEqual(
            PinnedMessages.pinForAllFailureMessage(reason: "not permitted"),
            "Teams didn\u{2019}t take the pin for everyone (not permitted). It stays on this Mac only.")
    }
}
