// Guard: VISUALAUDIT fix1 —
// (a) Settings > Calls does not nest a Form (device rows go straight into the grouped Form);
// (b) the call chat's Jump to Latest is not a plain overlay on the List.
import XCTest

final class CallSurfaceGuardTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testCallsPaneDoesNotNestForm() throws {
        let s = try source("Settings/CallsPane.swift")
        XCTAssertTrue(s.contains("CallDevicesRows(devices: devices)"))
        XCTAssertFalse(s.contains("CallDevicesForm"), "nested Form renders default-style pop-ups")
    }

    func testJumpToLatestIsNotPlainOverlay() throws {
        let s = try source("Call/CallInspector.swift")
        let i = try XCTUnwrap(s.range(of: "Button(\"Jump to Latest\""))
        let before = String(s[..<i.lowerBound].suffix(400))
        XCTAssertFalse(before.contains(".overlay(alignment: .bottom)"))
        XCTAssertTrue(before.contains(".safeAreaBar(") || before.contains(".safeAreaInset("))
    }
}
