// Meet.swift — om-meet-join: lobby state machine, join hints, pre-join
// mic/camera preview model. The lobby machine mirrors Rust
// `ost::api::calendar::{LobbyState, lobby_next}` exactly (same five
// states, same transitions); the pre-join model reuses CameraCapture +
// the mic-level sampler, degrading cleanly with no hardware (flat
// meter, "Camera off" tile, never a hang or a prompt loop).
import AVFoundation
import Combine
import Foundation

// MARK: - Lobby state machine (pure; mirrors Rust lobby_next)

/// Waiting-room states: `idle → joining → lobby → admitted`, with
/// `failed` reachable from `joining`/`lobby`. `admitted` is terminal
/// for the join flow (the call slot owns `connected` onwards).
public enum LobbyState: String, Sendable, Equatable {
    case idle
    case joining
    case lobby
    case admitted
    case failed
}

/// Join-flow events (signaling callbacks in the embedder).
public enum LobbyEvent: Sendable, Equatable {
    /// User pressed Join (or a parsed thread leg started placing).
    case start
    /// Signaling placed the leg; the meeting may still hold us.
    case placed
    /// Server parked us in the waiting room (or the leg is still
    /// placing/ringing past the lobby grace window).
    case lobbySignal
    /// Admitted to the meeting (leg connected).
    case admit
    /// Rejected / declined / leg ended before admission.
    case reject
    /// Back to idle (dismiss, retry, new join string).
    case reset
}

public enum LobbyMachine {
    /// Pure transition: `(state, event) → state`. Mirrors Rust.
    public static func next(_ state: LobbyState, _ event: LobbyEvent) -> LobbyState {
        if event == .reset { return .idle }
        return switch (state, event) {
        case (.idle, .start): .joining
        case (.joining, .placed): .joining
        case (.joining, .lobbySignal): .lobby
        case (.joining, .admit): .admitted
        case (.joining, .reject): .failed
        case (.lobby, .placed): .lobby
        case (.lobby, .admit): .admitted
        case (.lobby, .reject): .failed
        case (.failed, .start): .joining
        default: state // terminal states ignore stale progress
        }
    }

    /// One human line for the lobby banner (nil when no banner).
    public static func banner(for state: LobbyState, detail: String? = nil) -> String? {
        return switch state {
        case .idle, .admitted: nil
        case .joining: "Joining…"
        case .lobby: "In the lobby — waiting for someone to admit you"
        case .failed: detail.map { "Couldn't join: \($0)" } ?? "Couldn't join the meeting"
        }
    }
}

// MARK: - Join hints (pure)

public enum MeetJoin {
    /// User-facing hint for a parsed join target (nil = ready to join).
    /// `unknown` never dials — the button stays disabled.
    public static func hint(for target: JoinTarget?) -> String? {
        guard let target else { return "Paste a Teams meeting link or thread id" }
        return switch target.kind {
        case "thread": nil
        case "meeting-id": "Personal meeting link \u{2014} joined in this app"
        case "url": isMicrosoftLink(target)
            ? "A short Teams link \u{2014} checked in this app, never in a browser"
            : "Opens in your browser \u{2014} not a Teams call link"
        default: "Not a Teams meeting link \u{2014} check the paste"
        }
    }

    /// Join-button label for a parsed target.
    public static func buttonLabel(for target: JoinTarget?) -> String {
        guard let target else { return "Join" }
        return switch target.kind {
        case "thread": "Join"
        case "meeting-id": "Join"
        case "url": isMicrosoftLink(target) ? "Join" : "Open"
        default: "Join"
        }
    }

    /// The target is a link on a Microsoft Teams host (never a browser hand-off).
    static func isMicrosoftLink(_ target: JoinTarget) -> Bool {
        URL(string: target.url).map(MeetLinkResolver.isMicrosoftTeamsURL) ?? false
    }
}

// MARK: - Join by meeting ID + passcode (core-c)

/// Outcome of `RustCore.meetingResolveID` (Graph `onlineMeetings`
/// joinMeetingId lookup).
public enum MeetingIDResolution: Equatable, Sendable {
    /// Resolved to the meeting's join URL (joins in-app via the thread).
    case found(joinURL: String, subject: String?)
    /// Graph has no such meeting for this user (only meetings the user
    /// organizes or is invited to are visible) → web meet link fallback.
    case notFound
    /// Graph disclosed the passcode and the typed one differs.
    case passcodeMismatch

    private struct Wire: Decodable {
        let ok: Bool
        let found: Bool?
        let join_url: String?
        let subject: String?
        let error: String?
    }

    /// Decode core JSON: `{ok,found,join_url,subject}` /
    /// `{ok:true,found:false}` / `{ok:false,error:"passcode"}`. Other
    /// `ok:false` shapes throw `CoreCallError.failed`. Pure.
    public static func parse(_ data: Data) throws -> MeetingIDResolution {
        let w = try JSONDecoder().decode(Wire.self, from: data)
        if !w.ok, w.error == "passcode" { return .passcodeMismatch }
        if !w.ok {
            let err = try? JSONDecoder().decode(CoreError.self, from: data)
            throw CoreCallError.failed(err?.message ?? "meetid")
        }
        if w.found == true, let url = w.join_url, !url.isEmpty {
            return .found(joinURL: url, subject: w.subject)
        }
        return .notFound
    }
}

public extension MeetJoin {
    /// Digits of a typed meeting ID (`"123 456 789 012"`), nil unless
    /// 9–15 ASCII digits (core `normalize_join_meeting_id` bounds).
    static func meetingIDDigits(_ raw: String) -> String? {
        let digits = raw.filter { !$0.isWhitespace }
        guard (9 ... 15).contains(digits.count),
              digits.unicodeScalars.allSatisfy({ ("0" ... "9").contains($0) })
        else { return nil }
        return digits
    }
}

// MARK: - Pre-join mic/camera preview

/// Pre-join device check: mic/camera toggles + live camera preview +
/// mic level meter. Headless-safe: no camera yields the "off" tile, no
/// mic (or TCC denial) flats the meter — nothing hangs, nothing throws
/// out of the sampling loop.
@MainActor
public final class PreJoinModel: ObservableObject {
    /// Mic enabled for the join (off flats the meter, no sampling).
    @Published public var micOn = true
    /// Camera enabled for the join (off stops capture).
    @Published public var cameraOn = true {
        didSet {
            if cameraOn { startCamera() } else { camera.stop() }
        }
    }
    /// Live level (0..1). `levelLive=false` = no input right now.
    @Published public private(set) var level = 0.0
    @Published public private(set) var levelLive = false
    /// Mic TCC denial: the sheet shows the fix-it hint until granted.
    @Published public private(set) var micDenied = false

    public let camera = CameraCapture()

    private var levelTimer: Timer?
    private var levelSampling = false
    private var started = false

    public init() {}

    /// Begin preview + meter (sheet appear). Safe to call twice.
    public func start() {
        guard !started else { return }
        started = true
        if cameraOn { startCamera() }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleOnce() }
        }
        sampleOnce()
    }

    /// End preview + meter (sheet dismiss / join pressed).
    public func stop() {
        started = false
        levelTimer?.invalidate()
        levelTimer = nil
        levelSampling = false
        level = 0
        levelLive = false
        camera.stop()
    }

    private func startCamera() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .denied || status == .restricted { return }
            if status != .authorized {
                guard await CameraCapture.requestAccess() else { return }
            }
            guard self.cameraOn, self.started else { return }
            self.camera.start()
        }
    }

    private func sampleOnce() {
        guard started, !levelSampling else { return }
        guard micOn else {
            levelLive = false
            level = 0
            return
        }
        // Prompt-free TCC gate (AvPanelModel parity): denial flats the
        // meter and raises the hint; never prompts from the loop.
        if MicAccess.denied {
            micDenied = true
            levelLive = false
            level = 0
            return
        }
        guard MicAccess.status() == .authorized else {
            levelLive = false
            level = 0
            return
        }
        micDenied = false
        levelSampling = true
        Task.blocking { [weak self] in
            let result: Result<MicLevel, Error>
            do { result = try .success(RustCore.micLevel(input: nil)) } catch { result = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.levelSampling = false
                guard self.started, self.micOn else { return }
                switch result {
                case let .success(v):
                    self.levelLive = v.has_input
                    self.level = v.has_input ? AvLevel.fraction(db: v.peak_db) : 0
                case .failure:
                    self.levelLive = false
                    self.level = 0
                }
            }
        }
    }
}
