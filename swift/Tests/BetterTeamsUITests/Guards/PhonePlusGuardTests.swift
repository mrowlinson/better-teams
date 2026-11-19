// PhonePlusGuardTests.swift — PHONE-PLUS R1 pins (need owner OK to
// edit/delete/skip): Park + Queues tabs exist in the Phone sheet with
// demo interactivity, every live branch states a licence reason, and no
// park/queue Graph wiring appears anywhere (R0: no such endpoint exists
// — Teams PowerShell admin surface only).
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

final class PhonePlusGuardTests: XCTestCase {
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

    func testParkAndQueuesTabsExist() throws {
        let s = try uiSource("Sections/Calls/PhoneViews.swift")
        for required in ["case park", "case queues", "ParkView(phone:",
                         "QueuesView(phone:", ".tag(PhoneTab.park)",
                         ".tag(PhoneTab.queues)"] {
            XCTAssertTrue(s.contains(required), "PhoneViews.swift must contain \(required)")
        }
    }

    func testParkAndQueuesUseNativeControls() throws {
        let s = try uiSource("Sections/Calls/PhoneViews.swift")
        XCTAssertTrue(s.contains("struct ParkView"), "park tab view")
        XCTAssertTrue(s.contains("struct QueuesView"), "queues tab view")
        // List/Section pin the native browse shape; ContentUnavailableView
        // pins the empty states (HIG, no custom chrome).
        XCTAssertTrue(s.contains("Section(\"Call Queues\")"), "queues section")
        XCTAssertTrue(s.contains("Section(\"Auto Attendants\")"), "attendants section")
    }

    func testLivePlusBranchesCarryReasons() throws {
        let s = try uiSource("Sections/Calls/PhoneViews.swift")
        XCTAssertTrue(s.contains("PhoneStore.parkReason"), "live park needs the policy reason")
        XCTAssertTrue(s.contains("PhoneStore.queuesReason"), "live queues needs the licence reason")
        XCTAssertTrue(PhoneStore.parkReason.contains("Teams Phone licence"),
                      "park reason must name the missing licence")
        XCTAssertTrue(PhoneStore.queuesReason.contains("Teams Phone licence"),
                      "queues reason must name the missing licence")
    }

    func testNoParkQueueGraphWiring() throws {
        // R0: no Graph endpoint exists for park/pickup or queues/auto
        // attendants — any such literal means a lane wired a fake live
        // path. Delegates-only surface stays unchanged.
        let core = try coreSource("PhoneSettings.swift")
        for banned in ["/communications/calls", "/callQueues", "/autoAttendant",
                       "cloudCommunications", "CsCallQueue", "CsAutoAttendant"] {
            XCTAssertFalse(core.contains(banned), "PhoneSettings.swift must not contain \(banned)")
        }
        let ui = try uiSource("Sections/Calls/PhoneViews.swift")
        for banned in ["/communications/calls", "/callQueues", "/autoAttendant"] {
            XCTAssertFalse(ui.contains(banned), "PhoneViews.swift must not contain \(banned)")
        }
    }
}
