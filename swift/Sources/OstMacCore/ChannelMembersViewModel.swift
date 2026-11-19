// ChannelMembersViewModel.swift — private/shared channel roster store
// (mirrors TeamRosterViewModel; the view was built for this lane).
import Combine
import Foundation

/// Loads one private/shared channel's roster off the main thread and
/// publishes rows.
///
/// Default fetchers call `RustCore.channelMembers/channelMemberAdd/
/// channelMemberRemove` (blocking FFI + network) on detached tasks.
/// Tests inject mock fetchers.
///
/// Standard channels share the team roster — this store is only for
/// channels whose `membershipType` is private/shared.
@MainActor
public final class ChannelMembersViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias ListFetcher = @Sendable (String, String) throws -> ChannelMembersResponse
    public typealias AddFetcher = @Sendable (String, String, String, Bool) throws -> ChannelMemberAddResponse
    public typealias RemoveFetcher = @Sendable (String, String, String) throws -> Void

    /// Team and channel this roster belongs to.
    public let teamID: String
    public let channelID: String
    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var members: [ChannelMember] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: TeamRosterState = .loading

    private let listFetcher: ListFetcher
    private let addFetcher: AddFetcher
    private let removeFetcher: RemoveFetcher

    public init(
        teamID: String,
        channelID: String,
        listFetcher: @escaping ListFetcher = { try RustCore.channelMembers(teamID: $0, channelID: $1) },
        addFetcher: @escaping AddFetcher = { try RustCore.channelMemberAdd(teamID: $0, channelID: $1, user: $2, owner: $3) },
        removeFetcher: @escaping RemoveFetcher = { try RustCore.channelMemberRemove(teamID: $0, channelID: $1, memberID: $2) }
    ) {
        self.teamID = teamID
        self.channelID = channelID
        self.listFetcher = listFetcher
        self.addFetcher = addFetcher
        self.removeFetcher = removeFetcher
    }

    /// API-backed construction (demo seam: `DemoMembersAPI` in demo,
    /// `LiveChannelMembersAPI` on the wire). The default-fetcher init
    /// above stays the live wire.
    public convenience init(teamID: String, channelID: String, api: ChannelMembersAPI) {
        self.init(
            teamID: teamID,
            channelID: channelID,
            listFetcher: { try api.list(teamID: $0, channelID: $1) },
            addFetcher: { try api.add(teamID: $0, channelID: $1, user: $2, owner: $3) },
            removeFetcher: { try api.remove(teamID: $0, channelID: $1, memberID: $2) }
        )
    }

    /// Display name for one roster entry. Graph `displayName` wins
    /// when non-blank, then email, then the membership id. Pure helper
    /// so tests pin the fallback chain.
    public nonisolated static func displayName(for member: ChannelMember) -> String {
        let direct = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty { return member.displayName }
        if let mail = member.email {
            let trimmed = mail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return mail }
        }
        return member.id
    }

    /// Owner rows first (each group sorted by display name).
    /// Pure helper.
    public nonisolated static func sorted(_ members: [ChannelMember]) -> [ChannelMember] {
        members.sorted {
            if $0.isOwner != $1.isOwner { return $0.isOwner }
            return displayName(for: $0)
                .localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    /// Fetch the roster.
    public func load() async {
        state = .loading
        let fetcher = listFetcher
        let teamID = teamID
        let channelID = channelID
        do {
            let response = try await Task.blocking {
                try fetcher(teamID, channelID)
            }.value
            members = response.members
            state = response.members.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Add one user (id or UPN), optionally as owner. On success the
    /// returned membership is appended; failure surfaces as `.error`.
    public func add(user: String, owner: Bool) async {
        let fetcher = addFetcher
        let teamID = teamID
        let channelID = channelID
        do {
            let response = try await Task.blocking {
                try fetcher(teamID, channelID, user, owner)
            }.value
            members.append(response.member)
            state = .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Remove one membership id. On success the row is dropped
    /// locally (empty roster flips to `.empty`); failure surfaces
    /// as `.error` and keeps the row.
    public func remove(memberID: String) async {
        let fetcher = removeFetcher
        let teamID = teamID
        let channelID = channelID
        do {
            try await Task.blocking {
                try fetcher(teamID, channelID, memberID)
            }.value
            members.removeAll { $0.id == memberID }
            state = members.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Adopt rows without core (tests, previews, demo).
    public func adopt(_ members: [ChannelMember]) {
        self.members = members
        state = members.isEmpty ? .empty : .loaded
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
