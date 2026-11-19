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

    /// Board / Charts / Schedule selection (depth views; board default).
    @Published public var boardView: PlannerBoardView = .board
    /// Task details by task id (depth inspector; empty until loaded).
    @Published public private(set) var detailsByTask: [String: PlannerTaskDetails] = [:]
    /// Comments by thread id (depth inspector; empty until loaded).
    @Published public private(set) var commentsByThread: [String: [PlannerComment]] = [:]

    /// Depth fetchers (labels, details, comments, delete task,
    /// create/delete plan). Nil when the host does not wire them.
    private let depthLabelsFetcher: LabelsFetcher?
    private let depthRenameFetcher: RenameFetcher?
    private let depthDetailsFetcher: DetailsFetcher?
    private let depthChecklistFetcher: ChecklistFetcher?
    private let depthDescriptionFetcher: DescriptionFetcher?
    private let depthReferenceFetcher: ReferenceFetcher?
    private let depthDeleteTaskFetcher: DeleteTaskFetcher?
    private let depthCreatePlanFetcher: CreatePlanFetcher?
    private let depthDeletePlanFetcher: DeletePlanFetcher?
    private let depthCreateBucketFetcher: CreateBucketFetcher?
    private let depthCommentFetcher: CommentFetcher?
    private let depthCommentsFetcher: CommentsFetcher?

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
    /// The shared in-flight full load (launch-r2 dedup).
    private var loadFlight: Task<Void, Never>?

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
        localEdits: Bool = false,
        labelsFetcher: LabelsFetcher? = { try PlannerCore.labels(taskID: $0, etag: $1, category: $2, on: $3) },
        renameFetcher: RenameFetcher? = { try PlannerCore.renameLabels(planID: $0, names: $1) },
        detailsFetcher: DetailsFetcher? = { try PlannerCore.details(taskID: $0) },
        checklistFetcher: ChecklistFetcher? = {
            try PlannerCore.checklist(taskID: $0, etag: $1, itemID: $2, title: $3, checked: $4, remove: $5)
        },
        descriptionFetcher: DescriptionFetcher? = {
            try PlannerCore.description(taskID: $0, etag: $1, description: $2)
        },
        referenceFetcher: ReferenceFetcher? = {
            try PlannerCore.reference(taskID: $0, etag: $1, url: $2, alias: $3, attach: $4)
        },
        deleteTaskFetcher: DeleteTaskFetcher? = { try PlannerCore.deleteTask(taskID: $0, etag: $1) },
        createPlanFetcher: CreatePlanFetcher? = { try PlannerCore.createPlan(groupID: $0, title: $1) },
        deletePlanFetcher: DeletePlanFetcher? = { try PlannerCore.deletePlan(planID: $0) },
        createBucketFetcher: CreateBucketFetcher? = { try PlannerCore.createBucket(planID: $0, name: $1) },
        commentFetcher: CommentFetcher? = { try PlannerCore.comment(groupID: $0, threadID: $1, text: $2) },
        commentsFetcher: CommentsFetcher? = { try PlannerCore.comments(groupID: $0, threadID: $1) }
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
        self.depthLabelsFetcher = labelsFetcher
        self.depthRenameFetcher = renameFetcher
        self.depthDetailsFetcher = detailsFetcher
        self.depthChecklistFetcher = checklistFetcher
        self.depthDescriptionFetcher = descriptionFetcher
        self.depthReferenceFetcher = referenceFetcher
        self.depthDeleteTaskFetcher = deleteTaskFetcher
        self.depthCreatePlanFetcher = createPlanFetcher
        self.depthDeletePlanFetcher = deletePlanFetcher
        self.depthCreateBucketFetcher = createBucketFetcher
        self.depthCommentFetcher = commentFetcher
        self.depthCommentsFetcher = commentsFetcher
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
    /// One in-flight load is shared (launch-r2: sign-in/account/launch
    /// paths fire together) — every waiter gets the same result.
    public func load() async {
        if let flight = loadFlight { await flight.value; return }
        let flight = Task<Void, Never> { await self.runLoad() }
        loadFlight = flight
        await flight.value
        loadFlight = nil
    }

    private func runLoad() async {
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
                // Launch-r2: loadAllPlans just fetched this team's plans —
                // adopt them instead of fetching the same list again
                // (same clear/board flow as loadPlans, minus the fetch).
                // Only refetch when that leg failed (retry).
                if plansByTeam[id] != nil {
                    boardLoading = true
                    boardError = nil
                    clearBoard(keepLoading: true)
                    if id == selectedTeamID {
                        plans = plansByTeam[id] ?? []
                        selectedPlanID = plans.first?.planId
                        if let planID = selectedPlanID {
                            await loadBoard(planID: planID)
                            return
                        }
                    }
                    if id == selectedTeamID {
                        boardLoading = false
                    }
                } else {
                    await loadPlans(teamID: id)
                }
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

// MARK: - plannerdepth: labels, details, comments, delete task, create plan

extension PlannerViewModel {
    /// Set (`on == true`) or clear one label 1-6 on a task.
    public func setLabel(taskID: String, category: Int, on: Bool) {
        guard (1...6).contains(category),
              let idx = tasks.firstIndex(where: { $0.taskId == taskID }),
              tasks[idx].labels.contains(category) != on
        else { return }
        if localEdits {
            var ids = tasks[idx].labels.filter { $0 != category }
            if on { ids.append(category) }
            tasks[idx] = tasks[idx].with(labels: ids)
            return
        }
        guard let fetcher = depthLabelsFetcher else { return }
        let etag = tasks[idx].etag
        boardError = nil
        Task.blocking { [weak self] in
            do {
                let updated = try fetcher(taskID, etag, category, on)
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

    /// Rename plan labels (display names by number). The service
    /// currently ignores the write (API-limited); the plan list still
    /// refreshes so a working write paints at once.
    public func renameLabels(planID: String, names: [Int: String]) {
        let clean = names.filter {
            (1...6).contains($0.key)
                && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !clean.isEmpty else { return }
        if localEdits { return } // demo names come from fixtures
        guard let fetcher = depthRenameFetcher else { return }
        boardError = nil
        Task.blocking { [weak self] in
            do {
                let result = try fetcher(planID, clean)
                await MainActor.run { [weak self] in
                    self?.adoptPlanResult(result.plan)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Adopt a created/renamed plan into the plans-by-team list.
    func adoptPlanResult(_ plan: PlannerPlan) {
        guard let team = teamID(containing: plan.planId) ?? selectedTeamID else { return }
        var list = plansByTeam[team] ?? []
        if let i = list.firstIndex(where: { $0.planId == plan.planId }) {
            list[i] = plan
        } else {
            list.append(plan)
        }
        plansByTeam[team] = list
        if team == selectedTeamID {
            plans = list
            if selectedPlanID == nil { selectedPlanID = plan.planId }
        }
    }

    /// Load one task's details + comments (inspector). Demo resolves
    /// fixtures synchronously; live refreshes behind the cached rows.
    public func loadDetails(taskID: String) {
        if localEdits {
            detailsByTask[taskID] = PlannerDemo.details(for: taskID)
            if let task = tasks.first(where: { $0.taskId == taskID }),
               !task.threadID.isEmpty {
                commentsByThread[task.threadID] = PlannerDemo.comments(for: taskID)
            } else {
                commentsByThread[taskID] = PlannerDemo.comments(for: taskID)
            }
            return
        }
        guard let fetcher = depthDetailsFetcher else { return }
        Task.blocking { [weak self] in
            do {
                let response = try fetcher(taskID)
                await MainActor.run { [weak self] in
                    self?.detailsByTask[taskID] = response.details
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
        loadComments(taskID: taskID)
    }

    /// Cached details etag for a task (checklist/description/reference
    /// writes send it back).
    func detailsEtag(taskID: String) -> String? {
        let etag = detailsByTask[taskID]?.etag
        return (etag?.isEmpty == false) ? etag : nil
    }

    /// Refresh cached details after a write (best effort: failure keeps
    /// the stale rows, never an error state).
    private func refreshDetails(taskID: String) {
        guard let fetcher = depthDetailsFetcher else { return }
        Task.blocking { [weak self] in
            guard let response = try? fetcher(taskID) else { return }
            await MainActor.run { [weak self] in
                self?.detailsByTask[taskID] = response.details
            }
        }
    }

    /// Toggle one checklist item (title round-trips unchanged).
    public func toggleChecklist(taskID: String, itemID: String) {
        guard let item = detailsByTask[taskID]?.checklist.first(where: { $0.itemId == itemID }) else { return }
        setChecklist(taskID: taskID, itemID: itemID, title: item.title, checked: !item.checked, remove: false)
    }

    /// Add one checklist item.
    public func addChecklist(taskID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setChecklist(taskID: taskID, itemID: "", title: trimmed, checked: false, remove: false)
    }

    /// Remove one checklist item.
    public func removeChecklist(taskID: String, itemID: String) {
        setChecklist(taskID: taskID, itemID: itemID, title: "", checked: false, remove: true)
    }

    private func setChecklist(taskID: String, itemID: String, title: String, checked: Bool, remove: Bool) {
        if localEdits {
            var details = detailsByTask[taskID] ?? PlannerDemo.details(for: taskID)
            if remove {
                details = PlannerTaskDetails(
                    etag: details.etag, description: details.description, preview: details.preview,
                    checklist: details.checklist.filter { $0.itemId != itemID },
                    references: details.references)
            } else if itemID.isEmpty {
                let item = PlannerChecklistItem(
                    itemId: "demo-check-local-\(details.checklist.count + 1)",
                    title: title, checked: checked)
                details = PlannerTaskDetails(
                    etag: details.etag, description: details.description, preview: details.preview,
                    checklist: details.checklist + [item], references: details.references)
            } else {
                details = PlannerTaskDetails(
                    etag: details.etag, description: details.description, preview: details.preview,
                    checklist: details.checklist.map {
                        $0.itemId == itemID
                            ? PlannerChecklistItem(itemId: $0.itemId, title: title, checked: checked)
                            : $0
                    },
                    references: details.references)
            }
            detailsByTask[taskID] = details
            return
        }
        guard let etag = detailsEtag(taskID: taskID),
              let fetcher = depthChecklistFetcher else { return }
        boardError = nil
        Task.blocking { [weak self] in
            do {
                try fetcher(taskID, etag, itemID, title, checked, remove)
                await MainActor.run { [weak self] in
                    self?.refreshDetails(taskID: taskID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    public func setDescription(taskID: String, description: String) {
        if localEdits {
            let details = detailsByTask[taskID] ?? PlannerDemo.details(for: taskID)
            detailsByTask[taskID] = PlannerTaskDetails(
                etag: details.etag, description: description, preview: details.preview,
                checklist: details.checklist, references: details.references)
            return
        }
        guard let etag = detailsEtag(taskID: taskID),
              let fetcher = depthDescriptionFetcher else { return }
        boardError = nil
        Task.blocking { [weak self] in
            do {
                try fetcher(taskID, etag, description)
                await MainActor.run { [weak self] in
                    self?.refreshDetails(taskID: taskID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    public func addReference(taskID: String, url: String, alias: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return }
        setReference(taskID: taskID, url: trimmed, alias: alias, attach: true)
    }

    public func removeReference(taskID: String, url: String) {
        setReference(taskID: taskID, url: url, alias: "", attach: false)
    }

    private func setReference(taskID: String, url: String, alias: String, attach: Bool) {
        if localEdits {
            let details = detailsByTask[taskID] ?? PlannerDemo.details(for: taskID)
            var refs = details.references.filter { $0.url != url }
            if attach {
                refs.append(PlannerReference(url: url, alias: alias.isEmpty ? url : alias))
            }
            detailsByTask[taskID] = PlannerTaskDetails(
                etag: details.etag, description: details.description, preview: details.preview,
                checklist: details.checklist, references: refs)
            return
        }
        guard let etag = detailsEtag(taskID: taskID),
              let fetcher = depthReferenceFetcher else { return }
        boardError = nil
        Task.blocking { [weak self] in
            do {
                try fetcher(taskID, etag, url, alias, attach)
                await MainActor.run { [weak self] in
                    self?.refreshDetails(taskID: taskID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Load a task's thread posts (no thread yet: clears to none).
    public func loadComments(taskID: String) {
        guard let task = tasks.first(where: { $0.taskId == taskID }) else { return }
        if localEdits { return } // loadDetails already set fixtures
        guard !task.threadID.isEmpty,
              let team = teamID(containing: task.planId),
              let fetcher = depthCommentsFetcher else {
            if !task.threadID.isEmpty { commentsByThread[task.threadID] = [] }
            return
        }
        let thread = task.threadID
        Task.blocking { [weak self] in
            do {
                let response = try fetcher(team, thread)
                await MainActor.run { [weak self] in
                    self?.commentsByThread[thread] = response.posts
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Post one comment to a task's thread, then re-read the posts.
    public func postComment(taskID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let task = tasks.first(where: { $0.taskId == taskID }),
              !task.threadID.isEmpty,
              let team = teamID(containing: task.planId)
        else { return }
        if localEdits {
            let post = PlannerComment(
                id: "demo-post-local-\((commentsByThread[task.threadID]?.count ?? 0) + 1)",
                kind: "Text", content: trimmed)
            commentsByThread[task.threadID, default: []].append(post)
            return
        }
        guard let poster = depthCommentFetcher,
              let reader = depthCommentsFetcher else { return }
        boardError = nil
        Task.blocking { [weak self] in
            do {
                try poster(team, task.threadID, trimmed)
                let response = try reader(team, task.threadID)
                await MainActor.run { [weak self] in
                    self?.commentsByThread[task.threadID] = response.posts
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Delete one task (confirmation lives in the UI). The row drops at
    /// once; the selection clears because the task is gone.
    public func deleteTask(taskID: String) {
        guard let idx = tasks.firstIndex(where: { $0.taskId == taskID }) else { return }
        if localEdits {
            tasks.remove(at: idx)
            detailsByTask.removeValue(forKey: taskID)
            return
        }
        guard let fetcher = depthDeleteTaskFetcher else { return }
        let etag = tasks[idx].etag
        boardError = nil
        Task.blocking { [weak self] in
            do {
                try fetcher(taskID, etag)
                await MainActor.run { [weak self] in
                    guard let self,
                          let i = self.tasks.firstIndex(where: { $0.taskId == taskID })
                    else { return }
                    self.tasks.remove(at: i)
                    self.detailsByTask.removeValue(forKey: taskID)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Create one plan under a team, with a first bucket, then show it.
    public func createPlan(teamID: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if localEdits {
            let plan = PlannerPlan(planId: "demo-plan-local-\(plansByTeam.count + 1)", title: trimmed)
            adoptPlanResult(plan)
            selectedTeamID = teamID
            plans = plansByTeam[teamID] ?? []
            selectPlan(planID: plan.planId)
            return
        }
        guard let planFetcher = depthCreatePlanFetcher else { return }
        let bucketFetcher = depthCreateBucketFetcher
        boardError = nil
        Task.blocking { [weak self] in
            do {
                let result = try planFetcher(teamID, trimmed)
                if let bucket = try? bucketFetcher?(result.plan.planId, "To do") {
                    await MainActor.run { [weak self] in
                        self?.buckets.append(bucket.bucket)
                    }
                }
                await MainActor.run { [weak self] in
                    self?.adoptPlanResult(result.plan)
                    self?.show(planID: result.plan.planId)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }

    /// Delete one plan (confirmation lives in the UI). Falls back to
    /// the team's first remaining plan.
    public func deletePlan(planID: String) {
        guard plansByTeam.values.contains(where: { $0.contains(where: { $0.planId == planID }) }) else { return }
        if localEdits {
            for team in plansByTeam.keys {
                plansByTeam[team]?.removeAll { $0.planId == planID }
            }
            plans.removeAll { $0.planId == planID }
            if selectedPlanID == planID {
                selectedPlanID = plans.first?.planId
            }
            return
        }
        guard let fetcher = depthDeletePlanFetcher else { return }
        boardError = nil
        Task.blocking { [weak self] in
            do {
                try fetcher(planID)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for team in self.plansByTeam.keys {
                        self.plansByTeam[team]?.removeAll { $0.planId == planID }
                    }
                    self.plans.removeAll { $0.planId == planID }
                    if self.selectedPlanID == planID {
                        let next = self.plans.first?.planId
                        self.selectedPlanID = next
                        if let next { self.show(planID: next) }
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.boardError = Self.message(for: error)
                }
            }
        }
    }
}
