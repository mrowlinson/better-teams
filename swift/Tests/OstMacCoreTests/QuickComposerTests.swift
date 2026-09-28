// QuickComposerTests.swift — f1-composer lane: global quick-composer
// hotkey model (combo value + prefs + reject list), summon/Esc state
// machine, send gate, sendable-target filter parity, and hotkey
// register/unregister cycling.
import XCTest

@testable import OstMacCore

@MainActor
final class QuickComposerTests: XCTestCase {
    private func suite() -> UserDefaults {
        let d = UserDefaults(suiteName: "test-quickcompose") ?? .standard
        d.removePersistentDomain(forName: "test-quickcompose")
        return d
    }

    // MARK: - Combo value

    func testDefaultComboIsCtrlCmdM() {
        XCTAssertEqual(QuickComposeCombo.default.keyCode, 46)
        XCTAssertEqual(
            QuickComposeCombo.default.modifiers,
            QuickComposeCombo.cmdModifier | QuickComposeCombo.controlModifier)
    }

    func testDefaultComboDisplayString() {
        XCTAssertEqual(QuickComposeCombo.default.displayString, "⌃⌘M")
    }

    func testComboCodableRoundTrip() {
        let combo = QuickComposeCombo(
            keyCode: 31,
            modifiers: QuickComposeCombo.cmdModifier | QuickComposeCombo.optionModifier)
        let data = try! JSONEncoder().encode(combo)
        XCTAssertEqual(try! JSONDecoder().decode(QuickComposeCombo.self, from: data), combo)
    }

    func testDisplayStringOrdersModifiers() {
        let combo = QuickComposeCombo(
            keyCode: 18, // 1
            modifiers: QuickComposeCombo.cmdModifier | QuickComposeCombo.shiftModifier
                | QuickComposeCombo.optionModifier | QuickComposeCombo.controlModifier)
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘1")
    }

    func testCarbonModifiersFromCocoaFlags() {
        // NSEvent.ModifierFlags raw values (no AppKit import in pure core).
        let cocoaCommand: UInt = 0x100000
        let cocoaControl: UInt = 0x40000
        let cocoaOption: UInt = 0x80000
        let cocoaShift: UInt = 0x20000
        XCTAssertEqual(
            QuickComposeCombo.carbonModifiers(cocoaFlags: cocoaCommand | cocoaControl),
            QuickComposeCombo.cmdModifier | QuickComposeCombo.controlModifier)
        XCTAssertEqual(
            QuickComposeCombo.carbonModifiers(cocoaFlags: cocoaOption | cocoaShift),
            QuickComposeCombo.optionModifier | QuickComposeCombo.shiftModifier)
        XCTAssertEqual(QuickComposeCombo.carbonModifiers(cocoaFlags: 0), 0)
    }

    // MARK: - Reject list (pinned)

    func testDefaultComboNotRejected() {
        XCTAssertNil(QuickComposeCombo.default.rejectedReason)
    }

    func testBareKeyRejected() {
        XCTAssertNotNil(QuickComposeCombo(keyCode: 46, modifiers: 0).rejectedReason)
    }

    func testShiftOnlyRejected() {
        XCTAssertNotNil(QuickComposeCombo(
            keyCode: 46, modifiers: QuickComposeCombo.shiftModifier).rejectedReason)
    }

    func testSystemCollisionsRejected() {
        let cmd = QuickComposeCombo.cmdModifier
        // keyCode: Q=12 W=13 Tab=48 Space=49 `=50 H=4 M=46 ,=43 F=3.
        for code: UInt32 in [12, 13, 48, 49, 50, 4, 46, 43, 3] {
            XCTAssertNotNil(
                QuickComposeCombo(keyCode: code, modifiers: cmd).rejectedReason,
                "Cmd+keycode \(code) must be rejected")
        }
        // Ctrl+Space (input switcher).
        XCTAssertNotNil(QuickComposeCombo(
            keyCode: 49, modifiers: QuickComposeCombo.controlModifier).rejectedReason)
    }

    func testInAppCollisionsRejected() {
        let cmd = QuickComposeCombo.cmdModifier
        // K=40 (jump), J=38 (join), Shift+I=34 (sign-in).
        XCTAssertNotNil(QuickComposeCombo(keyCode: 40, modifiers: cmd).rejectedReason)
        XCTAssertNotNil(QuickComposeCombo(keyCode: 38, modifiers: cmd).rejectedReason)
        XCTAssertNotNil(QuickComposeCombo(
            keyCode: 34, modifiers: cmd | QuickComposeCombo.shiftModifier).rejectedReason)
    }

    func testCustomUsableComboAccepted() {
        // Ctrl+Cmd+Q: Q is rejected under bare Cmd only; with Ctrl added
        // it no longer collides with Quit.
        XCTAssertNil(QuickComposeCombo(
            keyCode: 12,
            modifiers: QuickComposeCombo.cmdModifier | QuickComposeCombo.controlModifier
        ).rejectedReason)
        XCTAssertNil(QuickComposeCombo(
            keyCode: 122, // F1
            modifiers: QuickComposeCombo.cmdModifier | QuickComposeCombo.optionModifier
        ).rejectedReason)
    }

    // MARK: - Prefs persist

    func testPrefsDefaultWhenAbsent() {
        let d = suite()
        XCTAssertEqual(QuickComposerPrefs.loadCombo(defaults: d), .default)
        XCTAssertTrue(QuickComposerPrefs.isEnabled(defaults: d))
    }

    func testPrefsRemapPersistsAcrossReload() {
        let d = suite()
        let combo = QuickComposeCombo(
            keyCode: 31, modifiers: QuickComposeCombo.cmdModifier | QuickComposeCombo.optionModifier)
        QuickComposerPrefs.saveCombo(combo, defaults: d)
        XCTAssertEqual(QuickComposerPrefs.loadCombo(defaults: d), combo)
    }

    func testPrefsEnabledRoundTrip() {
        let d = suite()
        QuickComposerPrefs.setEnabled(false, defaults: d)
        XCTAssertFalse(QuickComposerPrefs.isEnabled(defaults: d))
        QuickComposerPrefs.setEnabled(true, defaults: d)
        XCTAssertTrue(QuickComposerPrefs.isEnabled(defaults: d))
    }

    // MARK: - Hotkey register/unregister (no relaunch)

    func testHotKeyUpdateRegistersAndUnregisters() {
        let hotKey = QuickComposerHotKey()
        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertTrue(hotKey.update(combo: .default, enabled: true))
        XCTAssertTrue(hotKey.isRegistered)
        XCTAssertEqual(hotKey.activeCombo, .default)
        XCTAssertFalse(hotKey.update(combo: .default, enabled: false))
        XCTAssertFalse(hotKey.isRegistered)
        XCTAssertNil(hotKey.activeCombo)
    }

    func testHotKeyRemapReRegistersWithoutRelaunch() {
        let hotKey = QuickComposerHotKey()
        XCTAssertTrue(hotKey.update(combo: .default, enabled: true))
        let combo = QuickComposeCombo(
            keyCode: 31, modifiers: QuickComposeCombo.cmdModifier | QuickComposeCombo.optionModifier)
        XCTAssertTrue(hotKey.update(combo: combo, enabled: true))
        XCTAssertEqual(hotKey.activeCombo, combo)
        hotKey.unregister()
        XCTAssertFalse(hotKey.isRegistered)
    }

    func testHotKeyRejectsUnusableCombo() {
        let hotKey = QuickComposerHotKey()
        XCTAssertFalse(hotKey.update(
            combo: QuickComposeCombo(keyCode: 12, modifiers: QuickComposeCombo.cmdModifier),
            enabled: true))
        XCTAssertFalse(hotKey.isRegistered)
    }

    // MARK: - Summon / Esc state machine

    func testSummonShowsEmpty() {
        var model = QuickComposerModel()
        XCTAssertFalse(model.isVisible)
        model.summon()
        XCTAssertTrue(model.isVisible)
        XCTAssertEqual(model.targetQuery, "")
        XCTAssertEqual(model.message, "")
    }

    func testEscWithMessageClearsFirst() {
        var model = QuickComposerModel()
        model.summon()
        model.message = "hello"
        model.targetQuery = "ava"
        XCTAssertEqual(model.esc(), .clearedMessage)
        XCTAssertEqual(model.message, "")
        XCTAssertTrue(model.isVisible)
    }

    func testEscWithQueryClearsSecond() {
        var model = QuickComposerModel()
        model.summon()
        model.targetQuery = "ava"
        XCTAssertEqual(model.esc(), .clearedQuery)
        XCTAssertEqual(model.targetQuery, "")
        XCTAssertTrue(model.isVisible)
    }

    func testEscOnEmptyDismisses() {
        var model = QuickComposerModel()
        model.summon()
        XCTAssertEqual(model.esc(), .dismissed)
        XCTAssertFalse(model.isVisible)
    }

    // MARK: - Send gate

    func testCanSendNeedsSignedInAndText() {
        XCTAssertTrue(QuickComposerModel.canSend(text: "hi", signedIn: true))
        XCTAssertFalse(QuickComposerModel.canSend(text: "hi", signedIn: false))
        XCTAssertFalse(QuickComposerModel.canSend(text: "   ", signedIn: true))
        XCTAssertFalse(QuickComposerModel.canSend(text: "", signedIn: true))
    }

    func testBlankMessageNeverSends() {
        let conv = ConversationStore()
        conv.showDemo(chatID: "c1", chatName: "Ava Martinez", messages: [])
        conv.send(text: "   \n  ")
        conv.send(text: "")
        XCTAssertTrue(conv.messages.isEmpty)
        XCTAssertNil(conv.error)
    }

    func testDemoSendEchoesOwnBubble() {
        let conv = ConversationStore()
        conv.showDemo(chatID: "c1", chatName: "Ava Martinez", messages: [])
        conv.send(text: "  hello  ")
        XCTAssertEqual(conv.messages.count, 1)
        XCTAssertEqual(conv.messages[0].content, "hello")
        XCTAssertTrue(conv.messages[0].isOwn)
    }

    // MARK: - Send routing (open timeline vs direct core)

    func testRoutingOpenTargetUsesOpenStore() {
        XCTAssertTrue(QuickComposerRouting.sendThroughOpenStore(
            targetID: "c1", openChatID: "c1"))
    }

    func testRoutingOffscreenTargetSendsDirect() {
        XCTAssertFalse(QuickComposerRouting.sendThroughOpenStore(
            targetID: "c2", openChatID: "c1"))
        XCTAssertFalse(QuickComposerRouting.sendThroughOpenStore(
            targetID: "c1", openChatID: nil))
    }

    // MARK: - Sendable-only targets (ForwardPicker parity)

    private func composerTargets() -> [JumpTarget] {
        let chats = [
            ChatItem(chatId: "c1", name: "Ava Martinez"),
            ChatItem(chatId: "c2", name: "Weekend Plans", is_group: true),
        ]
        let teams = [
            TeamItem(teamId: "t1", name: "Engineering", channels: [
                TeamChannel(channelId: "ch1", name: "general"),
                TeamChannel(channelId: "ch2", name: "shipping"),
            ]),
            TeamItem(teamId: "t0", name: "Lonely", channels: []),
        ]
        return ForwardPicker.targets(chats: chats, teams: teams)
    }

    func testComposerTargetsAreAllSendable() {
        for t in composerTargets() {
            XCTAssertNotNil(t.openID, "\(t.title) must be sendable")
        }
    }

    func testComposerTargetsDropChannelLessTeam() {
        let titles = composerTargets().map(\.title)
        XCTAssertFalse(titles.contains("Lonely"))
        XCTAssertTrue(titles.contains("Ava Martinez"))
        XCTAssertTrue(titles.contains("#general"))
        XCTAssertTrue(titles.contains("#shipping"))
    }

    func testComposerTargetFilterMatchesJumpRows() {
        // Same row data as Cmd+K (JumpTargets), narrowed to sendable.
        let all = JumpTargets.build(
            chats: [ChatItem(chatId: "c1", name: "Ava Martinez")],
            teams: [TeamItem(teamId: "t0", name: "Lonely", channels: [])])
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(composerTargets().count, 5) // 2 chats + 2 channels + 1 team
    }
}
