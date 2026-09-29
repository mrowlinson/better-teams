// StableUITests.swift — STABLEUI pins for the shared first-load pane.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class StableUITests: XCTestCase {
    /// R22.4: the corner refresh spinner carries a visible caption (built
    /// from its label), delayed by the same 0.3 s as the loading pane.
    func testRefreshStatusCaptionIsVisibleText() {
        XCTAssertEqual(RefreshStatus.caption("Updating Chats"), "Updating Chats\u{2026}")
        XCTAssertEqual(RefreshStatus.caption("Loading Earlier Messages\u{2026}"), "Loading Earlier Messages\u{2026}")
        XCTAssertEqual(LoadingPane.delayMilliseconds, 300)
    }

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
