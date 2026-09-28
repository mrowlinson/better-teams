// MeetingsViewModel.swift — loads upcoming meetings + join-by-link flow.
// Join-by-link: paste a Teams link (or thread id) -> core classifies it ->
// thread legs open the pre-join sheet (mic/camera preview + toggles),
// meeting-id/url links open in the browser, unknown shows a hint and
// never dials. Thread joins run signaling place and drive the lobby
// machine (idle -> joining -> lobby -> admitted|failed); a grace timer
// flips joining -> lobby while the leg is still placing (meeting joins
// park in placing/ringing until the organizer admits).
import AppKit
import Combine
import Foundation

/// Meetings content state (mirrors TeamsState).
public enum MeetingsState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty list in `meetings`.
    case loaded
    /// Fetch succeeded with zero meetings.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Loads upcoming meetings off the main thread and owns the join flow.
// Default fetchers call `RustCore.meetings` / `meetingJoinParse`
/// (blocking network) on detached tasks; the join runner defaults to
/// `RustCore.callPlace` (signaling only). Tests inject mock fetchers.
@MainActor
public final class MeetingsViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias MeetingsFetcher = @Sendable () throws -> MeetingsResponse
    public typealias ParseFetcher = @Sendable (String) throws -> JoinParseResponse
    public typealias JoinRunner = @Sendable (String) throws -> CallResult
    public typealias Opener = (URL) -> Void
    /// Meeting ID + passcode → resolution (core-c; runs off-main).
    public typealias MeetingIDResolver = @Sendable (String, String) throws -> MeetingIDResolution

    /// Latest meetings (only meaningful in `.loaded`; stale otherwise).
    @Published public private(set) var meetings: [MeetingItem] = []
    /// Current content state. Starts `.loading`.
    @Published public private(set) var state: MeetingsState = .loading
    /// Join-box text (paste a link or thread id).
    @Published public var joinText = ""
    /// Last parsed join target (nil until the first parse).
    @Published public private(set) var target: JoinTarget?
    /// Parse in flight.
    @Published public private(set) var parsing = false
    /// Lobby machine state for the active join.
    @Published public private(set) var lobby = LobbyState.idle
    /// Failure detail for the `.failed` banner (nil otherwise).
    @Published public private(set) var lobbyDetail: String?
    /// Pre-join sheet visibility (armed only for thread targets).
    @Published public var showPreJoin = false
    /// The thread target the pre-join sheet is confirming.
    @Published public private(set) var pendingJoin: JoinTarget?
    /// Meetings fetched (Diagnostics window only — never in the sidebar).
    @Published public private(set) var fetchedCount = 0
    /// Joins started (Diagnostics window only).
    @Published public private(set) var joinCount = 0
    /// Join-by-ID lookup in flight (core-c).
    @Published public private(set) var resolvingMeetingID = false
    /// Join-by-ID failure (bad input, passcode mismatch). Nil when clear.
    @Published public private(set) var meetingIDError: String?
    /// Where the last join-by-ID went: in-app (resolved) or web fallback.
    @Published public private(set) var lastMeetingIDRoute: MeetingIDRoute?

    public enum MeetingIDRoute: Equatable, Sendable {
        case inApp
        case web
    }

    /// Hint for the current target (nil = ready). Unknown never dials.
    public var joinHint: String? { MeetJoin.hint(for: target) }

    /// Join-button label for the current target.
    public var joinLabel: String { MeetJoin.buttonLabel(for: target) }

    /// True when the Join button can act (thread dials, link kinds open).
    public var canJoin: Bool {
        guard let t = target else { return false }
        return t.canJoinInApp || t.canOpenExternally
    }

    /// Lobby banner line (nil when no banner).
    public var lobbyBanner: String? { LobbyMachine.banner(for: lobby, detail: lobbyDetail) }

    private let meetingsFetcher: MeetingsFetcher
    private let parseFetcher: ParseFetcher
    private let joinRunner: JoinRunner
    private let opener: Opener
    private let meetingIDResolver: MeetingIDResolver
    private var meetingIDGeneration = 0
    private let lobbyGraceSecs: Double
    private var lobbyGeneration = 0

    public init(
        meetingsFetcher: @escaping MeetingsFetcher = { try RustCore.meetings() },
        parseFetcher: @escaping ParseFetcher = { try RustCore.meetingJoinParse(raw: $0) },
        joinRunner: @escaping JoinRunner = { try RustCore.callPlace(threadID: $0) },
        opener: @escaping Opener = { NSWorkspace.shared.open($0) },
        lobbyGraceSecs: Double = 8,
        meetingIDResolver: @escaping MeetingIDResolver = {
            try RustCore.meetingResolveID(meetingID: $0, passcode: $1)
        }
    ) {
        self.meetingIDResolver = meetingIDResolver
        self.meetingsFetcher = meetingsFetcher
        self.parseFetcher = parseFetcher
        self.joinRunner = joinRunner
        self.opener = opener
        self.lobbyGraceSecs = lobbyGraceSecs
    }

    /// Fetch upcoming meetings.
    public func load() async {
        state = .loading
        let fetcher = meetingsFetcher
        do {
            let response = try await Task.detached { try fetcher() }.value
            meetings = response.meetings
            fetchedCount = response.meetings.count
            state = response.meetings.isEmpty ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry, sign-in).
    public func refresh() {
        Task { await load() }
    }

    /// Parse the join box (Join submit). Thread targets arm the pre-join
    /// sheet; link kinds open externally; unknown shows a hint.
    public func submitJoin() {
        let text = joinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !parsing else { return }
        parsing = true
        let fetcher = parseFetcher
        Task {
            do {
                let response = try await Task.detached { try fetcher(text) }.value
                self.target = response.target
                self.parsing = false
                self.route(target: response.target)
            } catch {
                self.parsing = false
                self.target = JoinTarget(kind: "unknown", url: text)
            }
        }
    }

    /// Join by meeting ID + passcode (core-c). Resolves the ID via Graph
    /// (`onlineMeetings` joinMeetingId) to the meeting's join URL and joins
    /// in-app through the normal paste path (thread → pre-join sheet).
    /// Not found (outside meeting, not signed in, missing scope, network
    /// error) falls back to the web meet link in the browser, as before.
    /// A passcode that Graph shows to differ sets `meetingIDError` and
    /// does not join. Malformed input sets `meetingIDError` pre-network.
    public func joinByMeetingID(_ meetingID: String, passcode: String) {
        meetingIDError = nil
        guard let digits = MeetJoin.meetingIDDigits(meetingID),
              let web = MeetJoin.webMeetURL(meetingID: digits, passcode: passcode)
        else {
            meetingIDError = "Enter a 9–15 digit meeting ID and its passcode."
            return
        }
        let pass = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        meetingIDGeneration += 1
        let gen = meetingIDGeneration
        resolvingMeetingID = true
        let resolver = meetingIDResolver
        Task {
            let resolution = try? await Task.detached { try resolver(digits, pass) }.value
            guard gen == self.meetingIDGeneration else { return } // superseded
            self.resolvingMeetingID = false
            switch resolution {
            case .found(let url, _):
                self.lastMeetingIDRoute = .inApp
                self.joinText = url
            case .passcodeMismatch:
                self.meetingIDError = "The passcode doesn't match this meeting ID."
                return
            case .notFound, nil:
                self.lastMeetingIDRoute = .web
                self.joinText = web
            }
            self.submitJoin()
        }
    }

    /// Join one upcoming meeting row (uses its join URL as the paste).
    public func joinMeeting(_ meeting: MeetingItem) {
        guard let url = meeting.joinURL, !url.isEmpty else { return }
        joinText = url
        submitJoin()
    }

    /// Route a parsed target: thread -> pre-join sheet, links -> browser.
    private func route(target: JoinTarget) {
        if target.canJoinInApp {
            pendingJoin = target
            showPreJoin = true
        } else if target.canOpenExternally, let url = URL(string: target.url) {
            opener(url)
        }
    }

    /// Cancel the pre-join sheet (no dial).
    public func cancelPreJoin() {
        showPreJoin = false
        pendingJoin = nil
    }

    /// Confirm the pre-join sheet: dial the thread leg (signaling) and
    /// drive the lobby machine. `micOn`/`cameraOn` record the pre-join
    /// toggles (signaling legs carry no media; the toggles apply when
    /// live media attaches).
    public func confirmJoin(micOn: Bool, cameraOn: Bool) {
        guard let threadID = pendingJoin?.threadID else { return }
        showPreJoin = false
        pendingJoin = nil
        _ = (micOn, cameraOn)
        joinCount += 1
        lobby = LobbyMachine.next(.idle, .start)
        lobbyDetail = nil
        lobbyGeneration += 1
        let gen = lobbyGeneration
        // Grace timer: still joining after N seconds -> waiting room.
        let grace = lobbyGraceSecs
        Task { @MainActor [weak self] in
            guard grace >= 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, self.lobbyGeneration == gen, self.lobby == .joining else { return }
            self.lobby = LobbyMachine.next(self.lobby, .lobbySignal)
        }
        let runner = joinRunner
        Task {
            do {
                let result = try await Task.detached { try runner(threadID) }.value
                guard gen == self.lobbyGeneration else { return } // superseded
                if result.accepted == true || result.call?.state == "connected" {
                    self.lobby = LobbyMachine.next(self.lobby, .placed)
                    self.lobby = LobbyMachine.next(self.lobby, .admit)
                } else {
                    self.lobbyDetail = result.rejection ?? Self.callDetail(result.call)
                    self.lobby = LobbyMachine.next(self.lobby, .reject)
                }
            } catch {
                guard gen == self.lobbyGeneration else { return }
                self.lobbyDetail = Self.message(for: error)
                self.lobby = LobbyMachine.next(self.lobby, .reject)
            }
        }
    }

    /// Dismiss the lobby banner (failed/admitted) back to idle.
    public func dismissLobby() {
        lobbyGeneration += 1 // supersede any parked grace timer
        lobby = .idle
        lobbyDetail = nil
    }

    private nonisolated static func callDetail(_ call: CallInfo?) -> String? {
        guard let call else { return nil }
        if let d = call.detail, !d.isEmpty { return d }
        return call.state == "connected" ? nil : "call \(call.state)"
    }

    nonisolated static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
