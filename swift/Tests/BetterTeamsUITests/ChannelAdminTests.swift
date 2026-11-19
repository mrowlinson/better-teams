// ChannelAdminTests.swift — channel-admin lane: Manage Channel moderation
// editor gating (pure wording; the view disables the pickers and shows
// the reason). Fakes only: nothing reaches the service.
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class ChannelAdminTests: XCTestCase {
    func testModerationReason() {
        XCTAssertNil(ManageChannelInfo.moderationReason(isGeneral: false, canEdit: true))
        XCTAssertEqual(ManageChannelInfo.moderationReason(isGeneral: false, canEdit: false),
                       "Only team owners can change moderation settings.")
        XCTAssertEqual(ManageChannelInfo.moderationReason(isGeneral: true, canEdit: true),
                       "The General channel's moderation can't be changed (Teams allows it only on standard channels).")
        // General wins even for non-owners (the service forbids it for all).
        XCTAssertEqual(ManageChannelInfo.moderationReason(isGeneral: true, canEdit: false),
                       "The General channel's moderation can't be changed (Teams allows it only on standard channels).")
    }
}
