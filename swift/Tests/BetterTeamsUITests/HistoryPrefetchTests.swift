// HistoryPrefetchTests.swift — histload: the timeline prefetches the
// next older page once the viewport is within one screen of the top.
import XCTest

@testable import BetterTeamsUI

final class HistoryPrefetchTests: XCTestCase {
    func testPrefetchesWithinOneScreenOfTop() {
        XCTAssertTrue(TimelineViewController.shouldPrefetchOlder(offsetFromTop: 0, viewportHeight: 600))
        XCTAssertTrue(TimelineViewController.shouldPrefetchOlder(offsetFromTop: 599, viewportHeight: 600))
        XCTAssertFalse(TimelineViewController.shouldPrefetchOlder(offsetFromTop: 600, viewportHeight: 600))
        // Tiny viewports keep the old 120 pt floor.
        XCTAssertTrue(TimelineViewController.shouldPrefetchOlder(offsetFromTop: 100, viewportHeight: 50))
    }
}
