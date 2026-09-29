// CallStore.swift — P4 split: verbatim move from CallView.swift.
// Signaling-only call slot + UX phase machine (see CallCenter.swift).
import Combine
import Foundation

public final class CallStore: ObservableObject {
    @Published public private(set) var call: CallInfo?
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?
    @Published public private(set) var lastAction = ""
    @Published public private(set) var media: LiveMediaStats?
    /// UX phase (CallCenter machine). Reduced from feed events and
    /// slot reconciliation — never set from the view layer directly.
    @Published public private(set) var phase: CallPhase = .idle
    /// Call ids the user dismissed (or the timeout retired). The banner
    /// stays hidden for these while the slot still shows them; the set
    /// resets when a new call id arrives.
    @Published public private(set) var dismissedIDs: Set<String> = []
    // -- in-call controls (om-call-ux; the InCallView window binds these)
    @Published public private(set) var muted = false
    @Published public private(set) var cameraOn = false
    /// Selected speaker route (nil = system default). Persisted under
    /// the A/V panel's key so both surfaces agree.
    @Published public private(set) var speaker: String?
    @Published public private(set) var speakerDevices: [String] = []
    @Published public private(set) var speakersLoaded = false
    @Published public private(set) var controlsError: String?
    /// The incoming call last accepted as a video call (Accept with
    /// Video): the incoming-call host starts a video session for it.
    public private(set) var videoAcceptedCallID: String?
    // -- session counters (Diagnostics only — never in the banner)
    @Published public private(set) var rings = 0
    @Published public private(set) var accepts = 0
    @Published public private(set) var declines = 0
    @Published public private(set) var dismissals = 0
    @Published public private(set) var timeouts = 0
    /// Camera hardware hook, installed by the in-call window (which owns
    /// the AVCapture session). Nil in tests/headless — the toggle still
    /// flips state so it stays exercisable without hardware.
    public var cameraHook: ((Bool) -> Void)?
    /// gap-g3: ring loop, installed by the app (live only). Nil =
    /// silent: headless/tests/demo never make noise.
    public var ringer: (any CallRinging)?
    /// gap-g3: fired once per incoming ring (the app posts the system
    /// banner here). Fires again only for a new call id or a re-ring
    /// after recall — never twice for one ring.
    public var onIncomingRing: ((CallInfo) -> Void)?
    /// gap-g3: fired once when a posted ring ends (answered, declined,
    /// dismissed, timed out — the app withdraws the banner here).
    public var onRingEnded: ((String) -> Void)?
    /// Call id the hooks/ringer currently serve (nil = no live ring).
    private var rungCallID: String?
    private var cancellables = Set<AnyCancellable>()
    private var generation = 0
    private var mediaGeneration = 0
    private var mediaPolling = false
    /// Slot id the local sets below were recorded against. All three
    /// reset when the slot id changes (track(_:)).
    private var trackedID: String?
    /// Terminal call ids cleared via clearEnded (stay idle locally
    /// until a new call id arrives).
    private var retiredIDs: Set<String> = []
    /// Incoming ring ids already counted (rings counts each ring once).
    private var countedRingIDs: Set<String> = []
    private var timeoutTimer: Timer?
    private let demo: Bool
    /// Injected slot read (perf guards count/coalesce; default hits core).
    public var statusFetcher: @Sendable () throws -> CallInfo? = {
        try RustCore.callStatus().call
    }
    /// Injected media read (default hits core).
    public var mediaFetcher: @Sendable () throws -> LiveMediaStats? = {
        try RustCore.callMedia().media
    }
    /// Refresh coalescing: one in-flight re-read; overlapping
    /// ticks/ingests set the queued flag and drain once.
    private var refreshInflight = false
    private var refreshQueued = false
    /// In-Call/A-V window open (set by those views' appear/disappear).
    /// The 1s media loop runs only while a media surface is up (the
    /// banner's stats line or one of these windows) — never headless.
    public var callWindowOpen = false {
        didSet { if oldValue != callWindowOpen { syncMediaPoll() } }
    }

    /// Media loop state (perf guards).
    public var isMediaPolling: Bool { mediaPolling }

    /// Refresh in flight (perf guards: cleared after reconcile lands).
    public var isRefreshInflight: Bool { refreshInflight }

    public init(demo: Bool = false) {
        self.demo = demo
        // Demo never reads the real device route (core-b leak sweep).
        self.speaker = demo ? nil : UserDefaults.standard.string(forKey: AvPanelModel.speakerKey)
        // gap-g3: every phase/call change re-decides the ring (answer,
        // decline, dismiss, timeout, recall, and the feed-beats-read
        // gap where ingest sets inviting before the slot lands — the
        // $call arm catches that one). The delivered pair drives the
        // decision (NEVER a self re-read: @Published emits in willSet,
        // so self.phase/self.call inside a sink still hold the OLD
        // values). syncRing writes no @Published state — no recursion.
        Publishers.CombineLatest($phase, $call)
            .sink { [weak self] phase, call in
                self?.syncRing(phase: phase, call: call)
            }
            .store(in: &cancellables)
    }

    deinit { timeoutTimer?.invalidate() }

    public var isDemo: Bool { demo }

    /// True when the banner should show (live phase, non-dismissed call).
    public var bannerVisible: Bool {
        CallRingPolicy.bannerVisible(
            phase: phase, call: call, dismissedIDs: dismissedIDs)
    }

    /// Feed hook: a call event landed — reduce the machine, then re-read
    /// the slot. The optimistic reduction keeps the banner responsive;
    /// reconciliation with the parked slot is the authority.
    public func ingest(_ event: CallEvent) {
        lastAction = "event:\(event.kind)"
        if let ev = CallPhaseMapper.event(for: event) {
            phase = CallPhaseReducer.next(phase, ev)
        }
        refresh()
    }

    /// Re-read the slot. Single in-flight: overlapping ticks/ingests
    /// collapse — the first runs, the rest set the queued flag, one
    /// drain re-read follows (never N parallel FFIs).
    public func refresh() {
        if demo { return } // demo state is seeded, never re-read
        if refreshInflight {
            refreshQueued = true
            return
        }
        refreshInflight = true
        let fetch = statusFetcher
        Task {
            let fetched: CallInfo?
            do {
                fetched = try await Task.blocking { try fetch() }.value
            } catch {
                fetched = nil
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reconcile(fetched)
                self.refreshInflight = false
                if self.refreshQueued {
                    self.refreshQueued = false
                    self.refresh()
                }
            }
        }
    }

    /// Adopt a freshly read slot: reset per-call sets on id change,
    /// honor dismiss/retire for the current id, else adopt the mapped
    /// phase (counting each incoming ring once, arming the timeout).
    private func reconcile(_ slot: CallInfo?) {
        resetMuteIfCallEnded(previous: call, slot: slot)
        track(slot?.id)
        guard let slot else {
            cancelTimeout()
            if call != nil { call = nil }
            if phase == .ended { phase = .idle }
            // Event-adopted inviting with no slot yet (the feed beat the
            // read): keep the phase; the next refresh adopts the slot.
            syncMediaPoll()
            return
        }
        if retiredIDs.contains(slot.id) {
            // Cleared locally: stay idle until a new call id arrives.
            call = nil
            phase = .idle
            cancelTimeout()
            syncMediaPoll()
            return
        }
        if call != slot { call = slot }
        if dismissedIDs.contains(slot.id) {
            // Hidden by dismiss/timeout: track terminal truth but never
            // re-raise the banner for this id.
            if slot.state == "ended" || slot.state == "failed" {
                phase = .ended
                cancelTimeout()
            }
            syncMediaPoll()
            return
        }
        let mapped = CallPhaseMapper.phase(for: slot)
        if mapped == .inviting, slot.dir == "in", !countedRingIDs.contains(slot.id) {
            countedRingIDs.insert(slot.id)
            rings += 1
        }
        if mapped == .inviting { armTimeout(for: slot.id) } else { cancelTimeout() }
        if phase != mapped { phase = mapped }
        syncMediaPoll()
    }

    /// Mirror of core `reset_call_mute`: an active call that ends/fails
    /// (or vanishes) clears the mic mute, so the next call starts
    /// unmuted. A toggle made between calls (no active call) is kept.
    private func resetMuteIfCallEnded(previous: CallInfo?, slot: CallInfo?) {
        guard muted, let previous, previous.isActive else { return }
        if slot?.id != previous.id || slot?.isActive != true { muted = false }
    }

    /// Duration origin for the live call: core `connected_at` (nil while
    /// placing/ringing or when no call). Count call duration from this,
    /// not from `startedAt` (ring/placement) or a UI-observed connect.
    public var connectedSince: Date? { call?.connectedDate }

    /// Reset per-call local sets when the slot id changes.
    private func track(_ id: String?) {
        if trackedID != id {
            trackedID = id
            dismissedIDs.removeAll()
            retiredIDs.removeAll()
            countedRingIDs.removeAll()
        }
    }

    // MARK: - Never-trap paths (dismiss + ring timeout)

    /// Hide the banner for the current call. The call keeps its server
    /// state (a ring keeps ringing — answer it from Diagnostics); only
    /// the banner goes away. Recall() brings it back.
    public func dismiss() {
        guard let c = call, phase == .inviting || phase == .active else { return }
        dismissedIDs.insert(c.id)
        dismissals += 1
        lastAction = "dismiss"
        phase = CallPhaseReducer.next(phase, .dismissed)
        cancelTimeout()
        syncMediaPoll() // banner surface gone (window may keep the loop)
    }

    /// Re-show a dismissed banner (Diagnostics escape hatch).
    /// Re-adopts the live slot phase (a dismissed ring invites again).
    public func recall() {
        guard let c = call, dismissedIDs.contains(c.id), c.isActive else { return }
        dismissedIDs.remove(c.id)
        lastAction = "recall"
        phase = CallPhaseMapper.phase(for: c)
        if phase == .inviting { armTimeout(for: c.id) }
        syncMediaPoll() // banner surface back (restarts a live loop)
    }

    /// Retire a ringing banner whose time is up (missed call). Called by
    /// the armed timer and directly by tests with a synthetic clock.
    public func checkTimeout(now: TimeInterval) {
        guard phase == .inviting, let c = call, !dismissedIDs.contains(c.id) else { return }
        guard CallRingPolicy.isExpired(startedAt: c.startedAt, now: now) else { return }
        dismissedIDs.insert(c.id)
        phase = CallPhaseReducer.next(phase, .timedOut)
        timeouts += 1
        lastAction = "timeout"
        cancelTimeout()
    }

    /// Clear a terminal call record back to idle (Diagnostics button).
    /// The slot's ended record stays server-side; locally we retire the
    /// id so refresh() stops re-adopting it. Refuses live slots (a
    /// dismissed ring is ended locally but still ringing — end it,
    /// don't clear it).
    public func clearEnded() {
        guard phase == .ended else { return }
        if let c = call, c.isActive { return }
        if let c = call {
            retiredIDs.insert(c.id)
            dismissedIDs.remove(c.id)
        }
        call = nil
        phase = .idle
        lastAction = "clear"
        cancelTimeout()
        syncMediaPoll()
    }

    private func armTimeout(for id: String) {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: CallRingPolicy.timeoutSecs, repeats: false
        ) { [weak self] _ in
            self?.checkTimeout(now: Date().timeIntervalSince1970)
        }
    }

    private func cancelTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    /// gap-g3: ring follows the phase machine — an incoming inviting
    /// phase rings (banner hook + ringer loop), anything else silences.
    /// Outgoing legs never ring locally; a dismissed ring stays silent
    /// until recall re-rings it. Answer and the ring-timeout path both
    /// leave inviting, so both stop the ring by construction.
    private func syncRing(phase: CallPhase, call: CallInfo?) {
        if phase == .inviting, let c = call,
           c.dir == "in", !dismissedIDs.contains(c.id)
        {
            ringer?.start()
            if rungCallID != c.id {
                // A second ring superseding the first ends the old one
                // (its banner withdraws; the loop keeps ringing for B).
                if let old = rungCallID { onRingEnded?(old) }
                rungCallID = c.id
                onIncomingRing?(c)
            }
            return
        }
        ringer?.stop()
        if let rung = rungCallID {
            rungCallID = nil
            onRingEnded?(rung)
        }
    }

    // MARK: - In-call controls

    /// Mute/unmute the live-call mic (stored when idle and applied to the
    /// next call; core clears it when an active call ends — per call).
    public func setMuted(_ on: Bool) {
        if demo {
            muted = on
            lastAction = on ? "demo:mute" : "demo:unmute"
            return
        }
        Task {
            do {
                let r = try await Task.blocking { try RustCore.callMute(muted: on) }.value
                await MainActor.run {
                    self.muted = r.muted
                    self.controlsError = nil
                }
            } catch {
                await MainActor.run {
                    self.controlsError = "Mute failed: \(error)"
                }
            }
        }
    }

    /// Camera on/off. Flips state always; the in-call window's hook
    /// starts/stops capture (nil headless — the toggle still works).
    public func setCameraOn(_ on: Bool) {
        cameraOn = on
        lastAction = on ? "camera-on" : "camera-off"
        cameraHook?(on)
    }

    /// Select the speaker route (nil = system default). Persisted under
    /// the shared A/V key; the core reroutes a live call without
    /// dropping audio on failure.
    public func setSpeaker(_ name: String?) {
        speaker = name
        if demo { return } // never persists the real route
        UserDefaults.standard.set(name, forKey: AvPanelModel.speakerKey)
        Task {
            do {
                _ = try await Task.blocking { try RustCore.callSpeaker(name: name) }.value
                await MainActor.run { self.controlsError = nil }
            } catch {
                await MainActor.run {
                    self.controlsError = "Speaker select failed: \(error)"
                }
            }
        }
    }

    /// Reload output devices (always completes; empty list headless).
    public func refreshSpeakers() {
        if demo {
            speakerDevices = ["Demo Speaker"]
            speakersLoaded = true
            return
        }
        Task {
            do {
                let d = try await Task.blocking { try RustCore.audioDevices() }.value
                await MainActor.run {
                    self.speakerDevices = d.outputs
                    self.speakersLoaded = true
                    if self.speaker == nil { self.speaker = d.default_output }
                    self.controlsError = nil
                }
            } catch {
                await MainActor.run {
                    self.speakerDevices = []
                    self.speakersLoaded = true
                    self.controlsError = "Speaker list unavailable: \(error)"
                }
            }
        }
    }

    public func dismissControlsError() { controlsError = nil }

    /// True while a live call is up AND a media surface reads it (the
    /// banner's stats line or the In-Call/A-V window).
    private var mediaWanted: Bool {
        guard call?.liveMedia == true, call?.isActive == true else { return false }
        return bannerVisible || callWindowOpen
    }

    /// Run the 1s media-stats loop exactly while a live call is up AND
    /// a media surface is visible. Stopping for a lost surface keeps
    /// the last stats (repopulated ≤1s after return); stopping for a
    /// dead call clears them.
    private func syncMediaPoll() {
        if demo { return } // demo never touches core (no stats line)
        let want = mediaWanted
        if want, !mediaPolling {
            mediaPolling = true
            mediaGeneration += 1
            let gen = mediaGeneration
            let fetch = mediaFetcher
            Task.blocking(priority: .utility) { [weak self] in
                while self?.mediaPolling == true, self?.mediaGeneration == gen {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard self?.mediaPolling == true, self?.mediaGeneration == gen else { return }
                    do {
                        let m = try fetch()
                        await MainActor.run { [weak self] in
                            guard let self, self.mediaGeneration == gen else { return }
                            self.media = m
                        }
                    } catch {
                        // Transient; next tick retries.
                    }
                }
            }
        } else if !want, mediaPolling {
            mediaPolling = false
            mediaGeneration += 1 // supersede any parked loop
            if !(call?.liveMedia == true && (call?.isActive ?? false)) {
                media = nil
            }
        }
    }

    /// Seed offline demo state (shot hook: --show-call incoming|active).
    /// `startedAt` dates the seeded ring for timeout shots/tests.
    /// Seeds a fresh world: per-call local sets reset first so shots
    /// and tests are deterministic.
    public func seedDemo(state: String, startedAt: UInt64 = 0) {
        cancelTimeout()
        dismissedIDs.removeAll()
        retiredIDs.removeAll()
        countedRingIDs.removeAll()
        switch state {
        case "incoming":
            call = CallInfo(
                id: "demo-call", dir: "in", peer: "8:orgid:demo",
                peerName: "Doe, Jane", thread: "", state: "ringing",
                startedAt: startedAt,
                detail: "modalities: Audio")
        case "active":
            call = CallInfo(
                id: "demo-call", dir: "out", peer: "8:orgid:demo",
                peerName: "Doe, Jane", thread: "19:demo@thread.v2",
                state: "connected", controller: "https://demo/conv/x",
                startedAt: 1, detail: "outgoing leg · ● Rec injects recorder")
        case "live":
            call = CallInfo(
                id: "demo-call", dir: "out", peer: "8:orgid:demo",
                peerName: "Doe, Jane", thread: "19:demo@thread.v2",
                state: "connected", controller: "https://demo/conv/x",
                startedAt: 1, detail: "echo bot · a/v flowing",
                liveMedia: true)
        case "ended":
            call = CallInfo(
                id: "demo-call", dir: "in", peer: "8:orgid:demo",
                peerName: "Doe, Jane", thread: "", state: "ended",
                startedAt: 1, detail: "Call ended")
        default:
            call = nil
        }
        track(call?.id)
        phase = CallPhaseMapper.phase(for: call)
        if let c = call, phase == .inviting, c.dir == "in",
            !countedRingIDs.contains(c.id)
        {
            countedRingIDs.insert(c.id)
            rings += 1
            armTimeout(for: c.id)
        }
        syncMediaPoll()
    }

    private func run(_ label: String, _ work: @escaping () throws -> CallResult) {
        let wasIncomingRing = call?.dir == "in" && call?.state == "ringing"
        if demo {
            // Offline echo: flip local state so the banner is exercisable.
            lastAction = "demo:\(label)"
            switch label {
            case "accept", "place", "echo", "accept-live", "place-live", "echo-live", "place-video", "accept-video":
                let live = label.hasSuffix("-live") || label.hasSuffix("-video")
                let now = UInt64(Date().timeIntervalSince1970)
                if var c = call { c = CallInfo(id: c.id, dir: c.dir, peer: c.peer, peerName: c.peerName, thread: c.thread, state: "connected", controller: c.controller, startedAt: c.startedAt, detail: c.detail, liveMedia: live ? true : c.liveMedia, connectedAt: c.connectedAt ?? now); call = c }
                else { call = CallInfo(id: "demo-call", dir: "out", peer: "", peerName: "Doe, Jane", state: "connected", liveMedia: live ? true : nil, connectedAt: now) }
                if label.hasPrefix("accept") { accepts += 1 }
            case "end":
                if call?.isActive == true { muted = false } // mute is per call
                call = nil
                if wasIncomingRing { declines += 1 }
            default:
                break
            }
            track(call?.id)
            phase = CallPhaseMapper.phase(for: call)
            if phase == .inviting, let c = call { armTimeout(for: c.id) }
            else { cancelTimeout() }
            syncMediaPoll()
            return
        }
        busy = true
        error = nil
        generation += 1
        let gen = generation
        Task {
            let result: Result<CallResult, Error>
            do {
                result = try .success(await Task.blocking { try work() }.value)
            } catch {
                result = .failure(error)
            }
            guard gen == generation else { return } // superseded
            busy = false
            switch result {
            case let .success(r):
                lastAction = label
                if label.hasPrefix("accept") { accepts += 1 }
                if label == "end", wasIncomingRing { declines += 1 }
                if let c = r.call {
                    reconcile(c)
                } else { refresh() }
                if let rej = r.rejection, r.accepted == false { error = rej }
            case let .failure(e):
                error = String(describing: e)
                refresh()
            }
        }
    }

    /// Place a call with live audio media (as `placeLive`): the core's
    /// signaling-only place connected without audio, so no app path uses it.
    public func place(threadID: String, timeoutSecs: Int32 = 30) {
        placeLive(threadID: threadID, timeoutSecs: timeoutSecs)
    }

    public func placeLive(threadID: String, timeoutSecs: Int32 = 30) {
        run("place-live") { try RustCore.callPlaceLive(threadID: threadID, timeoutSecs: timeoutSecs) }
    }

    /// 1:1 video call with live media (VIDEO1): the invitation carries
    /// Audio + Video; the host pushes camera NALs and decodes remote AUs.
    public func placeLiveVideo(threadID: String, timeoutSecs: Int32 = 30) {
        run("place-video") { try RustCore.callPlaceLiveVideo(threadID: threadID, timeoutSecs: timeoutSecs) }
    }

    public func echo(timeoutSecs: Int32 = 30) {
        run("echo") { try RustCore.callEcho(timeoutSecs: timeoutSecs) }
    }

    public func echoLive(timeoutSecs: Int32 = 30) {
        run("echo-live") { try RustCore.callEchoLive(timeoutSecs: timeoutSecs) }
    }

    /// Accept the ringing call with live audio media (as `acceptLive`):
    /// the banner's plain Accept and every other accept path. The core's
    /// signaling-only accept connected without audio, so no app path uses it.
    public func accept() {
        acceptLive()
    }

    public func acceptLive() {
        run("accept-live") { try RustCore.callAcceptLive() }
    }

    /// Accept the ringing call as a video call with live media (VIDEO1).
    public func acceptLiveVideo() {
        videoAcceptedCallID = call?.id
        run("accept-video") { try RustCore.callAcceptLiveVideo() }
    }

    public func end() {
        run("end") { try RustCore.callEnd() }
    }

    public func injectRecorder() {
        run("record") { try RustCore.callRecordInject() }
    }

    public func dismissError() { error = nil }
}
