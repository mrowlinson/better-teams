// SkeletonTests.swift — P0 skeleton for the UI target's pure-logic
// tests (UI-SPEC §11.1). Later lanes add TimelineSnapshot, ScrollAnchor,
// ToolbarModel, rail capacity, FramePolicy, Route, WeekGridLayout,
// palette contrast tests here.
import XCTest

@testable import BetterTeamsUI

final class SkeletonTests: XCTestCase {
    /// The OstMac shim resolves this exact type.
    func testShimEntryTypeName() {
        XCTAssertEqual(
            String(reflecting: AppDelegate.self), "BetterTeamsUI.AppDelegate")
    }
}
