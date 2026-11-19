// ChannelPrivTests.swift — channelspriv lane: typed create, archive
// toggle, channel roster, archive guards. Fakes only: nothing reaches
// the service.
import XCTest

@testable import OstMacCore

@MainActor
final class ChannelPrivTests: XCTestCase {
    private func model(
        archiver: @escaping TeamsViewModel.ChannelArchiver = { _, _ in },
        unarchiver: @escaping TeamsViewModel.ChannelArchiver = { _, _ in },
        creator: @escaping TeamsViewModel.TypedCreator = { teamID, name, _, _ in
            ChannelCreateResponse(
                ok: true,
                channel: TeamChannel(channelId: "19:new@thread.tacv2", name: name))
        }
    ) -> TeamsViewModel {
        TeamsViewModel(
            fetcher: { TeamsTests.teamsJSON() },
            typedCreator: creator,
            channelArchiver: archiver,
            channelUnarchiver: unarchiver)
    }

    // MARK: - Membership type helper

    func testPrivateOrSharedFlag() {
        XCTAssertFalse(TeamChannel(channelId: "a", name: "General").isPrivateOrShared)
        XCTAssertFalse(TeamChannel(channelId: "a", name: "R", membershipType: "standard").isPrivateOrShared)
        XCTAssertTrue(TeamChannel(channelId: "a", name: "P", membershipType: "private").isPrivateOrShared)
        XCTAssertTrue(TeamChannel(channelId: "a", name: "S", membershipType: "Shared").isPrivateOrShared)
    }

    // MARK: - Typed create

    func testTypedCreateAppendsMembershipType() async {
        let seen = LockedBox<[String?]>([nil])
        let model = model { _, name, _, mt in
            seen.mutate { $0 = [mt] }
            return ChannelCreateResponse(
                ok: true,
                channel: TeamChannel(channelId: "19:p@thread.tacv2", name: name,
                                     membershipType: mt))
        }
        await model.load()
        await model.createChannel(teamID: "team-1", name: "Priv", description: nil,
                                  membershipType: "private")
        XCTAssertEqual(seen.value, ["private"])
        XCTAssertEqual(model.teams[0].channels.last?.membershipType, "private")
        XCTAssertNil(model.createError)
    }

    func testTypedCreateBlankNameSkipsCore() async {
        let calls = LockedBox(0)
        let model = model { _, _, _, _ in
            calls.mutate { $0 += 1 }
            throw CoreCallError.failed("must not call")
        }
        await model.load()
        await model.createChannel(teamID: "team-1", name: "   ", description: nil,
                                  membershipType: "private")
        XCTAssertEqual(calls.value, 0)
        XCTAssertNil(model.createError)
    }

    // MARK: - Archive toggle

    func testArchiveFlipsFlag() async {
        let model = model()
        await model.load()
        XCTAssertNil(model.teams[0].channels[0].isArchived)
        let ok = await model.archiveChannel(teamID: "team-1", channelID: "19:general@thread.tacv2")
        XCTAssertTrue(ok)
        XCTAssertEqual(model.teams[0].channels[0].isArchived, true)
        XCTAssertNil(model.actionError)
    }

    func testUnarchiveClearsFlag() async {
        let model = model()
        await model.load()
        _ = await model.archiveChannel(teamID: "team-1", channelID: "19:general@thread.tacv2")
        let ok = await model.unarchiveChannel(teamID: "team-1", channelID: "19:general@thread.tacv2")
        XCTAssertTrue(ok)
        XCTAssertEqual(model.teams[0].channels[0].isArchived, false)
    }

    func testArchiveFailureRollsBack() async {
        let model = model(archiver: { _, _ in throw CoreCallError.failed("denied") })
        await model.load()
        let ok = await model.archiveChannel(teamID: "team-1", channelID: "19:general@thread.tacv2")
        XCTAssertFalse(ok)
        XCTAssertNil(model.teams[0].channels[0].isArchived)
        XCTAssertEqual(model.actionError, "denied")
    }

    func testArchiveUnknownChannelReturnsFalse() async {
        let model = model()
        await model.load()
        let ok = await model.archiveChannel(teamID: "team-1", channelID: "nope")
        XCTAssertFalse(ok)
    }

    // MARK: - Archive guards

    func testArchiveGuards() {
        let no = TeamMemberSettings(allowDeleteChannels: false, allowCreateUpdateChannels: false)
        XCTAssertTrue(ChannelRights.evaluate(.archive, isGeneral: false, isOwner: true, settings: no).isAllowed)
        XCTAssertEqual(ChannelRights.evaluate(.archive, isGeneral: false, isOwner: false, settings: no),
                       .denied("Only team owners can archive channels in this team."))
        XCTAssertTrue(ChannelRights.evaluate(.archive, isGeneral: false, isOwner: nil, settings: no).isAllowed)
        XCTAssertEqual(ChannelRights.evaluate(.archive, isGeneral: true, isOwner: true, settings: no),
                       .denied("The General channel can't be archived."))
    }

    // MARK: - Channel roster

    private func roster(
        list: @escaping ChannelMembersViewModel.ListFetcher = { _, _ in
            ChannelMembersResponse(ok: true, members: [
                ChannelMember(id: "m1", displayName: "Ana", userId: "u1",
                              email: "ana@x.com", roles: ["owner"], isOwner: true),
                ChannelMember(id: "m2", displayName: "", userId: "u2",
                              email: "bob@x.com", roles: [], isOwner: false),
            ])
        }
    ) -> ChannelMembersViewModel {
        ChannelMembersViewModel(teamID: "t", channelID: "c", listFetcher: list)
    }

    func testRosterLoadAndFallbacks() async {
        let r = roster()
        await r.load()
        if case .loaded = r.state {} else { return XCTFail("expected loaded") }
        XCTAssertEqual(r.members.count, 2)
        XCTAssertEqual(ChannelMembersViewModel.displayName(for: r.members[1]), "bob@x.com")
        XCTAssertEqual(ChannelMembersViewModel.displayName(
            for: ChannelMember(id: "m3", displayName: "  ")), "m3")
        let sorted = ChannelMembersViewModel.sorted(r.members)
        XCTAssertEqual(sorted.map(\.id), ["m1", "m2"])
    }

    func testRosterAddRemove() async {
        let r = ChannelMembersViewModel(
            teamID: "t", channelID: "c",
            listFetcher: { _, _ in ChannelMembersResponse(ok: true, members: []) },
            addFetcher: { _, _, user, owner in
                ChannelMemberAddResponse(
                    ok: true,
                    member: ChannelMember(id: "m-\(user)", displayName: user, isOwner: owner))
            },
            removeFetcher: { _, _, _ in })
        await r.load()
        if case .empty = r.state {} else { return XCTFail("expected empty") }
        await r.add(user: "zoe@x.com", owner: false)
        if case .loaded = r.state {} else { return XCTFail("expected loaded") }
        XCTAssertEqual(r.members.map(\.id), ["m-zoe@x.com"])
        await r.remove(memberID: "m-zoe@x.com")
        XCTAssertTrue(r.members.isEmpty)
        if case .empty = r.state {} else { return XCTFail("expected empty") }
    }

    func testRosterLoadFailureSurfaces() async {
        let r = ChannelMembersViewModel(
            teamID: "t", channelID: "c",
            listFetcher: { _, _ in throw CoreCallError.failed("down") })
        await r.load()
        if case .error(let msg) = r.state {
            XCTAssertEqual(msg, "down")
        } else {
            XCTFail("expected error")
        }
    }
}
