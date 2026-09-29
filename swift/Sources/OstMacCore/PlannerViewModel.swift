// PlannerViewModel.swift — loads Planner boards via PlannerCore.
import Combine
import Foundation

/// Teams content state (mirrors RemindersState).
public enum PlannerState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty teams in `teams`.
    case loaded
    /// Fetch succeeded with zero teams.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads joined teams off the main thread, owns team selection, the
/// selected team's plans, and the selected plan's buckets + tasks.
/// Default fetchers call `RustCore.teams` / `PlannerCore.*` (blocking
/// network) on detached tasks. Tests inject mock fetchers.
/// `localEdits` (demo mode) applies add/complete/reopen to the
/// in-memory rows instead of calling core, so `--demo` stays offline.
@MainActor
public final class PlannerViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias TeamsFetcher = @Sendable () throws -> TeamsResponse
    public typealias PlansFetcher = @Sendable (String) throws -> PlannerPlansResponse
    public typealias BucketsFetcher = @Sendable (String) throws -> PlannerBucketsResponse
    public typealias TasksFetcher = @Sendable (String) throws -> PlannerTasksResponse
    public typealias AddFetcher = @Sendable (String, String, String) throws -> PlannerTaskResult
    public typealias SetFetcher = @Sendable (String, String) throws -> PlannerTaskResult
    /// (task id, etag, user id, assign) → updated task.
    public typealias AssignFetcher = @Sendable (String, String, String, Bool) throws -> PlannerTaskResult
    public typealias MembersFetcher = @Sendable (String) throws -> TeamMembersResponse

    /// Latest teams (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var teams: [TeamItem] = []
    /// Current teams state. Starts `.loading`.
    @Published public private(set) var state: PlannerState = .loading
    /// Selected team id (first team after load; nil when empty).
    @Published public private(set) var selectedTeamID: String?
    /// Plans of the selected team.
    @Published public private(set) var plans: [PlannerPlan] = []
    /// Selected plan id (first plan after plans load; nil when empty).
    @Published public private(set) var selectedPlanID: String?
    /// Buckets of the selected plan.
    @Published public private(set) var buckets: [PlannerBucket] = []
    /// Tasks of the selected plan (across all buckets).
    @Published public private(set) var tasks: [PlannerTask] = []
    /// Plans/buckets/tasks fetch in flight.
    @Published public private(set) var boardLoading = false
    /// Last board/add/complete/reopen failure (user-facing); nil when clear.
    @Published public private(set) var boardError: String?
    /// Plans of every joined team (team id → plans): the plans-by-team
    /// list (UI-SPEC §6.7). Teams whose plans failed to load are absent.
    @Published public private(set) var plansByTeam: [String: [PlannerPlan]] = [:]
    /// Every team's plans failed to load (user-facing); nil otherwise.
    @Published public private(set) var plansError: String?
    /// Plan the list selected (`show(planID:)`). A (re)load keeps it
    /// instead of falling back to the first team's first plan.
    public private(set) var requestedPlanID: String?
    /// Members of the shown plan's team (assignee names + the Assign
    /// menu), roster order. Empty until the roster lands.
    @Published public private(set) var members: [PlannerMember] = []
    /// Team whose roster `members` holds.
    private var membersTeamID: String?

    private let teamsFetcher: TeamsFetcher
    private let plansFetcher: PlansFetcher
    private let bucketsFetcher: BucketsFetcher
    private let tasksFetcher: TasksFetcher
    private let addFetcher: AddFetcher
    private let doneFetcher: SetFetcher
    private let reopenFetcher: SetFetcher
    private let assignFetcher: AssignFetcher
    private let membersFetcher: MembersFetcher?
    private let localEdits: Bool

    public init(
        teamsFetcher: @escaping TeamsFetcher = { try RustCore.teams() },
        plansFetcher: @escaping PlansFetcher = { try PlannerCore.plans(groupID: $0) },
        bucketsFetcher: @escaping BucketsFetcher = { try PlannerCore.buckets(planID: $0) },
        tasksFetcher: @escaping TasksFetcher = { try PlannerCore.tasks(planID: $0) },
        addFetcher: @escaping AddFetcher = { try PlannerCore.add(planID: $0, bucketID: $1, title: $2) },
        doneFetcher: @escaping SetFetcher = { try PlannerCore.done(taskID: $0, etag: $1) },
        reopenFetcher: @escaping SetFetcher = { try PlannerCore.reopen(taskID: $0, etag: $1) },
        assignFetcher: @escaping AssignFetcher = {
            try PlannerCore.assign(taskID: $0, etag: $1, userID: $2, assign: $3)
        },
        membersFetcher: MembersFetcher? = nil,
        localEdits: Bool = false
    ) {
        self.teamsFetcher = teamsFetcher
        self.plansFetcher = plansFetcher
        self.bucketsFetcher = bucketsFetcher
        self.tasksFetcher = tasksFetcher
        self.addFetcher = addFetcher
        self.doneFetcher = doneFetcher
        self.reopenFetcher = reopenFetcher
        self.assignFetcher = assignFetcher
        self.membersFetcher = membersFetcher
        self.localEdits = localEdits
    }

    /// NOLOAD: last-good snapshot store (nil = memory only / demo).
    public var snapshots: SectionCache?
    static let snapshotKey = "planner"
    /// Boards kept in the snapshot (most recently loaded first).
    static let snapshotBoards = 8

    struct Board: Codable {
        let buckets: [PlannerBucket]
        let tasks: [PlannerTask]
    }

    struct Snapshot: Codable {
        let teams: [TeamItem]
        let plansByTeam: [String: [PlannerPlan]]
        let selectedTeamID: String?
        let selectedPlanID: String?
        let boards: [String: Board]
        let boardOrder: [String]
    }

    /// Boards seen (session + snapshot): reopening one paints at once.
    private var boardCache: [String: Board] = [:]
    private var boardOrder: [String] = []

    /// Paint the last good plans list + boards before any fetch.
    @discardableResult
    public func restoreSnapshot() -> Bool {
        guard let snap = snapshots?.load(Snapshot.self, key: Self.snapshotKey),
              !snap.teams.isEmpty else { return false }
        teams = snap.teams
        plansByTeam = snap.plansByTeam
        boardCache = snap.boards
        boardOrder = snap.boardOrder
        selectedTeamID = snap.selectedTeamID ?? snap.teams.first?.teamId
        plans = selectedTeamID.flatMap { snap.plansByTeam[$0] } ?? []
        selectedPlanID = snap.selectedPlanID
        if let id = snap.selectedPlanID, let board = snap.boards[id] {
            buckets = board.buckets
            tasks = board.tasks
        }
        state = .loaded
        return true
    }

    private func saveSnapshot() {
        guard let snapshots, !teams.isEmpty else { return }
        let keep = Array(boardOrder.prefix(Self.snapshotBoards))
        snapshots.save(Snapshot(
            teams: teams, plansByTeam: plansByTeam, selectedTeamID: selectedTeamID,
            selectedPlanID: selectedPlanID,
            boards: boardCache.filter { keep.contains($0.key) }, boardOrder: keep),
            key: Self.snapshotKey)
    }

    /// Fetch teams, select the first, fetch its plans + first board.
    public func load() async {
        state = .loading
        boardError = nil
        let fetcher = teamsFetcher
        do {
            let response = try await Task.blocking {
                try fetcher()
            }.value
            teams = response.teams
            state = response.teams.isEmpty ? .empty : .loaded
            selectedTeamID = response.teams.first?.teamId
            await loadAllPlans(response.teams)
            if let planID = requestedPlanID {
                // The list's selection wins over the first-plan default.
                adopt(planID: planID)
                await loadBoard(planID: planID)
                return
            }
            if let id = selectedTeamID {
                await loadPlans(teamID: id)
            } else {
                clearBoard()
            }
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry, sign-in).
    public func refresh() {
        Task { await load() }
    }

    /// Select another team and fetch its plans + first board.
    public func selectTeam(teamID: String) {
        guard teamID != selectedTeamID else { return }
        selectedTeamID = teamID
        Task { await loadPlans(teamID: teamID) }
    }

    /// Select another plan and fetch its board.
    public func selectPlan(planID: String) {
        guard planID != selectedPlanID else { return }
        selectedPlanID = planID
        Task { await loadBoard(planID: planID) }
    }

    /// Show one plan's board (list selection, any team). Nil clears the
    /// request only; the board on hand stays. Repeats are no-ops.
    public func show(planID: String?) {
        requestedPlanID = planID
        guard let planID, planID != selectedPlanID else { return }
        adopt(planID: planID)
        // NOLOAD: a board seen before paints at once; refresh behind.
        let cached = boardCache[planID]
        buckets = cached?.buckets ?? []
        tasks = cached?.tasks ?? []
        Task { await loadBoard(planID: planID) }
    }

    /// The team whose plans include `planID`, when loaded.
    public func teamID(containing planID: String) -> String? {
        plansByTeam.first { $0.value.contains { $0.planId == planID } }?.key
    }

    private func adopt(planID: String) {
        if let team = teamID(containing: planID) {
            selectedTeamID = team
            plans = plansByTeam[team] ?? []
        }
        selectedPlanID = planID
    }

    /// Fetch every team's plans concurrently (plans-by-team list).
    private func loadAllPlans(_ teams: [TeamItem]) async {
        let fetcher = plansFetcher
        var out: [String: [PlannerPlan]] = [:]
        var lastError: String?
        await withTaskGroup(of: (String, Result<[PlannerPlan], Error>).self) { group in
            for team in teams {
                let id = team.teamId
                group.addTask {
                    do { return (id, .success(try fetcher(id).plans)) }
                    catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let plans): out[id] = plans
                case .failure(let error): lastError = Self.message(for: error)
                }
            }
        }
        plansByTeam = out
        plansError = !teams.isEmpty && out.isEmpty ? lastError : nil
        if !out.isEmpty { saveSnapshot() }
    }

    /// Refresh the selected plan's board.
    public func refreshBoard() {
        guard let id = selectedPlanID else { return }
        Task { await loadBoard(planID: id) }
    }

    /// Tasks in one bucket, newest last (optionally hiding completed).
    public nonisolated static func visible(
        _ tasks: [PlannerTask], bucketID: String, hideDone: Bool
    ) -> [PlannerTask] {
        tasks.filter {
            $0.bucketId == bucketID && (!hideDone || !$0.completed)
        }
    }

    /// Tasks whose bucket is unknown (defensive: never silently drop rows
    /// when the buckets call lags the tasks call).
    public nonisolated static func orphaned(
        _ tasks: [PlannerTask], buckets: [PlannerBucket]
    ) -> [PlannerTask] {
        let known = Set(buckets.map(\.bucketId))
        return tasks.filter { !known.contains($0.bucketId) }
    }

    /// Add a task to one bucket of the selected plan. Empty titles and
    /// unknown buckets are ignored.
    public func add(bucketID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let planID = selectedPlanID,
              buckets.contains(where: { $0.bucketId == bucketID })
        else { return }
        if localEdits {
            tasks.append(PlannerTask(
                taskId: "demo-ptask-local-\(tasks.count + 1)",
                planId: planID, bucketId: bucketID, title: trimmed))
            boardError = nil
            return
        }
        let fetcher = addFetcher
        boardError = nil
        Task.blocking { [weak self] in
            do {
                let created = try fetcher(planID, bucketID, trimmed)
                await MainActor.run { [weak self] in
                    self?.tasks.append(created.task)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Mark a task completed (100). No-op when already done. The row's
    /// etag feeds `If-Match`; a 412 surfaces in `boardError`.
    public func complete(taskID: String) {
        set(taskID: taskID, complete: true)
    }

    /// Reopen a task (0). No-op when not done.
    public func reopen(taskID: String) {
        set(taskID: taskID, complete: false)
    }

    private func set(taskID: String, complete: Bool) {
        guard let idx = tasks.firstIndex(where: { $0.taskId == taskID }),
              tasks[idx].completed != complete
        else { return }
        if localEdits {
            let row = tasks[idx]
            tasks[idx] = PlannerTask(
                taskId: row.taskId, planId: row.planId,
                bucketId: row.bucketId, title: row.title,
                percent: complete ? 100 : 0, completed: complete,
                priority: row.priority, due: row.due, etag: row.etag)
            return
        }
        let fetcher = complete ? doneFetcher : reopenFetcher
        let etag = tasks[idx].etag
        boardError = nil
        Task.blocking { [weak self] in
            do {
                let updated = try fetcher(taskID, etag)
                await MainActor.run { [weak self] in
                    guard let self,
                          let i = self.tasks.firstIndex(where: { $0.taskId == taskID })
                    else { return }
                    self.tasks[i] = updated.task
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Display name for an assignee id: the team roster's name, else
    /// "Unknown Person" (the roster may lag or the user may have left).
    public func memberName(_ userID: String) -> String {
        members.first { $0.id == userID }?.name ?? "Unknown Person"
    }

    /// Assign (`assigned == true`) or unassign one team member. No-op
    /// when the task already matches. The row's etag feeds `If-Match`;
    /// failures surface in `boardError`.
    public func assign(taskID: String, userID: String, assigned: Bool) {
        guard let idx = tasks.firstIndex(where: { $0.taskId == taskID }),
              tasks[idx].assignees.contains(userID) != assigned
        else { return }
        if localEdits {
            var ids = tasks[idx].assignees.filter { $0 != userID }
            if assigned { ids.append(userID) }
            tasks[idx] = tasks[idx].with(assignees: ids.sorted())
            return
        }
        let fetcher = assignFetcher
        let etag = tasks[idx].etag
        boardError = nil
        Task.blocking { [weak self] in
            do {
                let updated = try fetcher(taskID, etag, userID, assigned)
                await MainActor.run { [weak self] in
                    guard let self,
                          let i = self.tasks.firstIndex(where: { $0.taskId == taskID })
                    else { return }
                    self.tasks[i] = updated.task
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Roster of the shown plan's team (best effort: a failure keeps
    /// the fallback names, never an error state). Once per team.
    private func loadMembers(planID: String) {
        guard let fetcher = membersFetcher,
              let teamID = teamID(containing: planID) ?? selectedTeamID,
              teamID != membersTeamID
        else { return }
        membersTeamID = teamID
        members = []
        Task {
            guard let resp = try? await Task.blocking(operation: { try fetcher(teamID) }).value,
                  teamID == membersTeamID
            else { return }
            members = resp.members.map {
                PlannerMember(id: $0.userId.flatMap { $0.isEmpty ? nil : $0 } ?? $0.id, name: $0.displayName)
            }
        }
    }

    private func loadPlans(teamID: String) async {
        boardLoading = true
        boardError = nil
        clearBoard(keepLoading: true)
        let fetcher = plansFetcher
        do {
            let response = try await Task.blocking {
                try fetcher(teamID)
            }.value
            // Selection may have moved while fetching; only adopt when fresh.
            if teamID == selectedTeamID {
                plans = response.plans
                selectedPlanID = response.plans.first?.planId
                if let planID = selectedPlanID {
                    await loadBoard(planID: planID)
                    return
                }
            }
        } catch {
            if teamID == selectedTeamID {
                boardError = Self.message(for: error)
            }
        }
        if teamID == selectedTeamID {
            boardLoading = false
        }
    }

    private func loadBoard(planID: String) async {
        loadMembers(planID: planID)
        boardLoading = true
        boardError = nil
        let bFetcher = bucketsFetcher
        let tFetcher = tasksFetcher
        do {
            async let bResponse = Task.blocking {
                try bFetcher(planID)
            }.value
            async let tResponse = Task.blocking {
                try tFetcher(planID)
            }.value
            let (buckets, tasks) = try await (bResponse, tResponse)
            // Selection may have moved while fetching; only adopt when fresh.
            if planID == selectedPlanID {
                self.buckets = buckets.buckets
                self.tasks = tasks.tasks
            }
            boardCache[planID] = Board(buckets: buckets.buckets, tasks: tasks.tasks)
            boardOrder.removeAll { $0 == planID }
            boardOrder.insert(planID, at: 0)
            saveSnapshot()
        } catch {
            if planID == selectedPlanID {
                boardError = Self.message(for: error)
            }
        }
        if planID == selectedPlanID {
            boardLoading = false
        }
    }

    private func clearBoard(keepLoading: Bool = false) {
        plans = []
        selectedPlanID = nil
        buckets = []
        tasks = []
        if !keepLoading {
            boardLoading = false
        }
    }

    static func message(for error: Error) -> String {
        FriendlyError.message(for: error)
    }
}
