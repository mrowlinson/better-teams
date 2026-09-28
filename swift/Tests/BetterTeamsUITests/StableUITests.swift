// StableUITests.swift — STABLEUI pins for the shared first-load pane.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class StableUITests: XCTestCase {
    /// First-load pane: hidden for the first 0.3 s (a fast load shows
    /// nothing), labelled per section, spoken without the ellipsis.
    func testLoadingPaneDelayAndSpokenLabel() {
        XCTAssertEqual(LoadingPane.delayMilliseconds, 300)
        XCTAssertEqual(LoadingPane.accessibilityLabel("Loading Shifts\u{2026}"), "Loading Shifts")
        XCTAssertEqual(LoadingPane.accessibilityLabel(nil), "Loading")
        let pane = LoadingPane("Loading Chats\u{2026}", progress: 0.4)
        XCTAssertEqual(pane.label, "Loading Chats\u{2026}")
        XCTAssertEqual(pane.progress, 0.4)
    }
}
