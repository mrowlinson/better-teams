// VisfixM1M2GuardTests.swift — VISFIX-M1M2 R0/R1: the two medium visual
// defects stay fixed (owner: M1 clipped Notifications row, M2 bare-label
// Calls detail; L1 accepted as-is). Source scans of the two touched
// surfaces only. Nothing goes on screen.
import SwiftUI
import XCTest
@testable import BetterTeamsUI
@testable import OstMacCore

enum VisfixM1M2Scanner {
    /// M1: the Notifications pane must scroll its content (the DND row
    /// clipped in a fixed 700x640 slot with no scroll).
    static func m1Violations(in source: String) -> [String] {
        var out: [String] = []
        let code = source.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
        if !code.contains("ScrollView") {
            out.append("NotificationsPane: no ScrollView (bottom rows clip again)")
        }
        if !code.contains("height: 640") {
            out.append("NotificationsPane: 700x640 window slot changed (other panes/size behavior must stay intact)")
        }
        return out
    }

    /// M2: the Calls no-selection detail must be a designed empty state
    /// (symbol + description + action), never a bare NoSelectionPane label.
    static func m2Violations(in source: String) -> [String] {
        var out: [String] = []
        let lines = source.components(separatedBy: "\n")
        let code = lines.map { $0.components(separatedBy: "//").first ?? $0 }.joined(separator: "\n")
        // The detail pane's fallback branch.
        let detailRange = code.range(of: "struct CallsDetailPane") ?? code.startIndex..<code.endIndex
        let detailSrc = String(code[detailRange.lowerBound...])
        if detailSrc.contains("NoSelectionPane(\"No Contact Selected\")") {
            out.append("CallsViews: CallsDetailPane still shows a bare NoSelectionPane label")
        }
        if !code.contains("CallsNoContactPane") {
            out.append("CallsViews: no designed no-contact pane")
        }
        return out
    }
}

@MainActor
final class VisfixM1M2GuardTests: XCTestCase {
    private var uiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    private func source(_ subpath: String) throws -> String {
        try String(contentsOf: uiDir.appendingPathComponent(subpath), encoding: .utf8)
    }

    // MARK: M1

    func testM1NotificationsPaneScrolls() throws {
        let src = try source("Settings/NotificationsPane.swift")
        let found = VisfixM1M2Scanner.m1Violations(in: src)
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }

    func testM1DNDRowKept() throws {
        // Control: the fix scrolls to the row, it must not delete it.
        let pane = try source("Settings/NotificationsPane.swift")
        XCTAssertTrue(pane.contains("DoNotDisturbSection(quiet: quiet)"), "DND section still in the pane")
        let dnd = try source("Settings/QuietHoursSection.swift")
        XCTAssertTrue(dnd.contains("Picker(\"Turn off\""), "DND expiry Picker still present")
    }

    // MARK: M2

    func testM2CallsDetailDesigned() throws {
        let src = try source("Sections/Calls/CallsViews.swift")
        let found = VisfixM1M2Scanner.m2Violations(in: src)
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }

    func testM2NoContactPaneContent() throws {
        // Control: title kept, symbol + description + action present.
        let src = try source("Sections/Calls/CallsViews.swift")
        XCTAssertTrue(src.contains("EmptyPane(\"No Contact Selected\", systemImage: \"phone\""),
                      "no-contact pane keeps its title with a symbol")
        XCTAssertTrue(src.contains("Select a recent call or Speed Dial contact"),
                      "no-contact pane describes what to do")
        XCTAssertTrue(src.contains("Button(\"New Call…\")"), "no-contact pane offers the New Call action")
    }

    // MARK: scanner controls

    func testScannerControls() {
        XCTAssertTrue(VisfixM1M2Scanner.m1Violations(in: "ScrollView { Form {} }\n.frame(height: 640)").isEmpty)
        XCTAssertEqual(VisfixM1M2Scanner.m1Violations(in: "Form {}").count, 2)
        XCTAssertTrue(VisfixM1M2Scanner.m2Violations(in: "struct CallsDetailPane {}\nstruct CallsNoContactPane: View {}").isEmpty)
        XCTAssertEqual(
            VisfixM1M2Scanner.m2Violations(
                in: "struct CallsDetailPane { var b: some View { NoSelectionPane(\"No Contact Selected\") } }").count, 2)
    }
}
