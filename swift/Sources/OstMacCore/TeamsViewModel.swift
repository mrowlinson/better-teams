// TeamsViewModel.swift — loads joined teams via ostmac-core, owns browser state.
import Combine
import Foundation

/// Browser content state (mirrors ChatListState without realtime ingest:
/// channels open as conversations but never reorder the browser).
public enum TeamsState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty list in `teams`.
    case loaded
    /// Fetch succeeded with zero teams.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads the teams list off the main thread and publishes rows.
///
/// Default fetcher calls `RustCore.teams` (blocking network) on a
/// detached task. Tests inject a mock fetcher.
@MainActor
public final class TeamsViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Fetcher = @Sendable () throws -> TeamsResponse
    /// Sync channel create (runs off-main): team id, name, description.
    public typealias Creator = @Sendable (String, String, String?) throws -> ChannelCreateResponse
    /// Sync join-by-id (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Joiner = @Sendable (String) throws -> TeamJoinResponse
    /// Sync team create (runs off-main): name, description.
    public typealias TeamCreator = @Sendable (String, String?) throws -> TeamCreateResponse
    /// Sync public-team search (runs off-main): query. Throws `CoreCallError`.
    public typealias PublicSearcher = @Sendable (String) throws -> PublicTeamsResponse

    /// Latest rows (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var teams: [TeamItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: TeamsState = .loading
    /// Last channel-create failure (user-facing); nil when clear.
    @Published public private(set) var createError: String?
    /// Team ids with a join in flight (drives row spinners).
    @Published public private(set) var joiningIDs: Set<String> = []
    /// Successful joins this session (test/UX counter).
    @Published public private(set) var joinsCompleted: Int = 0
    /// Failed joins this session (test/UX counter).
    @Published public private(set) var joinFailures: Int = 0
    /// Last join failure message, nil after a success or blank noop.
    @Published public private(set) var joinError: String?
    /// Team create in flight (drives the sheet spinner).
    @Published public private(set) var teamCreating = false
    /// Last team-create failure (user-facing); nil when clear.
    @Published public private(set) var teamCreateError: String?
    /// Successful team creates this session (test/UX counter).
    @Published public private(set) var teamsCreated = 0
    /// Public (joinable) teams for `publicQuery`, server-ranked. Joined
    /// teams are included; `isMember(_:)` marks them.
    @Published public private(set) var publicResults: [PublicTeam] = []
    /// Public-team search in flight.
    @Published public private(set) var publicSearching = false
    /// Last public-team search failure (user-facing); nil when clear.
    @Published public private(set) var publicSearchError: String?
    /// Last submitted public-team query (trimmed; empty = cleared).
    @Published public private(set) var publicQuery = ""

    private let fetcher: Fetcher
    private let creator: Creator
    private let joiner: Joiner
    private let teamCreator: TeamCreator
    private let publicSearcher: PublicSearcher
    private var publicGeneration = 0

    public init(
        fetcher: @escaping Fetcher = { try RustCore.teams() },
        creator: @escaping Creator = { try RustCore.channelCreate(teamID: $0, name: $1, description: $2) },
        joiner: @escaping Joiner = { try RustCore.teamJoin(teamID: $0) },
        teamCreator: @escaping TeamCreator = { try RustCore.teamCreate(name: $0, description: $1) },
        publicSearcher: @escaping PublicSearcher = { try RustCore.teamSearch(query: $0) }
    ) {
        self.fetcher = fetcher
        self.creator = creator
        self.joiner = joiner
        self.teamCreator = teamCreator
        self.publicSearcher = publicSearcher
    }

    /// NOLOAD: last-good snapshot store (nil = memory only / demo).
    public var snapshots: SectionCache?
    static let snapshotKey = "teams"

    /// Paint the last good list (launch / account switch) before any
    /// fetch; the next load revalidates behind the rows.
    @discardableResult
    public func restoreSnapshot() -> Bool {
        guard let cached = snapshots?.load([TeamItem].self, key: Self.snapshotKey),
              !cached.isEmpty else { return false }
        teams = cached
        state = .loaded
        return true
    }

    /// Fetch the list.
    public func load() async {
        state = .loading
        let fetcher = fetcher
        do {
            let response = try await Task.detached {
                try fetcher()
            }.value
            teams = response.teams
            state = response.teams.isEmpty ? .empty : .loaded
            snapshots?.save(response.teams, key: Self.snapshotKey)
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry, sign-in).
    public func refresh() {
        Task { await load() }
    }

    /// Account switch (d1-accounts): drop every row + transient state.
    /// Lands on `.empty` (static, no spinner); the caller follows
    /// with `loadQuietly`.
    public func resetForAccount() {
        teams = []
        createError = nil
        joiningIDs = []
        joinError = nil
        teamCreating = false
        teamCreateError = nil
        clearPublicSearch()
        state = .empty
    }

    /// Fetch without the `.loading` spinner (account-switch follow-up
    /// to `resetForAccount`): state only moves when results land.
    public func loadQuietly() async {
        let fetcher = fetcher
        do {
            let response = try await Task.detached {
                try fetcher()
            }.value
            teams = response.teams
            state = response.teams.isEmpty ? .empty : .loaded
            snapshots?.save(response.teams, key: Self.snapshotKey)
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Create one channel in a team, appending the returned row. Blank
    /// names never reach core; an unknown team id (stale list) lands
    /// silently. Failures surface in `createError`.
    public func createChannel(teamID: String, name: String, description: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        createError = nil
        let creator = creator
        do {
            let created = try await Task.detached {
                try creator(teamID, trimmed, description)
            }.value
            guard let idx = teams.firstIndex(where: { $0.teamId == teamID }) else { return }
            let row = teams[idx]
            teams[idx] = TeamItem(
                teamId: row.teamId, name: row.name,
                channels: row.channels + [created.channel])
        } catch {
            createError = Self.message(for: error)
        }
    }

    /// Join one team by id, then reload the list so the new team shows.
    /// Blank ids are a noop (joiner never runs). Runs the blocking join
    /// off-main on a detached task; `joiningIDs` tracks flight.
    public func join(teamID: String) async {
        let id = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        joiningIDs.insert(id)
        let joiner = joiner
        do {
            _ = try await Task.detached {
                try joiner(id)
            }.value
            joiningIDs.remove(id)
            joinsCompleted += 1
            joinError = nil
            await load()
        } catch {
            joiningIDs.remove(id)
            joinFailures += 1
            joinError = Self.message(for: error)
        }
    }

    /// Search public (joinable) teams by name. Blank queries clear
    /// without touching core; stale completions are dropped (fast typing
    /// lands on the newest query). Runs the blocking search off-main.
    public func searchPublic(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        publicGeneration += 1
        let gen = publicGeneration
        publicQuery = q
        guard !q.isEmpty else {
            publicResults = []
            publicSearching = false
            publicSearchError = nil
            return
        }
        publicSearching = true
        publicSearchError = nil
        let searcher = publicSearcher
        let result: Result<[PublicTeam], Error> = await Task.detached {
            do { return .success(try searcher(q).teams) } catch { return .failure(error) }
        }.value
        guard gen == publicGeneration else { return } // superseded
        switch result {
        case .success(let rows):
            publicResults = rows
        case .failure(let error):
            publicResults = []
            publicSearchError = Self.message(for: error)
        }
        publicSearching = false
    }

    /// Drop the public-team query + rows (sheet dismiss).
    public func clearPublicSearch() {
        publicGeneration += 1
        publicResults = []
        publicSearching = false
        publicSearchError = nil
        publicQuery = ""
    }

    /// True when the search hit is already in the joined list.
    public func isMember(_ team: PublicTeam) -> Bool {
        teams.contains { $0.teamId == team.id }
    }

    /// Join a public-team search hit (same path as join-by-id: the hit
    /// id is the team id). Already-joined hits are a noop.
    public func join(publicTeam team: PublicTeam) async {
        guard !isMember(team) else { return }
        await join(teamID: team.id)
    }

    /// Create one standard team, appending the returned row. Blank
    /// names never reach core. Runs the blocking create (POST + poll,
    /// up to ~120s) off-main on a detached task; `teamCreating`
    /// tracks flight. Failures surface in `teamCreateError`.
    public func createTeam(name: String, description: String?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        teamCreateError = nil
        teamCreating = true
        let teamCreator = teamCreator
        do {
            let created = try await Task.detached {
                try teamCreator(trimmed, description)
            }.value
            teamCreating = false
            teamsCreated += 1
            teams.append(created.team)
            if state == .empty { state = .loaded }
        } catch {
            teamCreating = false
            teamCreateError = Self.message(for: error)
        }
    }

    /// Channels matching `query` (case-insensitive); empty query matches all.
    /// Pure helper for the browser filter; team rows stay visible only when
    /// the team name or at least one of their channels matches.
    public nonisolated static func filtered(_ teams: [TeamItem], query: String) -> [TeamItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return teams }
        return teams.compactMap { team in
            if team.name.lowercased().contains(q) { return team }
            let channels = team.channels.filter { $0.name.lowercased().contains(q) }
            guard !channels.isEmpty else { return nil }
            return TeamItem(teamId: team.teamId, name: team.name, channels: channels)
        }
    }

    static func message(for error: Error) -> String {
        FriendlyError.message(for: error)
    }

    // MARK: - Pure browser helpers (moved verbatim from
    // TeamsBrowser.swift in the scratch-ui rebuild; the view was
    // deleted, the helpers stay on the view model).

    /// "Team > #channel" display name for an opened channel.
    /// Pure helper so tests pin the format (DemoData.name must match).
    public nonisolated static func channelDisplayName(team: String, channel: String) -> String {
        "\(team) > #\(channel)"
    }

    /// Disclosure state for one team. Filtering pins every visible team
    /// open so matches are never hidden inside a collapsed group.
    /// Pure helper so tests pin the expand/collapse contract.
    public nonisolated static func isExpanded(teamID: String, collapsed: Set<String>, filtering: Bool) -> Bool {
        if filtering { return true }
        return !collapsed.contains(teamID)
    }

    /// Next collapsed set after toggling one team. Pure helper so tests
    /// pin the per-team toggle (no all-or-nothing side effects).
    public nonisolated static func toggled(_ collapsed: Set<String>, teamID: String) -> Set<String> {
        var out = collapsed
        if out.contains(teamID) {
            out.remove(teamID)
        } else {
            out.insert(teamID)
        }
        return out
    }
}
