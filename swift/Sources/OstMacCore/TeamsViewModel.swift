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
    /// Sync channel delete (runs off-main): team id, channel id.
    public typealias ChannelDeleter = @Sendable (String, String) throws -> Void
    /// Sync channel edit (runs off-main): team id, channel id, new name
    /// (nil = unchanged), new description (nil = unchanged).
    public typealias ChannelUpdater = @Sendable (String, String, String?, String?) throws -> Void
    /// Sync leave-team (runs off-main): team id.
    public typealias TeamLeaver = @Sendable (String) throws -> Void
    /// Sync read-only ownership check (runs off-main): team id.
    public typealias OwnerCheck = @Sendable (String) throws -> Bool
    /// Sync read-only member-permission read (runs off-main): team id.
    public typealias SettingsFetcher = @Sendable (String) throws -> TeamMemberSettings

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
    /// Last channel/team menu action failure (user-facing); nil when
    /// clear. Optimistic edits are rolled back before this is set.
    @Published public private(set) var actionError: String?
    /// Teams the signed-in user owns (gates Edit/Delete channel).
    @Published public private(set) var ownedTeamIDs: Set<String> = []
    /// Teams where the ownership read answered "not an owner" (vs an
    /// unknown answer, which stays out of both sets).
    @Published public private(set) var notOwnedTeamIDs: Set<String> = []
    /// Member permissions + General channel id per team (unknown fields nil).
    @Published public private(set) var memberSettings: [String: TeamMemberSettings] = [:]
    /// Channels that vanished from the tree while known (deleted here
    /// or elsewhere); an open one shows the deleted state. Cleared when
    /// the id comes back.
    @Published public private(set) var deletedChannelIDs: Set<String> = []
    /// Tree refreshes that changed rows (test/UX counter).
    @Published public private(set) var syncChanges = 0

    private let fetcher: Fetcher
    private let creator: Creator
    private let joiner: Joiner
    private let teamCreator: TeamCreator
    private let publicSearcher: PublicSearcher
    private var publicGeneration = 0
    private let channelDeleter: ChannelDeleter
    private let channelUpdater: ChannelUpdater
    private let teamLeaver: TeamLeaver
    private let ownerCheck: OwnerCheck
    private let settingsFetcher: SettingsFetcher
    /// When each team's rights were last asked.
    private var ownershipAskedAt: [String: Date] = [:]
    /// Seconds before a team's rights are read again (permissions can
    /// change while the app stays open).
    public nonisolated static let rightsTTL: TimeInterval = 300
    /// Menu writes in flight: a sync landing mid-write would resurrect
    /// the optimistic change, so sync results wait for zero.
    private var pendingWrites = 0
    private var syncing = false

    public init(
        fetcher: @escaping Fetcher = { try RustCore.teams() },
        creator: @escaping Creator = { try RustCore.channelCreate(teamID: $0, name: $1, description: $2) },
        joiner: @escaping Joiner = { try RustCore.teamJoin(teamID: $0) },
        teamCreator: @escaping TeamCreator = { try RustCore.teamCreate(name: $0, description: $1) },
        publicSearcher: @escaping PublicSearcher = { try RustCore.teamSearch(query: $0) },
        channelDeleter: @escaping ChannelDeleter = { try RustCore.channelDelete(teamID: $0, channelID: $1) },
        channelUpdater: @escaping ChannelUpdater = {
            try RustCore.channelUpdate(teamID: $0, channelID: $1, name: $2, description: $3)
        },
        teamLeaver: @escaping TeamLeaver = { try RustCore.teamLeave(teamID: $0) },
        ownerCheck: @escaping OwnerCheck = { try RustCore.isTeamOwner(teamID: $0) },
        settingsFetcher: @escaping SettingsFetcher = { try RustCore.teamSettings(teamID: $0) }
    ) {
        self.fetcher = fetcher
        self.creator = creator
        self.joiner = joiner
        self.teamCreator = teamCreator
        self.publicSearcher = publicSearcher
        self.channelDeleter = channelDeleter
        self.channelUpdater = channelUpdater
        self.teamLeaver = teamLeaver
        self.ownerCheck = ownerCheck
        self.settingsFetcher = settingsFetcher
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
        teams = ChannelRights.generalFirst(cached, primary: primaryIDs)
        state = .loaded
        return true
    }

    /// Fetch the list.
    public func load() async {
        state = .loading
        let fetcher = fetcher
        do {
            let response = try await Task.blocking {
                try fetcher()
            }.value
            let rows = arranged(response.teams)
            teams = rows
            state = rows.isEmpty ? .empty : .loaded
            snapshots?.save(rows, key: Self.snapshotKey)
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
        actionError = nil
        ownedTeamIDs = []
        notOwnedTeamIDs = []
        memberSettings = [:]
        ownershipAskedAt = [:]
        deletedChannelIDs = []
        state = .empty
    }

    /// Fetch without the `.loading` spinner (account-switch follow-up
    /// to `resetForAccount`): state only moves when results land.
    public func loadQuietly() async {
        let fetcher = fetcher
        do {
            let response = try await Task.blocking {
                try fetcher()
            }.value
            let rows = arranged(response.teams)
            teams = rows
            state = rows.isEmpty ? .empty : .loaded
            snapshots?.save(rows, key: Self.snapshotKey)
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
            let created = try await Task.blocking {
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
            _ = try await Task.blocking {
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
        let result: Result<[PublicTeam], Error> = await Task.blocking {
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
            let created = try await Task.blocking {
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

    // MARK: - Tree sync (TEAMSYNC: changes made elsewhere)

    /// Quiet tree refresh at utility priority: never shows a spinner,
    /// never drops rows on failure, and publishes only when the tree
    /// actually changed (stable list, selection and scroll kept).
    /// Returns false when the fetch failed (caller backs off).
    @discardableResult
    public func sync() async -> Bool {
        guard !syncing else { return true }
        syncing = true
        defer { syncing = false }
        let fetcher = fetcher
        do {
            let response = try await Task.blocking(priority: .utility) {
                try fetcher()
            }.value
            // A menu write landed mid-fetch: this snapshot may predate
            // it, so skip rather than resurrect the optimistic edit.
            guard pendingWrites == 0 else { return true }
            apply(response.teams)
            return true
        } catch {
            if teams.isEmpty, state == .loading { state = .error(Self.message(for: error)) }
            return false
        }
    }

    /// Diff-apply one fetched tree: identical trees publish nothing;
    /// changed trees replace rows in server order (ids stable, so the
    /// list keeps selection and scroll) and record vanished channels.
    public func apply(_ response: [TeamItem]) {
        let fresh = arranged(response)
        let freshIDs = Set(fresh.flatMap { $0.channels.map(\.channelId) })
        let gone = Set(teams.flatMap { $0.channels.map(\.channelId) }).subtracting(freshIDs)
        let back = deletedChannelIDs.intersection(freshIDs)
        if !gone.isEmpty || !back.isEmpty {
            deletedChannelIDs = deletedChannelIDs.union(gone).subtracting(back)
        }
        let newState: TeamsState = fresh.isEmpty ? .empty : .loaded
        if state != newState { state = newState }
        guard fresh != teams else { return }
        teams = fresh
        syncChanges += 1
        snapshots?.save(fresh, key: Self.snapshotKey)
    }

    /// Ask (read-only) whether the user owns each team, and what the
    /// team lets members do, for every team not asked within
    /// `rightsTTL`. Each read stands alone: a failure leaves that fact
    /// unknown (never "no"). Answers gate Edit/Delete channel and pin
    /// General first.
    public func refreshOwnership() async {
        let now = Date()
        let ask = teams.map(\.teamId).filter { id in
            guard let at = ownershipAskedAt[id] else { return true }
            return now.timeIntervalSince(at) >= Self.rightsTTL
        }
        guard !ask.isEmpty else { return }
        for id in ask { ownershipAskedAt[id] = now }
        let check = ownerCheck
        let fetch = settingsFetcher
        for id in ask {
            let owns = try? await Task.blocking(priority: .utility) { try check(id) }.value
            if owns == true {
                ownedTeamIDs.insert(id); notOwnedTeamIDs.remove(id)
            } else if owns == false {
                ownedTeamIDs.remove(id); notOwnedTeamIDs.insert(id)
            } else {
                ownedTeamIDs.remove(id); notOwnedTeamIDs.remove(id)
            }
            if let settings = try? await Task.blocking(priority: .utility, operation: { try fetch(id) }).value,
               memberSettings[id] != settings {
                memberSettings[id] = settings
            }
        }
        let rows = arranged(teams)
        if rows != teams { teams = rows }
    }

    /// Whether channel writes (edit/delete) are offered for `teamID` to
    /// a confirmed owner. Menus use `permission(_:teamID:channelID:)`.
    public func canManageChannels(teamID: String) -> Bool {
        ownedTeamIDs.contains(teamID)
    }

    /// The gate behind the channel menu and the Conversation menu:
    /// enabled, or disabled with the reason to show.
    public func permission(_ action: ChannelAction, teamID: String, channelID: String) -> ChannelPermission {
        let settings = memberSettings[teamID]
        let owner: Bool? = ownedTeamIDs.contains(teamID) ? true : (notOwnedTeamIDs.contains(teamID) ? false : nil)
        return ChannelRights.evaluate(
            action, isGeneral: isGeneral(teamID: teamID, channelID: channelID), isOwner: owner, settings: settings)
    }

    /// True when `channelID` is its team's General channel.
    public func isGeneral(teamID: String, channelID: String) -> Bool {
        let primary = memberSettings[teamID]?.primaryChannelId
        guard let ch = teams.first(where: { $0.teamId == teamID })?.channels.first(where: { $0.channelId == channelID })
        else { return primary == channelID }
        return ChannelRights.isGeneral(ch, primaryID: primary)
    }

    private var primaryIDs: [String: String] {
        memberSettings.compactMapValues(\.primaryChannelId)
    }

    /// One fetched tree made ready to show: a team that comes back with
    /// no channels while it had some is a failed channel read (every
    /// team has General), so its old rows stay; General goes first.
    private func arranged(_ fresh: [TeamItem]) -> [TeamItem] {
        let old = Dictionary(teams.map { ($0.teamId, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = fresh.map { t -> TeamItem in
            guard t.channels.isEmpty, let prev = old[t.teamId], !prev.channels.isEmpty else { return t }
            return TeamItem(teamId: t.teamId, name: t.name, channels: prev.channels)
        }
        return ChannelRights.generalFirst(kept, primary: primaryIDs)
    }

    // MARK: - Menu writes (optimistic, rolled back on failure)

    /// Delete one channel: the row leaves at once; a failed delete puts
    /// it back where it was and sets `actionError`. Returns success.
    @discardableResult
    public func deleteChannel(teamID: String, channelID: String) async -> Bool {
        guard let ti = teams.firstIndex(where: { $0.teamId == teamID }),
              teams[ti].channels.contains(where: { $0.channelId == channelID }) else { return false }
        let before = teams
        let row = teams[ti]
        teams[ti] = TeamItem(teamId: row.teamId, name: row.name,
                             channels: row.channels.filter { $0.channelId != channelID })
        deletedChannelIDs.insert(channelID)
        actionError = nil
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        let deleter = channelDeleter
        do {
            try await Task.blocking { try deleter(teamID, channelID) }.value
            snapshots?.save(teams, key: Self.snapshotKey)
            return true
        } catch {
            teams = before
            deletedChannelIDs.remove(channelID)
            actionError = Self.message(for: error)
            return false
        }
    }

    /// Rename / re-describe one channel: the row changes at once and
    /// reverts on failure. Blank names are ignored (name unchanged).
    @discardableResult
    public func updateChannel(
        teamID: String, channelID: String, name: String?, description: String?
    ) async -> Bool {
        let newName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantName = (newName?.isEmpty == false) ? newName : nil
        let wantDesc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wantName != nil || wantDesc != nil,
              let ti = teams.firstIndex(where: { $0.teamId == teamID }),
              let ci = teams[ti].channels.firstIndex(where: { $0.channelId == channelID })
        else { return false }
        let before = teams
        let old = teams[ti].channels[ci]
        var channels = teams[ti].channels
        channels[ci] = TeamChannel(
            channelId: old.channelId, name: wantName ?? old.name,
            description: wantDesc.map { $0.isEmpty ? nil : $0 } ?? old.description,
            membershipType: old.membershipType, webUrl: old.webUrl, email: old.email)
        teams[ti] = TeamItem(teamId: teams[ti].teamId, name: teams[ti].name, channels: channels)
        actionError = nil
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        let updater = channelUpdater
        do {
            try await Task.blocking { try updater(teamID, channelID, wantName, wantDesc) }.value
            snapshots?.save(teams, key: Self.snapshotKey)
            return true
        } catch {
            teams = before
            actionError = Self.message(for: error)
            return false
        }
    }

    /// Leave one team: the team leaves the tree at once and comes back
    /// on failure. Returns success.
    @discardableResult
    public func leaveTeam(teamID: String) async -> Bool {
        guard let ti = teams.firstIndex(where: { $0.teamId == teamID }) else { return false }
        let before = teams
        let gone = Set(teams[ti].channels.map(\.channelId))
        teams.remove(at: ti)
        if teams.isEmpty { state = .empty }
        actionError = nil
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        let leaver = teamLeaver
        do {
            try await Task.blocking { try leaver(teamID) }.value
            deletedChannelIDs.formUnion(gone)
            ownedTeamIDs.remove(teamID)
            snapshots?.save(teams, key: Self.snapshotKey)
            return true
        } catch {
            teams = before
            state = .loaded
            actionError = Self.message(for: error)
            return false
        }
    }

    /// Dismiss the last menu-action failure.
    public func clearActionError() { actionError = nil }

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
