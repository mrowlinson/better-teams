// GraphTwoUITests.swift — §GRAPH2: the states that say a read failed.
// Pure view helpers only; nothing is shown on screen.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class GraphTwoUITests: XCTestCase {
    func testCatchUpStatusSaysTheTagReadFailedInsteadOfUpToDate() {
        let why = "Teams didn\u{2019}t allow reading your tags."
        XCTAssertEqual(CatchUpDigestView.statusLine(working: false, paused: nil, lastError: nil, tagsError: nil, pending: 0),
                       "Up to date", "control: no failure, no message")
        let line = CatchUpDigestView.statusLine(working: false, paused: nil, lastError: nil, tagsError: why, pending: 0)
        XCTAssertEqual(line, "Tag mentions unavailable \u{2014} \(why)")
        // A summary error still wins; work in progress still shows as work.
        XCTAssertEqual(CatchUpDigestView.statusLine(working: false, paused: nil, lastError: "Summary failed", tagsError: why, pending: 0),
                       "Summary failed")
        XCTAssertEqual(CatchUpDigestView.statusLine(working: true, paused: nil, lastError: nil, tagsError: why, pending: 2), "Updating\u{2026}")
    }

    func testOrganizationTabStaysWhenTheOrgReadFailed() {
        let profile = ContactProfile(id: "u1", displayName: "Tom Becker")
        var card = ContactCard(profile: profile, orgLoaded: true)
        XCTAssertFalse(ContactCardSheet.tabs(for: card).contains(.organization), "control: nothing to show hides the tab")
        card.failures[.organization] = "The directory didn\u{2019}t allow this."
        XCTAssertTrue(ContactCardSheet.tabs(for: card).contains(.organization), "a failed read keeps the tab so it can say why")
    }
}
