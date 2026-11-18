// Guard: FIXPACK4 — Settings polish defects found in TEXTWALL approval.
// (a) Advanced never shows the raw `init=-99` sentinel;
// (b) free-text fields on Settings panes have a visible border;
// (c) the Apps unload label takes its minutes from the policy constant;
// (d) the MCP path truncates in the middle, never wraps mid-path.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

final class SettingsPolishGuardTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/Settings/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testCoreStatusIsPlainWords() {
        XCTAssertEqual(DiagnosticsFormat.coreStatus(version: "?", initCode: -99), "Not started")
        XCTAssertEqual(DiagnosticsFormat.coreStatus(version: "1.2.3", initCode: 0), "Version 1.2.3")
        XCTAssertTrue(DiagnosticsFormat.coreStatus(version: "1.2.3", initCode: 7).contains("error 7"))
        // Control: the raw debug line still has the sentinel, so the check above is meaningful.
        XCTAssertTrue(DiagnosticsFormat.coreLine(version: "?", initCode: -99).contains("init=-99"))
    }

    func testAdvancedShowsCoreStatusNotRawLine() throws {
        let s = try source("AdvancedPane.swift")
        XCTAssertTrue(s.contains(#"LabeledContent("Core", value: app.coreStatus)"#))
        XCTAssertFalse(s.contains(#"LabeledContent("Core", value: app.coreLine)"#))
        XCTAssertTrue(s.contains(".truncationMode(.middle)"), "MCP path must truncate in the middle")
    }

    func testTextFieldsHaveVisibleBorder() throws {
        let chats = try source("ChatsPane.swift")
        for field in [#"TextField("Name""#, #"TextField("Text""#] {
            let i = try XCTUnwrap(chats.range(of: field), field)
            XCTAssertTrue(chats[i.lowerBound...].prefix(200).contains(".roundedBorder"), "\(field) needs a border")
        }
        let notif = try source("NotificationsPane.swift")
        let k = try XCTUnwrap(notif.range(of: #"TextField("Keyword""#))
        XCTAssertTrue(notif[k.lowerBound...].prefix(200).contains(".roundedBorder"))
        XCTAssertTrue(chats.contains("No templates"), "empty template list needs an empty state")
    }

    func testAppsUnloadLabelUsesPolicyConstant() throws {
        let s = try source("AppsPane.swift")
        XCTAssertFalse(s.contains("after 30 minutes hidden"), "hardcoded minutes")
        XCTAssertEqual(AppsPane.idleUnloadMinutes, Int(FramePolicy.idleUnloadAfter / 60))
    }
}
