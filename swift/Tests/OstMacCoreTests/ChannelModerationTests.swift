// ChannelModerationTests.swift — TEAMMOD lane: moderation model mapping
// (unknown -> everyone), fail-closed owner-only guards, optimistic
// moderation/visibility updates with revert. Fakes only: nothing
// reaches the service.
import XCTest

@testable import OstMacCore

@MainActor
final class ChannelModerationTests: XCTestCase {
    private nonisolated static func ch(_ id: String, _ name: String) -> TeamChannel {
        TeamChannel(channelId: id, name: name)
    }

    private nonisolated static let server = [
        TeamItem(teamId: "own", name: "Owned", channels: [ch("c1", "General"), ch("c2", "Builds")]),
        TeamItem(teamId: "mem", name: "Member", channels: [ch("c3", "General")]),
    ]

    private func model(
        owner: @escaping @Sendable (String) throws -> Bool = { $0 == "own" },
        moderation: @escaping @Sendable (String, String) throws -> ChannelModeration = { _, _ in ChannelModeration() },
        updater: @escaping @Sendable (String, String, String?, String?) throws -> Void = { _, _, _, _ in },
        visibility: @escaping @Sendable (String) throws -> TeamVisibilityResponse = { _ in TeamVisibilityResponse(visibility: "private") },
        visibilityUpdater: @escaping @Sendable (String, Bool) throws -> TeamVisibilityResponse = { _, p in
            TeamVisibilityResponse(visibility: p ? "private" : "public")
        },
        settings: @escaping @Sendable (String) throws -> TeamMemberSettings = { _ in TeamMemberSettings() },
        rows: LockedBox<[TeamItem]> = LockedBox(server)
    ) -> TeamsViewModel {
        TeamsViewModel(
            fetcher: { TeamsResponse(ok: true, teams: rows.value) },
            ownerCheck: owner,
            settingsFetcher: settings,
            moderationFetcher: moderation,
            moderationUpdater: updater,
            visibilityFetcher: visibility,
            visibilityUpdater: visibilityUpdater)
    }

    func testWireMapping() {
        XCTAssertEqual(WhoCanPost.from(nil), .everyone)
        XCTAssertEqual(WhoCanPost.from("moderators"), .moderators)
        XCTAssertEqual(WhoCanPost.from("everyoneExceptGuests"), .everyoneExceptGuests)
        XCTAssertEqual(WhoCanPost.from("owners"), .everyone)
        XCTAssertEqual(WhoCanReply.from(nil), .everyone)
        XCTAssertEqual(WhoCanReply.from("authorAndModerators"), .authorAndModerators)
        XCTAssertEqual(WhoCanReply.from("nobody"), .everyone)
        XCTAssertEqual(TeamPrivacy.from(nil), .unknown)
        XCTAssertEqual(TeamPrivacy.from("Private"), .private)
        XCTAssertEqual(TeamPrivacy.from("PUBLIC"), .public)
        XCTAssertEqual(TeamPrivacy.from("hiddenmembership"), .unknown)
        XCTAssertFalse(ChannelModeration().isModerated)
        XCTAssertTrue(ChannelModeration(userNewMessageRestriction: "moderators").isModerated)
    }

    func testGuardsFailClosed() {
        XCTAssertTrue(ChannelModerationRights.canEdit(isOwner: true))
        XCTAssertFalse(ChannelModerationRights.canEdit(isOwner: false))
        XCTAssertFalse(ChannelModerationRights.canEdit(isOwner: nil))
    }

    func testModerationBadgeGuard() {
        // Unknown (never read) shows no badge, never a guess.
        XCTAssertFalse(ChannelModerationBadge.showsBadge(nil))
        // Known unmoderated shows no badge.
        XCTAssertFalse(ChannelModerationBadge.showsBadge(ChannelModeration()))
        XCTAssertFalse(ChannelModerationBadge.showsBadge(ChannelModeration(
            userNewMessageRestriction: "everyone", replyRestriction: "everyone")))
        // Known moderated (either axis) shows the badge.
        XCTAssertTrue(ChannelModerationBadge.showsBadge(ChannelModeration(
            userNewMessageRestriction: "moderators")))
        XCTAssertTrue(ChannelModerationBadge.showsBadge(ChannelModeration(
            replyRestriction: "authorAndModerators")))
        XCTAssertTrue(ChannelModerationBadge.showsBadge(ChannelModeration(
            userNewMessageRestriction: "everyoneExceptGuests")))
    }

    func testModerationBadgeFromReadData() async {
        let vm = model(moderation: { _, channel in
            channel == "c2"
                ? ChannelModeration(userNewMessageRestriction: "moderators")
                : ChannelModeration()
        })
        await vm.load()
        await vm.refreshModeration(teamID: "own", channelID: "c2")
        await vm.refreshModeration(teamID: "own", channelID: "c1")
        let modKey = TeamsViewModel.moderationKey(teamID: "own", channelID: "c2")
        let plainKey = TeamsViewModel.moderationKey(teamID: "own", channelID: "c1")
        let unknownKey = TeamsViewModel.moderationKey(teamID: "mem", channelID: "c3")
        XCTAssertTrue(ChannelModerationBadge.showsBadge(vm.moderation[modKey]))
        XCTAssertFalse(ChannelModerationBadge.showsBadge(vm.moderation[plainKey]))
        XCTAssertFalse(ChannelModerationBadge.showsBadge(vm.moderation[unknownKey]))
    }

    func testModerationNeedsKnownOwner() async {
        let vm = model()
        await vm.load()
        await vm.refreshOwnership()
        XCTAssertTrue(vm.canEditModeration(teamID: "own"))
        XCTAssertFalse(vm.canEditModeration(teamID: "mem"))
        // Non-owner write refuses before any network.
        var called = false
        let vm2 = model(owner: { _ in false }, updater: { _, _, _, _ in called = true })
        await vm2.load()
        await vm2.refreshOwnership()
        let refused = await vm2.updateModeration(teamID: "mem", channelID: "c3", posts: .moderators, replies: nil)
        XCTAssertFalse(refused)
        XCTAssertFalse(called)
        XCTAssertEqual(vm2.actionError, "Only team owners can change moderation settings.")
    }

    func testModerationGeneralRefusesPreNetwork() async {
        var called = false
        let vm = model(
            updater: { _, _, _, _ in called = true },
            settings: { _ in TeamMemberSettings(primaryChannelId: "c1") })
        await vm.load()
        await vm.refreshOwnership()
        XCTAssertTrue(vm.isGeneral(teamID: "own", channelID: "c1"))
        let refused = await vm.updateModeration(teamID: "own", channelID: "c1", posts: .moderators, replies: nil)
        XCTAssertFalse(refused)
        XCTAssertFalse(called)
        XCTAssertEqual(vm.actionError, "The General channel's moderation can't be changed (Teams allows it only on standard channels).")
        // A standard channel still writes.
        let ok = await vm.updateModeration(teamID: "own", channelID: "c2", posts: .moderators, replies: nil)
        XCTAssertTrue(ok)
        XCTAssertTrue(called)
    }

    func testModerationOptimisticAndRevert() async {
        let seen = LockedBox<[String?]>([nil, nil])
        let vm = model(updater: { _, _, p, r in seen.value = [p, r] })
        await vm.load()
        await vm.refreshOwnership()
        let ok = await vm.updateModeration(teamID: "own", channelID: "c2", posts: .moderators, replies: .authorAndModerators)
        XCTAssertTrue(ok)
        XCTAssertEqual(seen.value, ["moderators", "authorAndModerators"])
        let key = TeamsViewModel.moderationKey(teamID: "own", channelID: "c2")
        XCTAssertEqual(vm.moderation[key]?.posts, .moderators)
        // Failing write reverts to the old value.
        let vm2 = model(updater: { _, _, _, _ in throw CoreCallError.failed("denied") })
        await vm2.load()
        await vm2.refreshOwnership()
        await vm2.refreshModeration(teamID: "own", channelID: "c2")
        let before = vm2.moderation[key]
        let reverted = await vm2.updateModeration(teamID: "own", channelID: "c2", posts: .everyone, replies: nil)
        XCTAssertFalse(reverted)
        XCTAssertEqual(vm2.moderation[key], before)
        XCTAssertNotNil(vm2.actionError)
    }

    func testVisibilityRoundTrip() async {
        let vm = model()
        await vm.load()
        await vm.refreshOwnership()
        await vm.refreshVisibility(teamID: "own")
        XCTAssertEqual(vm.visibility["own"], .private)
        let flipped = await vm.updateVisibility(teamID: "own", makePrivate: false)
        XCTAssertTrue(flipped)
        XCTAssertEqual(vm.visibility["own"], .public)
        // Non-owner flip refuses.
        let vm2 = model(owner: { _ in false })
        await vm2.load()
        await vm2.refreshOwnership()
        XCTAssertFalse(vm2.canSetVisibility(teamID: "mem"))
        let refusedFlip = await vm2.updateVisibility(teamID: "mem", makePrivate: true)
        XCTAssertFalse(refusedFlip)
        XCTAssertEqual(vm2.actionError, "Only team owners can change team privacy.")
    }
}
