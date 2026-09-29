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
/// (blocking network) on detached tasks; the join runners default to
/// the live-media core legs (`JoinLeg`: Join Now = live audio, Join with
/// Video = live Audio + Video). Tests inject mock fetchers.
@MainActor
public final class MeetingsViewModel: ObservableObject {
    /// Sync fetch (runs off-main). Throws `CoreCallError` on core failure.
    public typealias MeetingsFetcher = @Sendable () throws -> MeetingsResponse
    public typealias ParseFetcher = @Sendable (String) throws -> JoinParseResponse
    public typealias JoinRunner = @Sendable (String) throws -> CallResult
    public typealias Opener = (URL) -> Void
    /// FIXPACK F12: short-link resolver (start URL -> thread-bearing URL).
    public typealias LinkResolver = @Sendable (URL) async -> String?
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
    /// Join-by-ID failure (bad input, not found, lookup failed, passcode mismatch). Nil when clear.
    @Published public private(set) var meetingIDError: String?
    /// Where the last join-by-ID went: in-app when it resolved; nil when it
    /// didn't (the reason is `meetingIDError`). There is no web route.
    @Published public private(set) var lastMeetingIDRoute: MeetingIDRoute?

    public enum MeetingIDRoute: Equatable, Sendable {
        case inApp
    }

    /// FIXPACK F12: why a pasted Microsoft Teams link could not be joined
    /// (shown instead of the hint; never a browser hand-off). Nil when clear.
    @Published public private(set) var joinLinkError: String?

    /// Hint for the current target (nil = ready). Unknown never dials.
    public var joinHint: String? { joinLinkError ?? MeetJoin.hint(for: target) }

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
    private let videoJoinRunner: JoinRunner
    private let opener: Opener
    private let meetingIDResolver: MeetingIDResolver
    private let linkResolver: LinkResolver
    private var meetingIDGeneration = 0
    private let lobbyGraceSecs: Double
    private var lobbyGeneration = 0

    public init(
        meetingsFetcher: @escaping MeetingsFetcher = { try RustCore.meetings() },
        parseFetcher: @escaping ParseFetcher = { try RustCore.meetingJoinParse(raw: $0) },
        joinRunner: @escaping JoinRunner = { try MeetingsViewModel.runCoreJoin(.liveAudio, threadID: $0) },
        videoJoinRunner: @escaping JoinRunner = { try MeetingsViewModel.runCoreJoin(.liveVideo, threadID: $0) },
        opener: @escaping Opener = { NSWorkspace.shared.open($0) },
        lobbyGraceSecs: Double = 8,
        meetingIDResolver: @escaping MeetingIDResolver = {
            try RustCore.meetingResolveID(meetingID: $0, passcode: $1)
        },
        linkResolver: @escaping LinkResolver = { await MeetLinkResolver.resolve($0, hop: MeetLinkResolver.liveHop) }
    ) {
        self.linkResolver = linkResolver
        self.meetingIDResolver = meetingIDResolver
        self.meetingsFetcher = meetingsFetcher
        self.parseFetcher = parseFetcher
        self.joinRunner = joinRunner
        self.videoJoinRunner = videoJoinRunner
        self.opener = opener
        self.lobbyGraceSecs = lobbyGraceSecs
    }

    /// Fetch upcoming meetings.
    public func load() async {
        state = .loading
        let fetcher = meetingsFetcher
        do {
            let response = try await Task.blocking { try fetcher() }.value
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
    /// `viaMeetingID`: the paste came from join-by-ID, which never hands
    /// off to a browser (a resolved link that is not a thread is an error).
    public func submitJoin(viaMeetingID: Bool = false) {
        joinLinkError = nil
        let text = joinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !parsing else {
            if viaMeetingID {
                lastMeetingIDRoute = nil
                meetingIDError = "Another join is still being checked. Try again in a moment."
                resolvingMeetingID = false
            }
            return
        }
        parsing = true
        let fetcher = parseFetcher
        Task {
            do {
                let response = try await Task.blocking { try fetcher(text) }.value
                self.target = response.target
                self.parsing = false
                self.route(target: response.target, viaMeetingID: viaMeetingID)
            } catch {
                self.parsing = false
                self.target = JoinTarget(kind: "unknown", url: text)
                if viaMeetingID { self.notJoinableByID() }
            }
            // The by-ID lookup stays "busy" until routing is decided, so the
            // sheet never closes before a not-joinable error is set.
            if viaMeetingID { self.resolvingMeetingID = false }
        }
    }

    /// Join by meeting ID + passcode (core-c). Resolves the ID to the
    /// meeting's join URL and joins in-app through the normal paste path
    /// (thread -> pre-join sheet). §GRAPH2: this path never opens a
    /// browser or the Teams web app. The lookup (Graph `onlineMeetings`
    /// joinMeetingId) needs OnlineMeetings.Read, which the Teams sign-in
    /// lacks, and Teams has no other code-to-meeting lookup, so an ID that
    /// can't be resolved is shown as an error (`meetingIDError`: not
    /// found / lookup failed / passcode mismatch) pointing at the invite
    /// link, which does join in-app. Malformed input errors pre-network.
    public func joinByMeetingID(_ meetingID: String, passcode: String) {
        meetingIDError = nil
        lastMeetingIDRoute = nil
        let pass = passcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let digits = MeetJoin.meetingIDDigits(meetingID), !pass.isEmpty else {
            meetingIDError = "Enter a 9–15 digit meeting ID and its passcode."
            return
        }
        meetingIDGeneration += 1
        let gen = meetingIDGeneration
        resolvingMeetingID = true
        let resolver = meetingIDResolver
        Task {
            let outcome = await Task.blocking { Result { try resolver(digits, pass) } }.value
            guard gen == self.meetingIDGeneration else { return } // superseded
            switch outcome {
            case .success(.found(let url, _)):
                self.lastMeetingIDRoute = .inApp
                self.joinText = url // busy until submitJoin has routed it
            case .success(.passcodeMismatch):
                self.resolvingMeetingID = false
                self.meetingIDError = "The passcode doesn't match this meeting ID."
                return
            case .success(.notFound):
                self.resolvingMeetingID = false
                self.meetingIDError = "Teams couldn't find a meeting with that ID. Check the ID and passcode, "
                    + "or use Join with link and paste the invitation."
                return
            case .failure:
                self.resolvingMeetingID = false
                self.meetingIDError = "Couldn't look up that meeting ID with your Teams sign-in. "
                    + "Try again, or use Join with link and paste the invitation."
                return
            }
            self.submitJoin(viaMeetingID: true)
        }
    }

    /// Join one upcoming meeting row (uses its join URL as the paste).
    public func joinMeeting(_ meeting: MeetingItem) {
        guard let url = meeting.joinURL, !url.isEmpty else { return }
        joinText = url
        submitJoin()
    }

    /// Route a parsed target: thread -> pre-join sheet. FIXPACK F12: a
    /// Microsoft Teams link (teams.microsoft.com, teams.live.com,
    /// teams.cloud.microsoft, any subdomain) NEVER opens a browser: a short
    /// `/meet/` link resolves natively to its thread (read-only redirect
    /// follow), anything else is an error that says so. Other https links
    /// (Zoom, Webex, Google Meet) open in the default browser, but not for
    /// a join-by-ID paste (that is an error instead).
    private func route(target: JoinTarget, viaMeetingID: Bool = false) {
        if target.canJoinInApp {
            pendingJoin = target
            showPreJoin = true
        } else if viaMeetingID {
            notJoinableByID()
        } else if target.canOpenExternally, let url = URL(string: target.url) {
            if MeetLinkResolver.isMicrosoftTeamsURL(url) {
                resolveTeamsLink(url)
            } else {
                opener(url)
            }
        }
    }

    /// A Microsoft Teams link that is not itself a thread link.
    private func resolveTeamsLink(_ url: URL) {
        guard MeetLinkResolver.isShortMeetLink(url) else {
            joinLinkError = "That Teams link isn\u{2019}t a meeting this app can join. "
                + "Paste the meeting invitation link, or the meeting ID and passcode."
            return
        }
        parsing = true
        let resolver = linkResolver
        let parser = parseFetcher
        Task {
            let resolved = await resolver(url)
            var joinTarget: JoinTarget?
            if let resolved, let response = try? await Task.blocking(operation: { try parser(resolved) }).value,
               response.target.canJoinInApp {
                joinTarget = response.target
            }
            self.parsing = false
            if let joinTarget {
                self.target = joinTarget
                self.route(target: joinTarget)
            } else {
                self.joinLinkError = "Couldn\u{2019}t find the meeting behind this link without opening Teams in a browser. "
                    + "Paste the full invitation link instead."
            }
        }
    }

    /// A join-by-ID lookup that resolved to something this app can't join.
    private func notJoinableByID() {
        lastMeetingIDRoute = nil
        meetingIDError = "Teams found that meeting but not a way to join it in this app. "
            + "Use Join with link and paste the invitation."
    }

    /// Cancel the pre-join sheet (no dial).
    public func cancelPreJoin() {
        showPreJoin = false
        pendingJoin = nil
    }

    /// The core leg a join dials. Both attach live media: there is no
    /// signaling-only join (it connected without audio).
    public enum JoinLeg: String, Sendable {
        /// Join Now (camera off): live audio, the main video receive only.
        case liveAudio = "place-live"
        /// Join with Video: live audio + video.
        case liveVideo = "place-video"
    }

    /// The leg for a join: `video` = Join with Video.
    public nonisolated static func joinLeg(video: Bool) -> JoinLeg { video ? .liveVideo : .liveAudio }

    /// Dials `leg` on the core (blocking; runs off-main).
    public nonisolated static func runCoreJoin(_ leg: JoinLeg, threadID: String) throws -> CallResult {
        switch leg {
        case .liveAudio: try RustCore.callPlaceLive(threadID: threadID)
        case .liveVideo: try RustCore.callPlaceLiveVideo(threadID: threadID)
        }
    }

    /// Confirm the pre-join sheet: dial the thread leg with live media and
    /// drive the lobby machine. `micOn`/`cameraOn` record the pre-join
    /// toggles (applied by the call slot). `video`: Join with Video
    /// (MEETVIDEO) dials the Audio + Video leg (`joinLeg(video:)`).
    public func confirmJoin(micOn: Bool, cameraOn: Bool, video: Bool = false) {
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
        let runner = Self.joinLeg(video: video) == .liveVideo ? videoJoinRunner : joinRunner
        Task {
            do {
                let result = try await Task.blocking { try runner(threadID) }.value
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
