// Health.swift — om-steal-ids lane: per-audience token health + diagnostics UI.
//
// Port of weirdapps teams-access `src/commands/health-check.ts` (MIT):
// one timed read per surface, per-probe status, ok/degraded/broken
// verdict. Adapted to ost's derived-token slots (aad/graph/ic3/recorder/
// skype live in the TOML config, not a multi-audience session file):
// the token layer is offline (status slots), the probe layer is live
// (whoami + teams exercise the Graph token, chats the Skype token).
//
//   let health = HealthStore() // live core fetchers
//   await health.run()         // fills `report` (Settings diagnostics)
// Tests inject mock fetchers (same seam as PresenceStore).
import Foundation
import Combine

/// Token health + live probes. All fetches run off-main (blocking network/FFI).
@MainActor
public final class HealthStore: ObservableObject {
    public typealias StatusFetcher = @Sendable () throws -> StatusResponse
    public typealias MeFetcher = @Sendable () throws -> WhoamiResponse
    public typealias TeamsFetcher = @Sendable () throws -> TeamsResponse
    public typealias ChatsFetcher = @Sendable (Int32) throws -> ChatsResponse

    /// Last full report; nil until the first successful status read.
    @Published public private(set) var report: HealthReport?
    /// Status-read failure (probes never fail the run, they fail in place).
    @Published public private(set) var error: String?
    @Published public private(set) var running = false

    private let statusFetcher: StatusFetcher
    private let meFetcher: MeFetcher
    private let teamsFetcher: TeamsFetcher
    private let chatsFetcher: ChatsFetcher
    /// Per-fetch ceiling (om-settings-org): the core fetchers are
    /// blocking calls with no timeout of their own, so a wedged core
    /// used to stick `running` (and the "Checking…" badge) forever.
    /// Every fetch now races this clock; timeouts fail the status
    /// read or the probe in place, and `running` always clears.
    private let timeoutSeconds: Double

    /// Nonisolated so views can take a default `HealthStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        statusFetcher: @escaping StatusFetcher = { try RustCore.status() },
        meFetcher: @escaping MeFetcher = { try RustCore.whoami() },
        teamsFetcher: @escaping TeamsFetcher = { try RustCore.teams() },
        chatsFetcher: @escaping ChatsFetcher = { try RustCore.chats(limit: $0) },
        timeoutSeconds: Double = 30
    ) {
        self.statusFetcher = statusFetcher
        self.meFetcher = meFetcher
        self.teamsFetcher = teamsFetcher
        self.chatsFetcher = chatsFetcher
        self.timeoutSeconds = timeoutSeconds
    }

    /// Offline token slots from a status response (pure, tested).
    public static func tokenSlots(_ st: StatusResponse) -> [HealthToken] {
        [
            HealthToken(audience: "aad", present: st.tokens.aad.present, expired: st.tokens.aad.expired),
            HealthToken(audience: "graph", present: st.tokens.graph.present, expired: st.tokens.graph.expired),
            HealthToken(audience: "ic3", present: st.tokens.ic3.present, expired: st.tokens.ic3.expired),
            HealthToken(audience: "recorder", present: st.tokens.recorder.present, expired: st.tokens.recorder.expired),
            HealthToken(audience: "skype", present: st.tokens.skype.present, expired: st.tokens.skype.expired),
            HealthToken(audience: "refresh", present: st.tokens.refresh_present, expired: false),
        ]
    }

    /// Verdict: upstream probe rule (all ok → ok, none → broken, else
    /// degraded), capped at degraded when any token slot is missing or
    /// expired. Pure, tested.
    public static func verdict(tokens: [HealthToken], probes: [HealthProbe]) -> HealthOverall {
        let okCount = probes.filter(\.ok).count
        let probeVerdict: HealthOverall =
            okCount == probes.count ? .ok : okCount == 0 ? .broken : .degraded
        guard probeVerdict != .broken else { return .broken }
        let tokensBad = tokens.contains { !$0.present || $0.expired }
        return (probeVerdict == .degraded || tokensBad) ? .degraded : .ok
    }

    /// Run the full check: offline slots first, then the three timed
    /// live probes. Probe failures land in the report (never thrown);
    /// only the status read can fail the run. Every fetch races the
    /// timeout clock, so a wedged core fails loudly instead of
    /// sticking the badge on "Checking…" (om-settings-org).
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let statusFn = statusFetcher
        let meFn = meFetcher
        let teamsFn = teamsFetcher
        let chatsFn = chatsFetcher
        let st: StatusResponse
        do {
            st = try await Self.race(timeoutSeconds, statusFn)
        } catch {
            self.error = Self.message(for: error)
            return
        }
        let tokens = Self.tokenSlots(st)
        var probes: [HealthProbe] = []
        var account: String?
        // Probe 1: Graph /me (whoami exercises the Graph token).
        do {
            let t0 = Date()
            do {
                let me = try await Self.race(timeoutSeconds, meFn)
                account = me.mail
                probes.append(HealthProbe(
                    name: "graph_me", ok: true,
                    detail: "mail=\(me.mail ?? "(none)")",
                    durationMs: Self.ms(since: t0)))
            } catch {
                probes.append(HealthProbe(
                    name: "graph_me", ok: false,
                    detail: Self.message(for: error).prefix(200).description,
                    durationMs: Self.ms(since: t0)))
            }
        }
        // Probe 2: Graph /me/joinedTeams.
        do {
            let t0 = Date()
            do {
                let teams = try await Self.race(timeoutSeconds, teamsFn)
                probes.append(HealthProbe(
                    name: "graph_joined_teams", ok: true,
                    detail: "count=\(teams.teams.count)",
                    durationMs: Self.ms(since: t0)))
            } catch {
                probes.append(HealthProbe(
                    name: "graph_joined_teams", ok: false,
                    detail: Self.message(for: error).prefix(200).description,
                    durationMs: Self.ms(since: t0)))
            }
        }
        // Probe 3: chat list (exercises the Skype token path).
        do {
            let t0 = Date()
            do {
                let chats = try await Self.race(timeoutSeconds, { try chatsFn(1) })
                probes.append(HealthProbe(
                    name: "chatsvc_list", ok: true,
                    detail: "chats=\(chats.chats.count)",
                    durationMs: Self.ms(since: t0)))
            } catch {
                probes.append(HealthProbe(
                    name: "chatsvc_list", ok: false,
                    detail: Self.message(for: error).prefix(200).description,
                    durationMs: Self.ms(since: t0)))
            }
        }
        report = HealthReport(
            overall: Self.verdict(tokens: tokens, probes: probes),
            tokens: tokens, probes: probes, accountUPN: account)
        error = nil
    }

    /// Fire-and-forget run (Settings diagnostics, refresh button).
    public func runSoon() {
        Task { await run() }
    }

    /// Adopt a report without core (tests, previews, fixed Settings).
    public func adopt(_ report: HealthReport) {
        self.report = report
        error = nil
    }

    /// Drop everything after sign-out (fail closed).
    public func clear() {
        report = nil
        error = nil
    }

    private static func ms(since t0: Date) -> Int {
        Int(Date().timeIntervalSince(t0) * 1000)
    }

    /// Unwrap core envelope failures (same rule as AuthViewModel).
    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        if case HealthTimeout.timeout(let s) = error {
            return "Health check timed out after \(Int(s))s — the core call never returned."
        }
        return String(describing: error)
    }

    /// Run a blocking fetch off-main, racing the timeout clock. The
    /// winner resumes the continuation; the loser is abandoned (a
    /// wedged FFI call keeps its thread until it returns, but the
    /// run no longer waits on it — a task group cannot do this, it
    /// always waits for every child).
    private static func race<T: Sendable>(
        _ seconds: Double, _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let once = RaceOnce()
            Task.detached {
                let result = Result { try work() }
                if once.claim() {
                    switch result {
                    case let .success(value): cont.resume(returning: value)
                    case let .failure(error): cont.resume(throwing: error)
                    }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    cont.resume(throwing: HealthTimeout.timeout(seconds))
                }
            }
        }
    }

    /// Canned report for previews and fixed views. Never core.
    public static var demo: HealthReport {
        HealthReport(
            overall: .degraded,
            tokens: [
                HealthToken(audience: "aad", present: true, expired: false),
                HealthToken(audience: "graph", present: true, expired: false),
                HealthToken(audience: "ic3", present: true, expired: true),
                HealthToken(audience: "recorder", present: false, expired: false),
                HealthToken(audience: "skype", present: true, expired: false),
                HealthToken(audience: "refresh", present: true, expired: false),
            ],
            probes: [
                HealthProbe(name: "graph_me", ok: true, detail: "mail=demo@example.com", durationMs: 120),
                HealthProbe(name: "graph_joined_teams", ok: true, detail: "count=2", durationMs: 210),
                HealthProbe(name: "chatsvc_list", ok: false, detail: "demo offline", durationMs: 0),
            ],
            accountUPN: "demo@example.com")
    }
}

/// Timeout marker for a wedged core fetch (see `HealthStore`).
public enum HealthTimeout: Error, Sendable {
    case timeout(Double)
}

/// Exactly-once claim for the timeout race (first finisher resumes
/// the continuation; the loser drops its result).
private final class RaceOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

