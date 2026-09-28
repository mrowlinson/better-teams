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
    static let evidenceElapsed = 754

    public init(kind: CallKind, presentation: CallPresentation, model: WindowModel?, store: CallStore? = nil) {
        self.kind = kind
        self.presentation = presentation
        self.model = model
        self.store = store ?? model?.app?.call
        let live = model?.app != nil && model?.options.demo == false
        self.live = live
        evidence = model?.options.evidence ?? false
        if case .meeting = kind { joined = false } else { joined = true }
        camera = live ? CameraCapture() : nil
        devices = CallDevices(live: live, store: self.store, camera: camera)
        stage = CallStageViewController()
        stage.session = self
        subscribe()
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
    /// with the pre-join Mic and Camera choices.
    func joinNow() {
        guard !joined, !ended else { return }
        joined = true
        devices.setLevelWanted(false, by: .preJoin)
        model?.app?.meetings.confirmJoin(micOn: preMicOn, cameraOn: preCameraOn)
        if store?.muted != !preMicOn { store?.setMuted(!preMicOn) }
        if store?.cameraOn != preCameraOn { store?.setCameraOn(preCameraOn) }
        pushControls()
        pushTick()
    }

    /// Demo/evidence only: a meeting already joined and admitted (the
    /// demo core has no join leg).
    func joinForDemo() {
        guard model?.options.demo == true, !joined, !ended else { return }
        joined = true
        lobby = .admitted
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
        if live {
            store?.cameraHook = nil
            if store?.cameraOn == true { store?.setCameraOn(false) }
            if sharing { model?.app?.screenShare.stop() }
        }
        camera?.setLiveSend(false)
        camera?.stop()
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
                   store: CallStore? = nil) -> CallSession? {
        if let running = call, !running.ended {
            running.show()
            return nil
        }
        let s = CallSession(kind: kind, presentation: presentation ?? .current, model: self, store: store)
        call = s
        (provider(.call) as? CallSection)?.title = s.title
        navigator?.refreshToolbar()
        s.pushControls()
        s.pushTick()
        if show { s.show() }
        return s
    }
}
