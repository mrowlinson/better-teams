// PhoneUIGuardTests.swift — PHONEUI lane pins (need owner OK to
// edit/delete/skip): the Phone sheet is native controls (TabView + Form +
// Picker + Toggle, no underline tabs, no Capsule chrome), every live
// calling control is disabled-with-reason (PhoneStore.liveReason, never a
// bare disabled control), and the sheet stays wired to calls.phone.
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

final class PhoneUIGuardTests: XCTestCase {
    private func uiSource(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func coreSource(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OstMacCore/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPhoneSheetUsesNativeControls() throws {
        let s = try uiSource("Sections/Calls/PhoneViews.swift")
        for required in ["TabView(", "Picker(", "Toggle(", "Form {", "List"] {
            XCTAssertTrue(s.contains(required), "PhoneViews.swift must use \(required)")
        }
        XCTAssertFalse(s.contains("Capsule("), "no Capsule chrome in the Phone sheet")
        XCTAssertFalse(s.contains("UnderlineTab"), "no underline tabs in the Phone sheet")
    }

    func testLiveControlsCarryTheLicenceReason() throws {
        let s = try uiSource("Sections/Calls/PhoneViews.swift")
        XCTAssertTrue(s.contains("struct PhoneUnavailablePane"), "live tabs need the reason pane")
        let hits = s.components(separatedBy: "PhoneStore.liveReason").count - 1
        XCTAssertGreaterThanOrEqual(hits, 4, "every live control states the licence reason (\(hits) found)")
        XCTAssertTrue(s.contains(".help(PhoneStore.liveReason)"), "live dial Call needs the reason as help")
    }

    func testLicenceReasonNamesTeamsPhoneLicence() throws {
        XCTAssertTrue(PhoneStore.liveReason.contains("Teams Phone licence"),
                      "reason copy must name the missing licence")
    }

    func testPhoneCommandStaysWired() throws {
        let cmds = try uiSource("Sections/Calls/CallsCommands.swift")
        XCTAssertTrue(cmds.contains("calls.phone"), "calls.phone command id")
        XCTAssertTrue(cmds.contains("phoneSheet"), "phone sheet name")
        let section = try uiSource("Sections/Calls/CallsSection.swift")
        XCTAssertTrue(section.contains("CallsCommands.phoneSheet"), "Calls section serves the Phone sheet")
        XCTAssertTrue(section.contains("PhoneSheet(phone:"), "sheet hosts PhoneSheet")
        XCTAssertTrue(section.contains("CallsCommands.phone"), "perform/validate handle calls.phone")
    }

    func testPhoneGraphStaysDelegatesOnly() throws {
        let s = try coreSource("PhoneSettings.swift")
        XCTAssertTrue(s.contains("/me/communications/callSettings/delegates"), "delegates endpoint")
        XCTAssertFalse(s.contains("/communications/calls"), "no PSTN call-setup wiring without a licence")
    }
}
