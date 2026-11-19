// DemoChannelMembers.swift — channel-roster demo seam (MEMBERSDEMO lane).
//
// The Manage Channel sheet's store (`ChannelMembersViewModel`) talks to a
// `ChannelMembersAPI`. Live uses `LiveChannelMembersAPI` (the RustCore wire:
// blocking FFI + network, so an expired session surfaces there). Demo uses
// `DemoMembersAPI`: a seeded in-memory fake, so the sheet never touches the
// wire in demo mode. Mirrors the `ChannelWorkflowsAPI` seam in
// ChannelWorkflows.swift (`UnavailableWorkflowsAPI` live / `DemoWorkflowsAPI`
// demo).
import Foundation

/// List / add / remove for one private/shared channel's roster.
/// Sync throws: the store runs these off-main (`Task.blocking`), matching
/// the blocking FFI shape of the live source.
public protocol ChannelMembersAPI: Sendable {
    func list(teamID: String, channelID: String) throws -> ChannelMembersResponse
    func add(teamID: String, channelID: String, user: String, owner: Bool) throws -> ChannelMemberAddResponse
    func remove(teamID: String, channelID: String, memberID: String) throws
}

/// The live source: blocking FFI + network through RustCore.
public struct LiveChannelMembersAPI: ChannelMembersAPI {
    public init() {}
    public func list(teamID: String, channelID: String) throws -> ChannelMembersResponse {
        try RustCore.channelMembers(teamID: teamID, channelID: channelID)
    }
    public func add(teamID: String, channelID: String, user: String, owner: Bool) throws -> ChannelMemberAddResponse {
        try RustCore.channelMemberAdd(teamID: teamID, channelID: channelID, user: user, owner: owner)
    }
    public func remove(teamID: String, channelID: String, memberID: String) throws {
        try RustCore.channelMemberRemove(teamID: teamID, channelID: channelID, memberID: memberID)
    }
}

/// Seeded in-memory fake (demo). One owner + two members per channel;
/// add/remove act on the stored rows. No network, never throws.
/// @unchecked: every read/write of `byChannel`/`counter` holds `lock`.
public final class DemoMembersAPI: ChannelMembersAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var byChannel: [String: [ChannelMember]] = [:]
    private var counter = 0

    public init() {}

    private func seed(_ channelID: String) {
        guard byChannel[channelID] == nil else { return }
        byChannel[channelID] = [
            ChannelMember(id: "demo-\(channelID)-m1", displayName: "Megan Harper",
                          userId: "demo-u-megan", email: "megan@example.com",
                          roles: ["owner"], isOwner: true),
            ChannelMember(id: "demo-\(channelID)-m2", displayName: "Tom Becker",
                          userId: "demo-u-tom", email: "tom@example.com"),
            ChannelMember(id: "demo-\(channelID)-m3", displayName: "Ava Lindqvist",
                          userId: "demo-u-ava", email: "ava@example.com"),
        ]
    }

    public func list(teamID: String, channelID: String) throws -> ChannelMembersResponse {
        lock.lock(); defer { lock.unlock() }
        seed(channelID)
        return ChannelMembersResponse(ok: true, members: byChannel[channelID] ?? [])
    }

    public func add(teamID: String, channelID: String, user: String, owner: Bool) throws -> ChannelMemberAddResponse {
        lock.lock(); defer { lock.unlock() }
        seed(channelID)
        counter += 1
        let member = ChannelMember(id: "demo-\(channelID)-added-\(counter)", displayName: user,
                                   userId: user, email: user,
                                   roles: owner ? ["owner"] : [], isOwner: owner)
        byChannel[channelID, default: []].append(member)
        return ChannelMemberAddResponse(ok: true, member: member)
    }

    public func remove(teamID: String, channelID: String, memberID: String) throws {
        lock.lock(); defer { lock.unlock() }
        seed(channelID)
        byChannel[channelID]?.removeAll { $0.id == memberID }
    }
}
