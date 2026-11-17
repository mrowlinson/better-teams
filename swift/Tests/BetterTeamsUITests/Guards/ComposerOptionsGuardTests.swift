// Guard: COMPOSER-B — importance/urgent, subject, and broadcast-mention
// surfaces stay native and wired. The composer field stays plain text
// (draft-stays-markdown architecture, C1a); new surfaces are native
// controls (Menu + Picker, roundedBorder TextField) and delegate to the
// pure Swift/Rust layers (MentionWire, SendOpts).
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class ComposerOptionsGuardTests: XCTestCase {
    private var conversationDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/Conversation")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: conversationDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// Draft-stays-markdown: the field is plain text (C1a architecture,
    /// extended — never replaced — by C1b).
    func testComposerFieldStaysPlainText() throws {
        let composer = try source("Composer.swift")
        XCTAssertTrue(composer.contains("tv.isRichText = false"), "field stays plain text")
    }

    /// Importance is a native Menu + Picker (checkmarked), not custom chrome.
    func testImportancePickerIsNative() throws {
        let composer = try source("Composer.swift")
        XCTAssertTrue(composer.contains("Picker(\"Importance\""), "native Picker named Importance")
        XCTAssertTrue(composer.contains("importanceMenu"), "importance menu in the button row")
        XCTAssertFalse(composer.contains("importanceUnderline"), "no custom underline selection")
    }

    /// Announcement subject is a native rounded-border TextField,
    /// channels only.
    func testSubjectFieldIsNativeAndChannelOnly() throws {
        let composer = try source("Composer.swift")
        XCTAssertTrue(composer.contains("TextField(\"Subject\""), "native Subject TextField")
        XCTAssertTrue(composer.contains(".textFieldStyle(.roundedBorder)"), "rounded-border style")
        XCTAssertTrue(composer.contains("if isChannel { subjectField }"), "channels only")
    }

    /// Broadcast specials are offered (channel-gated) and resolved at
    /// send time; picker rows render the megaphone for specials.
    func testBroadcastSpecialsWiredEndToEnd() throws {
        let composer = try source("Composer.swift")
        XCTAssertTrue(composer.contains("MentionWire.displays(channel: isChannel)"), "picker offers specials")
        XCTAssertTrue(composer.contains("MentionWire.resolve(in: body, channel: isChannel)"), "send resolves specials")
        XCTAssertTrue(composer.contains("composer.resetSendOptions(chatID: chatID)"), "options reset after send")
        let popovers = try source("ComposerPopovers.swift")
        XCTAssertTrue(popovers.contains("MentionWire.isSpecialDisplay"), "special rows detected")
        XCTAssertTrue(popovers.contains("\"megaphone\""), "special rows get the megaphone")
    }

    /// Send path carries all three options (never drops one silently).
    func testSendThreadsAllOptions() throws {
        let store = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OstMacCore/ConversationStore.swift")
        let source = try String(contentsOf: store, encoding: .utf8)
        XCTAssertTrue(
            source.contains("importance: importance, subject: subject, mentions: mentions"),
            "OutgoingSend carries importance + subject + mentions")
    }
}
