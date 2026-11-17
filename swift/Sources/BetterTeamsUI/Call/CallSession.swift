// CallSession.swift — one per call, owned by the account's WindowModel
// (UI-SPEC §8, DL1). The session owns the one `CallStageViewController`
// for the call; the host chosen at start (Settings ▸ Calls ▸ Show calls)
// attaches it: In Main Window = `SectionID.call` in the main window's
// content area (`CallSection` detail pane), In a Separate Window = the
// `CallWindowController`. No mid-call move (DL1).
//
// The session mirrors the core call slot (`CallStore`: phase, mute,
// camera) and the meeting join flow (`MeetingsViewModel.lobby`), owns
// the one 1 s call-duration ticker R7 allows (it feeds the toolbar
// subtitle, the rail call item, the toolbar call item and the Calls
// row), and ends the call when the core reports the other side or the
// server ended it (remote end): same teardown as Leave, without the
// core end call.
import AppKit
import Combine
import Observation
import OstMacCore
import UserNotifications

/// What the call is (drives the stage's title and join step).
public enum CallKind: Equatable, Sendable {
    /// A calendar meeting: pre-join first (Join Now), then the lobby.
    case meeting(id: String, subject: String)
    /// A person (Calls ▸ Call, Call Back): placed at once.
    case person(name: String, thread: String)
    /// The echo test call.
    case test
}

@Observable
@MainActor
public final class CallSession {
    /// Host chosen when the call started (no mid-call move, DL1).
    public let presentation: CallPresentation
    public let kind: CallKind
    @ObservationIgnored public weak var model: WindowModel?
    /// The stage, created once per call and released at call end; both
    /// hosts attach this same controller (§8 shared parts).
    @ObservationIgnored public let stage: CallStageViewController
    /// The separate-window host (nil In Main Window).
    @ObservationIgnored public private(set) var window: CallWindowController?
    /// The core call slot this session follows (nil without an account).
    @ObservationIgnored let store: CallStore?
    /// Local camera for the self view (live only; demo shows a
    /// placeholder feed and never touches hardware or defaults).
    @ObservationIgnored let camera: CameraCapture?
    /// Mic / speaker / camera pickers + level meter (§8 Devices).
    @ObservationIgnored let devices: CallDevices
    /// A video call. 1:1 (VIDEO1): the stage shows the remote video large
    /// with the self view as a picture-in-picture, and the camera starts
    /// on. Group chats and meetings (MEETVIDEO): the tile grid of
    /// `meetingVideo`; a meeting becomes a video call at Join with Video.
    public private(set) var video: Bool
    /// A group chat or meeting call (not 1:1): video uses the tile grid.
    public let group: Bool
    /// Group / meeting video tiles (nil for 1:1 and audio calls). Live
    /// polls the core roster and per-source queues once media flows; demo
    /// shows a fixed roster with synthetic video and never touches the core.
    public private(set) var meetingVideo: MeetingVideoModel? = nil {
        didSet { wireLobbyBanner() }
    }
    /// Remote video decoders keyed by remote participant id (live 1:1
    /// video calls only; demo shows synthetic frames and never touches the
    /// core video queues): one entry, the peer's MRI, created when live
    /// media flows. Group video keeps its decoders in `meetingVideo`.
    public private(set) var remoteVideos: [String: LiveVideoModel] = [:]
    /// Meetings: the person pressed Join Now on the pre-join step.
    public private(set) var joined: Bool
    public private(set) var ended = false
    /// The other side or the server ended the call (core-driven end).
    public private(set) var endedRemotely = false
    /// Mirrors of the core slot and the join flow.
    public private(set) var phase: CallPhase = .idle
    public private(set) var lobby: LobbyState = .idle
    public private(set) var connected = false
    /// Seconds since the call connected (the 1 s ticker).
    public private(set) var elapsed = 0
    public private(set) var muted = false
    public private(set) var cameraOn = false
    public private(set) var sharing = false
    /// Pre-join toggles (§8 pre-join): applied at Join Now.
    public private(set) var preMicOn = true
    public private(set) var preCameraOn = false
    // MARK: C8b push-to-talk (local only; server sync pending)
    // The hand itself lives in main's C2b block above (demo/evidence
    // state + roster display); the Call menu's Raise Hand is its first
    // toggle UI. Live has no signaling endpoint yet, so the menu item
    // validates off outside demo (same posture as the roster display).
    /// Teams ⌥Space (opt-in, Settings ▸ Calls). While held the mic opens;
    /// release restores the mute from before the hold. A menu click (no
    /// key-up follows) talks for at most `pushToTalkCap` seconds.
    public private(set) var pushToTalkHeld = false
    private var pushToTalkWasMuted = false
    private var pushToTalkGen = 0
    static let pushToTalkCap = 5.0
    @ObservationIgnored private var pushToTalkMonitor: Any?

    /// The ⌥Space press (or a menu click): open the mic for the hold.
    public func talkBurst() {
        guard joined, !ended, AppSettings.shared.pushToTalk else { return }
        installPushToTalkMonitor()
        setPushToTalkHeld(true)
        pushToTalkGen += 1
        let gen = pushToTalkGen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushToTalkCap) { [weak self] in
            guard let self, gen == self.pushToTalkGen else { return }
            self.setPushToTalkHeld(false)
        }
    }

    public func setPushToTalkHeld(_ held: Bool) {
        guard joined, !ended, AppSettings.shared.pushToTalk else {
            if pushToTalkHeld { releasePushToTalk() }
            return
        }
        if held {
            guard !pushToTalkHeld else { return }
            installPushToTalkMonitor()
            pushToTalkHeld = true
            pushToTalkWasMuted = muted
            if muted { store?.setMuted(false) }
        } else if pushToTalkHeld {
            releasePushToTalk()
        }
    }

    private func releasePushToTalk() {
        pushToTalkHeld = false
        pushToTalkGen += 1
        if pushToTalkWasMuted { store?.setMuted(true) }
    }

    /// ⌥Space key-up ends the hold (the key-down comes through the menu
    /// key equivalent; repeats extend the cap through `talkBurst`).
    private func installPushToTalkMonitor() {
        guard pushToTalkMonitor == nil else { return }
        pushToTalkMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            guard let self, self.pushToTalkHeld, event.keyCode == 49,
                  event.modifierFlags.contains(.option) else { return event }
            self.setPushToTalkHeld(false)
            return event
        }
    }

    private func removePushToTalkMonitor() {
        if let m = pushToTalkMonitor { NSEvent.removeMonitor(m) }
        pushToTalkMonitor = nil
    }

    // MARK: C2a local-only meeting controls (no signaling, no server writes)
    /// The stage layout choice (meetings; 1:1 ignores it).
    public private(set) var layout: MeetingLayoutMode = .automatic
    /// Own-video background blur (Vision, on-device; demo blurs the
    /// rendered self scene, live needs a frame tap — still unblurred).
    public private(set) var selfBlur = false
    /// Local live captions (on-device Speech in live calls).
    public private(set) var captionsEnabled = false
    public private(set) var captions = LiveCaptionsLog()
    @ObservationIgnored private var captionsEngine: LiveCaptionsEngine?
    // MARK: C2b roster signaling (local state only — no wire yet, see MeetingSignals.swift)
    /// Your raised hand (meetings). Demo/evidence only: live has no
    /// signaling endpoint, so the control stays disabled there.
    public private(set) var handRaised = false
    /// Recent meeting reactions (demo/evidence only in live-unproven state).
    public private(set) var reactions = MeetingReactionLog()
    /// Mute-others / remove / make-presenter (demo applies to the
    /// in-memory roster; live throws liveUnproven and stays disabled).
    public let participantActions: MeetingParticipantActions

    @ObservationIgnored private let live: Bool
    @ObservationIgnored private let evidence: Bool
    @ObservationIgnored private var subs: Set<AnyCancellable> = []
    @ObservationIgnored private var shareSub: AnyCancellable?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var connectedAt: Date?
    /// The core slot reached inviting/active for this call, so a later
    /// ended/idle is this call ending (never a previous call's leftover).
    @ObservationIgnored private var armed = false

    /// Evidence shows a fixed duration (deterministic captures).
    static let evidenceElapsed = 1_127

    public init(kind: CallKind, presentation: CallPresentation, model: WindowModel?, store: CallStore? = nil,
                video: Bool = false, group: Bool = false) {
        self.kind = kind
        self.presentation = presentation
        self.model = model
        self.store = store ?? model?.app?.call
        let live = model?.app != nil && model?.options.demo == false
        self.live = live
        participantActions = live ? .live() : .demo()
        evidence = model?.options.evidence ?? false
        if case .meeting = kind { joined = false } else { joined = true }
        camera = live ? CameraCapture() : nil
        devices = CallDevices(live: live, store: self.store, camera: camera)
        let isVideo: Bool
        if video, case .person = kind { isVideo = true } else { isVideo = false }
        self.video = isVideo
        if case .meeting = kind { self.group = true } else { self.group = group }
        stage = CallStageViewController()
        stage.session = self
        if isVideo, self.group { meetingVideo = MeetingVideoModel(demo: !live) }
        subscribe()
        wireLobbyBanner() // init assignments skip didSet
        // Video calls start with the camera on (camera off later sends no
        // video at all, as Teams does).
        if isVideo, self.store?.cameraOn == false { self.store?.setCameraOn(true) }
        if !live { meetingVideo?.start() } // demo roster up at once
        devices.load()
        if !joined { devices.setLevelWanted(true, by: .preJoin) }
    }

    public var title: String {
        switch kind {
        case .meeting(_, let subject): subject
        case .person(let name, _): name
        case .test: "Test Call"
        }
    }

    /// Evidence captures (deterministic: no animated demo video).
    var isEvidence: Bool { evidence }

    public var isMeeting: Bool {
        if case .meeting = kind { return true }
        return false
    }

    /// The called person (person and test calls).
    var peerName: String? {
        switch kind {
        case .meeting: nil
        case .person(let name, _): name
        case .test: "Echo Test"
        }
    }

    /// Rail and toolbar call item label: the duration once connected.
    public var indicatorText: String { connected ? CallDuration.text(elapsed) : "Call" }

    /// Window subtitle (§8: duration), or the call state in words
    /// before the call connects (§10: never color alone).
    public var statusLine: String {
        if ended { return endedRemotely ? "Call ended" : "" }
        if connected { return CallDuration.text(elapsed) }
        if !joined { return "Ready to join" }
        if isMeeting {
            switch lobby {
            case .lobby: return "Waiting in the lobby"
            case .failed: return "Couldn\u{2019}t join"
            default: return "Joining…"
            }
        }
        if phase == .idle, store?.error != nil { return "Couldn\u{2019}t call" }
        return "Calling…"
    }

    public var controls: CallControlsState {
        CallControlsState(joined: joined, muted: joined ? muted : !preMicOn,
                          cameraOn: joined ? cameraOn : preCameraOn, sharing: sharing)
    }

    // MARK: presentation

    /// Shows the call: the main window's call section, or the call
    /// window (created on first show) when presented separately.
    public func show() {
        guard !ended else { return }
        switch presentation {
        case .mainWindow:
            model?.navigator?.select(section: .call)
        case .separateWindow:
            let w = makeWindowHost()
            if model?.options.evidence == true {
                // Evidence never activates the app or takes key (§11.4).
                w.window?.orderFrontRegardless()
            } else {
                w.showWindow(nil)
                w.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The separate-window host, created once (not ordered front).
    @discardableResult
    func makeWindowHost() -> CallWindowController {
        if let w = window { return w }
        let w = CallWindowController(session: self)
        window = w
        pushControls()
        pushTick()
        return w
    }

    /// The main window's toolbar (status call item, main-window controls).
    private var shellToolbar: NSToolbar? {
        (model?.navigator?.host as? ShellWindowController)?.window?.toolbar
    }

    // MARK: controls

    /// Pre-join ▸ Join Now (meetings): dials through the core join flow
    /// with the pre-join Mic and Camera choices. Camera on = Join with
    /// Video: the live Audio + Video leg and the meeting tile grid. A live
    /// camera-off join still receives everyone's video and screen shares
    /// (CALLFIX): the same tile grid, own tile camera-off.
    func joinNow() {
        guard !joined, !ended else { return }
        joined = true
        devices.setLevelWanted(false, by: .preJoin)
        if preCameraOn {
            video = true
            let mv = MeetingVideoModel(demo: !live)
            meetingVideo = mv
            if !live { mv.start() }
        } else if live, meetingVideo == nil {
            meetingVideo = MeetingVideoModel(demo: false)
        }
        model?.app?.meetings.confirmJoin(micOn: preMicOn, cameraOn: preCameraOn, video: preCameraOn)
        if store?.muted != !preMicOn { store?.setMuted(!preMicOn) }
        if store?.cameraOn != preCameraOn { store?.setCameraOn(preCameraOn) }
        pushControls()
        pushTick()
    }

    /// Demo/evidence only: a meeting already joined and admitted (the
    /// demo core has no join leg); `video`: joined with video (tile grid,
    /// demo roster, camera on).
    func joinForDemo(video withVideo: Bool = false) {
        guard model?.options.demo == true, !joined, !ended else { return }
        joined = true
        lobby = .admitted
        if withVideo, meetingVideo == nil {
            video = true
            let mv = MeetingVideoModel(demo: true)
            meetingVideo = mv
            mv.start()
            if store?.cameraOn == false { store?.setCameraOn(true) }
        }
        devices.setLevelWanted(false, by: .preJoin)
        if phase == .active { noteConnected() }
        pushControls()
        pushTick()
    }

    public func toggleMute() {
        guard !ended else { return }
        if !joined {
            preMicOn.toggle()
            pushControls()
        } else {
            store?.setMuted(!muted)
        }
    }

    public func toggleCamera() {
        guard !ended else { return }
        if !joined {
            preCameraOn.toggle()
            setLocalCamera(preCameraOn)
            pushControls()
        } else {
            store?.setCameraOn(!cameraOn)
        }
    }

    /// C2a: the stage layout (meetings). Pure local choice.
    public func setLayout(_ mode: MeetingLayoutMode) {
        guard !ended, layout != mode else { return }
        layout = mode
    }

    /// C2a: own-video background blur. Live camera frames have no tap
    /// yet, so the toggle shows on the demo self scene only.
    public func setSelfBlur(_ on: Bool) {
        guard !ended, selfBlur != on else { return }
        selfBlur = on
    }

    public func toggleSelfBlur() { setSelfBlur(!selfBlur) }

    /// C2a: local live captions. Live starts the on-device recognizer;
    /// demo and evidence seed lines instead (never the mic).
    public func setCaptions(_ on: Bool) {
        guard !ended, captionsEnabled != on else { return }
        captionsEnabled = on
        if on, live { startCaptionsEngine() } else { stopCaptionsEngine() }
    }

    public func toggleCaptions() { setCaptions(!captionsEnabled) }

    /// C2b: your raised hand (demo/evidence only — live has no
    /// signaling endpoint yet, so live calls never reach this).
    public func setHandRaised(_ up: Bool) {
        guard !live, !ended, handRaised != up else { return }
        handRaised = up
    }

    public func toggleHandRaised() { setHandRaised(!handRaised) }

    /// C2b: send one meeting reaction (demo/evidence only — no wire
    /// yet, so live calls never reach this).
    public func sendMeetingReaction(_ emoji: String, sender: String? = nil) {
        guard !live, !ended else { return }
        let own = sender ?? model?.ownDisplayName ?? "You"
        reactions.append(emoji: emoji, sender: own)
    }

    /// Demo/evidence only: deterministic caption lines (Western names).
    func seedDemoCaptions() {
        guard !live else { return }
        captions = LiveCaptionsLog(lines: [
            LiveCaptionLine(text: "Ava Lindqvist: Let's take the launch date first."),
            LiveCaptionLine(text: "Marco Chen: Thursday works if QA signs off."),
            LiveCaptionLine(text: "Priya Nair: I'll post the checklist after this call."),
        ])
    }

    /// Demo/evidence only: deterministic C2b signals (a raised hand,
    /// a presenter, two reactions). The evidence roster is shared, so
    /// this seeds through the app's meeting store.
    func seedDemoSignals() {
        guard !live else { return }
        setHandRaised(true)
        reactions = MeetingReactionLog(lines: [
            MeetingReaction(emoji: "👍", sender: "Ava Lindqvist"),
            MeetingReaction(emoji: "👏", sender: "Tom Becker"),
        ])
        guard let roster = model?.app?.meeting else { return }
        roster.ingest(MeetingRosterEvent(id: "8:orgid:ava", name: "", handRaised: true))
        roster.ingest(MeetingRosterEvent(id: "8:orgid:tom", name: "", isPresenter: true))
    }

    @MainActor
    private func startCaptionsEngine() {
        guard captionsEngine == nil else { return }
        let engine = LiveCaptionsEngine()
        engine.onLine = { [weak self] text, _ in
            guard let self else { return }
            var log = captions
            log.append(text)
            captions = log
        }
        captionsEngine = engine
        engine.start()
    }

    private func stopCaptionsEngine() {
        captionsEngine?.stop()
        captionsEngine = nil
    }

    /// Share Screen (⇧⌘E): the system `SCContentSharingPicker` through
    /// the core share model; demo flips a local flag (no capture).
    public func toggleShare() {
        guard joined, !ended else { return }
        if live, let app = model?.app {
            if shareSub == nil {
                shareSub = app.screenShare.$session.sink { [weak self] s in self?.mirror(sharing: s.phase.isLive) }
            }
            if sharing { app.screenShare.stop() } else { app.screenShare.start() }
        } else {
            mirror(sharing: !sharing)
        }
    }

    /// Devices popover, anchored to the Devices toolbar button of this
    /// call's host (§8).
    public func showDevices(from anchor: NSView? = nil) {
        guard !ended else { return }
        let toolbar = presentation == .separateWindow ? window?.window?.toolbar : shellToolbar
        let view = anchor ?? CallToolbar.devicesButton(in: toolbar) ?? stage.view
        devices.present(from: view, session: self)
    }

    // MARK: ending

    /// Leave: ends the core call leg, detaches and releases the stage,
    /// closes the call window, and returns the main window to the
    /// previous section when the call was on screen (§8 End).
    public func leave() {
        guard !ended else { return }
        ended = true
        subs.removeAll()
        if let app = model?.app, isMeeting {
            if joined { app.meetings.dismissLobby() } else { app.meetings.cancelPreJoin() }
        }
        if let s = store, s.call?.isActive == true || s.phase == .inviting || s.phase == .active {
            s.end()
        }
        tearDown()
    }

    /// Remote end: the other side or the server ended the call (core
    /// slot `ended`). Same teardown as Leave; no core end call.
    func endRemotely() {
        guard !ended else { return }
        ended = true
        endedRemotely = true
        subs.removeAll()
        if let app = model?.app, isMeeting { app.meetings.dismissLobby() }
        tearDown()
    }

    private func tearDown() {
        ticker?.invalidate()
        ticker = nil
        shareSub = nil
        pushToTalkHeld = false
        pushToTalkGen += 1
        removePushToTalkMonitor()
        if live {
            store?.cameraHook = nil
            if store?.cameraOn == true { store?.setCameraOn(false) }
            if sharing { model?.app?.screenShare.stop() }
        } else if video, store?.cameraOn == true {
            store?.setCameraOn(false) // demo: the next call starts camera-off
        }
        camera?.setLiveSend(false)
        camera?.stop()
        stopCaptionsEngine()
        for v in remoteVideos.values { v.stop() }
        meetingVideo?.stop()
        devices.close()
        stage.detachFromHost()
        let w = window
        window = nil
        w?.closeAfterLeave()
        guard let m = model, m.call === self else { return }
        m.call = nil
        if m.nav.section == .call { m.navigator?.returnToPrevious() }
        m.navigator?.refreshToolbar()
    }

    // MARK: core mirrors

    private func subscribe() {
        guard let store else { return }
        store.$phase.sink { [weak self] p in self?.mirror(phase: p) }.store(in: &subs)
        store.$muted.sink { [weak self] v in self?.mirror(muted: v) }.store(in: &subs)
        store.$cameraOn.sink { [weak self] v in self?.mirror(cameraOn: v) }.store(in: &subs)
        if isMeeting, let meetings = model?.app?.meetings {
            meetings.$lobby.sink { [weak self] l in self?.mirror(lobby: l) }.store(in: &subs)
        }
        if live {
            store.cameraHook = { [weak self] on in self?.setLocalCamera(on) }
        }
        if live {
            // `@Published` emits in willSet: the sink's value is the new
            // slot. Meetings become video calls at Join with Video, so
            // every live session follows the slot (syncVideo checks).
            store.$call.sink { [weak self] c in self?.syncVideo(c) }.store(in: &subs)
        }
    }

    /// Live video calls: once the core reports live media on the active
    /// leg, camera frames go to the core send queue and the remote video
    /// decoder starts (both idempotent). Camera-off meeting joins carry a
    /// tile grid too (they receive video).
    private func syncVideo(_ c: CallInfo?) {
        guard video || meetingVideo != nil, live, !ended, let c, c.isActive, c.liveMedia == true else { return }
        if store?.cameraOn == true, camera?.liveSend == false { camera?.setLiveSend(true) }
        if let mv = meetingVideo {
            mv.start() // roster + per-source decoders (idempotent)
            return
        }
        // 1:1: the core's single incoming queue is the peer's video.
        let peer = c.peer.isEmpty ? "peer" : c.peer
        let decoder = remoteVideos[peer] ?? LiveVideoModel()
        if remoteVideos[peer] == nil { remoteVideos[peer] = decoder }
        decoder.start()
    }

    private func mirror(phase p: CallPhase) {
        guard !ended else { return }
        phase = p
        switch p {
        case .inviting:
            armed = true
        case .active:
            armed = true
            if joined { noteConnected() }
        case .ended, .idle:
            if armed { endRemotely() }
        }
        if !ended { pushTick() }
    }

    private func mirror(lobby l: LobbyState) {
        guard !ended else { return }
        lobby = l
        // Meeting joins dial outside the call slot: re-read it so the live
        // media flag lands (camera send, tile decoders).
        if joined, l == .admitted, video || meetingVideo != nil, live { store?.refresh() }
        if joined, l == .admitted { noteConnected() }
        pushTick()
    }

    private func mirror(muted v: Bool) {
        muted = v
        pushControls()
    }

    private func mirror(cameraOn v: Bool) {
        cameraOn = v
        pushControls()
    }

    private func mirror(sharing v: Bool) {
        guard sharing != v else { return }
        sharing = v
        pushControls()
    }

    /// Duration origin from core (`CallStore.connectedSince`, stamped at
    /// the connected transition) while this call's slot is active; nil
    /// otherwise, so a previous call's stamp never leaks in.
    private var coreConnectedSince: Date? {
        guard store?.call?.isActive == true, let d = store?.connectedSince, d <= Date() else { return nil }
        return d
    }

    /// Starts the one 1 s duration ticker (R7: the only repeating timer
    /// besides the 60 s relative-time ticker). Evidence shows a fixed
    /// duration and runs no timer.
    private func noteConnected() {
        guard !connected else { return }
        connected = true
        if evidence {
            elapsed = Self.evidenceElapsed
        } else {
            let now = Date()
            let origin = coreConnectedSince ?? now
            connectedAt = origin
            elapsed = max(0, Int(now.timeIntervalSince(origin)))
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
        pushTick()
    }

    private func tick() {
        // The core stamp can land after the UI saw the connect; adopt it.
        if let core = coreConnectedSince { connectedAt = core }
        guard !ended, let c = connectedAt else { return }
        let e = max(0, Int(Date().timeIntervalSince(c)))
        guard e != elapsed else { return }
        elapsed = e
        // Demo meeting video: the active speaker moves every few seconds.
        if !live, e % 5 == 0 { meetingVideo?.advanceDemo() }
        pushTick()
    }

    /// Local camera for the self view (pre-join preview and in-call).
    private func setLocalCamera(_ on: Bool) {
        guard let camera else { return }
        guard on else {
            camera.setLiveSend(false)
            camera.stop()
            return
        }
        Task { @MainActor [weak self] in
            guard await CameraCapture.requestAccess(), let self, !self.ended else { return }
            let wantsCamera = self.joined ? self.cameraOn : self.preCameraOn
            guard wantsCamera else { return }
            camera.setLiveSend(self.store?.call?.liveMedia == true)
            camera.start()
        }
    }

    // MARK: pushing to AppKit hosts (same call stack, no observation)

    func pushControls() {
        let c = controls
        CallToolbar.apply(c, to: shellToolbar)
        CallToolbar.apply(c, to: window?.window?.toolbar)
    }

    func pushTick() {
        CallToolbar.applyStatus(indicatorText, accessibility: CallDuration.accessibility(connected ? elapsed : nil),
                                to: shellToolbar)
        window?.setSubtitle(statusLine)
        if presentation == .mainWindow, model?.nav.section == .call { model?.navigator?.refreshTitle() }
    }
}

public extension WindowModel {
    /// Starts a call in the presentation the person chose (Settings ▸
    /// Calls), read now: the choice applies from the next call (DL1).
    /// Refused (nil) while another call is running. `show: false`
    /// creates the session without presenting it (tests); `store`
    /// overrides the account's call slot (tests).
    @discardableResult
    func beginCall(_ kind: CallKind, presentation: CallPresentation? = nil, show: Bool = true,
                   store: CallStore? = nil, video: Bool = false, group: Bool = false) -> CallSession? {
        if let running = call, !running.ended {
            running.show()
            return nil
        }
        let s = CallSession(kind: kind, presentation: presentation ?? .current, model: self, store: store,
                            video: video, group: group)
        call = s
        (provider(.call) as? CallSection)?.title = s.title
        navigator?.refreshToolbar()
        s.pushControls()
        s.pushTick()
        if show { s.show() }
        return s
    }
}

// MARK: - meeting lobby banner

extension CallSession {
    /// A new lobby arrival posts "<name> is waiting in the lobby" with
    /// Admit (live runs only; demo and evidence never post).
    fileprivate func wireLobbyBanner() {
        guard let lobby = meetingVideo?.lobbyQueue else { return }
        let posts = live && model.map { NotificationRouter.postsSystemNotifications($0.options) } ?? false
        lobby.onArrival = posts ? { p in
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: MeetingLobbyInfo.requestID(participantID: p.id),
                content: MeetingLobbyInfo.makeContent(p), trigger: nil))
        } : nil
    }
}
