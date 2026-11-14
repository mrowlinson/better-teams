// FullscreenToolbarTests.swift — P2#15: full screen keeps the main
// window's toolbar visible (AppKit would auto-hide it); the call
// window shares the rule.
import XCTest

@testable import BetterTeamsUI
import AppKit

@MainActor
final class FullscreenToolbarTests: XCTestCase {
    func testToolbarStaysVisible() {
        let opts: NSApplication.PresentationOptions = [.autoHideToolbar, .autoHideMenuBar, .fullScreen]
        let out = ShellWindowController.fullScreenOptions(opts)
        XCTAssertFalse(out.contains(.autoHideToolbar), "toolbar stays visible in full screen")
        XCTAssertTrue(out.contains(.autoHideMenuBar), "other options untouched")
        XCTAssertTrue(out.contains(.fullScreen))
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(ShellWindowController.fullScreenOptions([]), [])
    }
}
