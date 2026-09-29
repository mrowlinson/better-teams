// TeamRosterViewModel.swift — team roster store (moved verbatim from
// TeamRosterView.swift in the scratch-ui rebuild; the view was deleted,
// the store API is frozen).
import Combine
import Foundation


/// Roster content state (mirrors TeamsState: channels open as
/// conversations but the roster never reorders the browser).
public enum TeamRosterState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty roster in `members`.
    case loaded
    /// Fetch succeeded with zero members.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads one team's roster off the main thread and publishes rows.
///
/// Default fetchers call `RustCore.teamMembers/teamMemberAdd/
/// teamMemberRemove` (blocking FFI + network) on detached tasks.
/// Tests inject mock fetchers.
///
/// Display names come from Graph `displayName` first; blanks fall
/// back to the caller-supplied `names` map (MRI/user-id → name, e.g.
/// adopted from `PresenceStore.resolved` or message senders), then
/// email, then the membership id. See `displayName(for:names:)`.
///
/// Known gaps (not fixed here):
/// - Graph omits/blanks `displayName` for some guests and deleted
///   users; those rows show email or the raw membership id.
/// - The caller MRI map only resolves the `8:orgid:` form
///   (`Mri.isResolvable`); skypeids/visitor/federated ids never
///   resolve and always fall through to email/id.
/// - Guests usually lack `email` and non-AAD entries may lack
///   `userId`; such rows can only show the membership id.
/// - No presence dots: per-member presence fetch is out of scope.
/// - Add/remove need owner rights; a 403 surfaces as the error text.
@MainActor
public final class TeamRosterViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias ListFetcher = @Sendable (String) throws -> TeamMembersResponse
    public typealias AddFetcher = @Sendable (String, String, Bool) throws -> TeamMemberAddResponse
    public typealias RemoveFetcher = @Sendable (String, String) throws -> TeamMemberRemoveResponse

    /// Team this roster belongs to.
    public let teamID: String
    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var members: [TeamMember] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: TeamRosterState = .loading
    /// Caller-supplied name map (MRI or user id → display name).
    /// Adopted from `PresenceStore.resolved` or message senders.
    public var names: [String: String] = [:]

    private let listFetcher: ListFetcher
    private let addFetcher: AddFetcher
    private let removeFetcher: RemoveFetcher

    public init(
        teamID: String,
        listFetcher: @escaping ListFetcher = { try RustCore.teamMembers(teamID: $0) },
        addFetcher: @escaping AddFetcher = { try RustCore.teamMemberAdd(teamID: $0, user: $1, owner: $2) },
        removeFetcher: @escaping RemoveFetcher = { try RustCore.teamMemberRemove(teamID: $0, memberID: $1) }
    ) {
        self.teamID = teamID
        self.listFetcher = listFetcher
        self.addFetcher = addFetcher
        self.removeFetcher = removeFetcher
    }

    /// Display name for one roster entry. Graph `displayName` wins
    /// when non-blank; blank falls back to the caller map (keyed by
    /// user id or `8:orgid:` MRI), then email, then the membership
    /// id. Pure helper so tests pin the fallback chain.
    public nonisolated static func displayName(for member: TeamMember, names: [String: String] = [:]) -> String {
        let direct = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty { return member.displayName }
        if let uid = member.userId {
            if let hit = names[uid] ?? names["8:orgid:\(uid)"] {
                let trimmed = hit.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return hit }
            }
        }
        if let mail = member.email {
            let trimmed = mail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return mail }
        }
        return member.id
    }

    /// Owner rows first (each group sorted by display name),
    /// so the roster reads owners → members. Pure helper.
    public nonisolated static func sorted(_ members: [TeamMember], names: [String: String] = [:]) -> [TeamMember] {
        members.sorted {
            if $0.isOwner != $1.isOwner { return $0.isOwner }
            return displayName(for: $0, names: names)
                .localizedCaseInsensitiveCompare(displayName(for: $1, names: names)) == .orderedAscending
        }
    }

    /// Owner entries of a roster. Pure helper.
    public nonisolated static func owners(of members: [TeamMember]) -> [TeamMember] {
        members.filter(\.isOwner)
    }

    /// Non-owner entries of a roster. Pure helper.
    public nonisolated static func nonOwners(of members: [TeamMember]) -> [TeamMember] {
        members.filter { !$0.isOwner }
    }

    /// Fetch the roster.
    public func load() async {
        state = .loading
        let fetcher = listFetcher
        let teamID = teamID
        do {
            let response = try await Task.blocking {
                try fetcher(teamID)
            }.value
            members = response.members
            state = response.members.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry).
    public func refresh() {
        Task { await load() }
    }

    /// Add one user (id or UPN), optionally as owner. On success the
    /// returned membership is appended and the state flips to
    /// `.loaded`; failure surfaces as `.error`.
    public func add(user: String, owner: Bool) async {
        let fetcher = addFetcher
        let teamID = teamID
        do {
            let response = try await Task.blocking {
                try fetcher(teamID, user, owner)
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
        do {
            let response = try await Task.blocking {
                try fetcher(teamID, memberID)
            }.value
            members.removeAll { $0.id == response.memberId }
            state = members.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Adopt rows without core (tests, previews, demo).
    public func adopt(_ members: [TeamMember]) {
        self.members = members
        state = members.isEmpty ? .empty : .loaded
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }

    /// Rows matching `query` (display name, email, or id,
    /// case-insensitive); empty query matches all. Pure helper.
    /// Moved from TeamRosterView.swift in the scratch-ui rebuild.
    public nonisolated static func filtered(_ members: [TeamMember], query: String, names: [String: String] = [:]) -> [TeamMember] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter { m in
            TeamRosterViewModel.displayName(for: m, names: names).lowercased().contains(q)
                || (m.email ?? "").lowercased().contains(q)
                || m.id.lowercased().contains(q)
        }
    }
}
