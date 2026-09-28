// CameraStartTests.swift — double-start idempotence (no camera hardware).
import XCTest

@testable import OstMacCore

@MainActor
final class CameraStartTests: XCTestCase {
    func testStartPlanIsIdempotentOnSameDevice() {
        XCTAssertEqual(CameraStartPlan.decide(active: false, activeDeviceID: nil, want: nil), .configure)
        XCTAssertEqual(CameraStartPlan.decide(active: false, activeDeviceID: "a", want: "a"), .configure)
        XCTAssertEqual(CameraStartPlan.decide(active: true, activeDeviceID: nil, want: nil), .alreadyRunning)
        XCTAssertEqual(CameraStartPlan.decide(active: true, activeDeviceID: "a", want: "a"), .alreadyRunning)
        XCTAssertEqual(CameraStartPlan.decide(active: true, activeDeviceID: "a", want: "b"), .reconfigure)
        XCTAssertEqual(CameraStartPlan.decide(active: true, activeDeviceID: nil, want: "b"), .reconfigure)
    }
}
