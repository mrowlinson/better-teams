// TrialLicenceGuardTests.swift — PSTN-TRIAL R1 pins (need owner OK to
// edit/delete/skip): the dial pad stays disabled-with-reason with a proven
// Phone System licence but no calling plan (trial tenant shape), the view
// names the actual missing capability, and no PSTN call-setup wiring
// appears anywhere (delegates-only Graph surface unchanged).
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

final class TrialLicenceGuardTests: XCTestCase {
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

    func testDialPadNamesMissingCallingPlan() throws {
        let s = try uiSource("Sections/Calls/PhoneViews.swift")
        XCTAssertTrue(s.contains("licence.callingPlanNote"),
                      "dial tab must wire the calling-plan capability note")
        XCTAssertTrue(PhoneLicence.callingPlanReason.contains("Calling Plan"),
                      "reason must name the missing capability")
        XCTAssertTrue(s.contains(".help(PhoneStore.liveReason)"),
                      "live dial Call keeps the generic reason as help")
    }

    func testTrialShapeParsesToPhoneSystemOnly() {
        let l = PhoneLicence.parse(servicePlanNames: ["TEAMS1", "MCOEV", "MCOMEETADV", "MCOSTANDARD"])
        XCTAssertTrue(l.hasPhoneSystem)
        XCTAssertFalse(l.hasCallingPlan)
        XCTAssertFalse(l.canDialPSTN)
    }

    func testNoCallSetupWiringWithTrialLicence() throws {
        let core = try coreSource("PhoneSettings.swift")
        XCTAssertFalse(core.contains("/communications/calls"),
                       "no PSTN call-setup wiring with a trial licence alone")
        let ui = try uiSource("Sections/Calls/PhoneViews.swift")
        XCTAssertFalse(ui.contains("/communications/calls"),
                       "no PSTN call-setup wiring in the Phone sheet")
    }
}
