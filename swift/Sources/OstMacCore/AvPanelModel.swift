// AvPanelModel.swift — P4 split: verbatim move from AvPanelView.swift.
import Combine
import CoreGraphics
import Foundation

@MainActor
public final class AvPanelModel: ObservableObject {
    // Devices (real names; picks persisted).
    @Published public var micDevices: [String] = []
    @Published public var speakerDevices: [String] = []
    @Published public var devicesLoaded = false
    /// Non-nil when the last scan timed out or failed (shown in the
    /// pickers' empty state with a Rescan button; nil on success).
    @Published public var devicesError: String?
    /// Scan budget in seconds (N=10: Rust-side lock budgets alone can
    /// burn 46s worst-case, so the UI must give up first). Injectable
    /// for tests; the wedged FFI thread keeps burning in the
    /// background, but the UI never spins past this.
    public var scanTimeout: TimeInterval = 10
    /// Device enumeration entry point (default: cpal via FFI).
    /// Injected by tests (`--av-scan-stuck` forces a hang for shots).
    public var deviceRunner: () throws -> AudioDevices = {
        try RustCore.audioDevices()
    }
    /// Monotonic scan id: late completions from a superseded scan drop.
    private var scanGeneration = 0
    @Published public var micDevice: String? {
        didSet { UserDefaults.standard.set(micDevice, forKey: Self.micKey) }
    }
    @Published public var speakerDevice: String? {
        didSet { UserDefaults.standard.set(speakerDevice, forKey: Self.speakerKey) }
    }
    public static let micKey = "om.av.micDevice"
    public nonisolated static let speakerKey = "om.av.speakerDevice"

    // Test state.
    @Published public var micPhase = TestPhase.idle
    @Published public var micResult = "Not tested"
    @Published public var speakerPhase = TestPhase.idle
    @Published public var speakerResult = "Not tested"

    // Live level (0..1). levelLive=false = no input right now.
    @Published public var level = 0.0
    @Published public var levelLive = false

    // Mic TCC denial: the panel shows the fix-it hint until granted.
    @Published public var micDenied = false
    /// --av-mic-denied shot hook: seed + hold the denial state.
    private let denyPreview: Bool
    /// unknown_device follow-up: which pick the rescan must heal.
    private enum HealKind { case mic, speaker }
    private var pendingHeal: HealKind?

    // Diagnostics (collapsed by default; raw core output lives here).
    @Published public var diagExpanded = false
    @Published public var caps = "—"
    @Published public var probe = "—"
    @Published public var check = "idle"
    @Published public var dry = "idle"
    @Published public var decode = "idle"
    @Published public var remoteImage: CGImage?
    @Published public var decodedImage: CGImage?
    @Published public var loop = "idle"

    private var levelTimer: Timer?
    private var levelSampling = false

    public init() {
        micDevice = UserDefaults.standard.string(forKey: Self.micKey)
        speakerDevice = UserDefaults.standard.string(forKey: Self.speakerKey)
        denyPreview = CommandLine.arguments.contains("--av-mic-denied")
        if denyPreview {
            micDenied = true
            micPhase = .failed
            micResult = AvSummary.micDenied
        }
        // --av-scan-stuck shot hook: force a wedged scan so the timeout
        // UI (error + Rescan) is demonstrable without bad hardware.
        if CommandLine.arguments.contains("--av-scan-stuck") {
            deviceRunner = {
                Thread.sleep(forTimeInterval: 120)
                throw CoreCallError.failed("scan_stuck: forced hang")
            }
        }
        // --av-scan-fake shot hook: canned devices so the resolved-picker
        // state is demonstrable on machines whose HAL wedges the real scan.
        if CommandLine.arguments.contains("--av-scan-fake") {
            deviceRunner = {
                AudioDevices(
                    ok: true, inputs: ["MacBook Pro Microphone"],
                    outputs: ["MacBook Pro Speakers"],
                    default_input: "MacBook Pro Microphone",
                    default_output: "MacBook Pro Speakers")
            }
        }
    }

    /// Off-main runner: `work` runs detached, `apply` publishes on-main.
    private func run<T: Sendable>(
        _ apply: @escaping @MainActor (Result<T, Error>) -> Void,
        work: @escaping @Sendable () throws -> T
    ) {
        Task.blocking(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try work()) } catch { result = .failure(error) }
            await MainActor.run {
                apply(result)
            }
        }
    }

    // MARK: Devices

    public func refreshDevices() {
        scanGeneration += 1
        let generation = scanGeneration
        let runner = deviceRunner
        let budget = scanTimeout
        run({ [weak self] (r: Result<AudioDevices, Error>) in
            guard let self, generation == self.scanGeneration else { return }
            switch r {
            case let .success(d):
                self.micDevices = d.inputs
                self.speakerDevices = d.outputs
                // Adopt the system default only when the user never picked.
                if self.micDevice == nil { self.micDevice = d.default_input }
                if self.speakerDevice == nil { self.speakerDevice = d.default_output }
                self.devicesError = nil
                self.drainHeal(devices: d)
            case let .failure(e):
                self.micDevices = []
                self.speakerDevices = []
                self.devicesError = AvSummary.friendlyError(e)
                self.drainHeal(devices: nil)
            }
            self.devicesLoaded = true
            // Chained after enumeration so CoreAudio setup never contends
            // with the device scan (concurrent probes wedge some drivers).
            self.refreshProbe()
            self.startLevelPolling()
        }, work: { try runner() })
        // Timeout: a wedged HAL/driver can hold the cpal call forever,
        // so the UI gives up at N seconds and shows the error state.
        // A late success still lands (same generation clears the error).
        Task.blocking(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            await MainActor.run { [weak self] in
                self?.scanTimedOut(generation: generation)
            }
        }
    }

    /// Timeout arm for `refreshDevices`: only the current generation
    /// flips, and only while still scanning.
    private func scanTimedOut(generation: Int) {
        guard generation == scanGeneration, !devicesLoaded else { return }
        micDevices = []
        speakerDevices = []
        devicesError = AvSummary.scanTimedOut
        devicesLoaded = true
        refreshProbe()
        startLevelPolling()
    }

    /// unknown_device follow-up: the rescan just landed — heal a true
    /// unplug to the system default, keep the pick on a wedge/empty list.
    private func drainHeal(devices d: AudioDevices?) {
        guard let kind = pendingHeal else { return }
        pendingHeal = nil
        switch kind {
        case .mic:
            micPhase = .failed
            switch AvHeal.action(pick: micDevice, devices: d?.inputs ?? []) {
            case .valid:
                micResult = AvSummary.deviceBack
            case .wedge:
                micResult = AvSummary.wedgeKept(micDevice)
            case .unplugged:
                micDevice = d?.default_input
                micResult = AvSummary.healedMic(d?.default_input)
            }
        case .speaker:
            speakerPhase = .failed
            switch AvHeal.action(pick: speakerDevice, devices: d?.outputs ?? []) {
            case .valid:
                speakerResult = AvSummary.deviceBack
            case .wedge:
                speakerResult = AvSummary.wedgeKept(speakerDevice)
            case .unplugged:
                speakerDevice = d?.default_output
                speakerResult = AvSummary.healedSpeaker(d?.default_output)
            }
        }
    }

    /// Unplug/replug recovery: stop the meter, rescan, restart it.
    public func rescanDevices() {
        stopLevelPolling()
        devicesLoaded = false
        devicesError = nil
        refreshDevices()
    }

    // MARK: Live level

    public func startLevelPolling() {
        guard levelTimer == nil else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollLevel() }
        }
    }

    public func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func pollLevel() {
        // Meter waits for the device scan, then yields to the mic test
        // (it owns the input stream while recording); resumes after.
        guard devicesLoaded, !levelSampling, micPhase != .running else { return }
        // TCC gate (prompt-free): denial flats the meter + raises the panel
        // hint; not-determined idles — the Test button owns the one prompt.
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
        if !denyPreview { micDenied = false }
        levelSampling = true
        let input = micDevice
        run({ [weak self] (r: Result<MicLevel, Error>) in
            guard let self else { return }
            self.levelSampling = false
            switch r {
            case let .success(v):
                self.levelLive = v.has_input
                self.level = v.has_input ? AvLevel.fraction(db: v.peak_db) : 0
            case .failure:
                self.levelLive = false
                self.level = 0
            }
        }, work: { try RustCore.micLevel(msecs: 150, input: input) })
    }

    // MARK: Tests (routed to the picked devices)

    public func runMicTest() {
        guard micPhase != .running else { return }
        micPhase = .running
        micResult = "Requesting microphone…"
        // The one mic prompt (mirrors startCamera): denial lands in the
        // panel with the Settings hint instead of a core no_input error.
        Task { [self] in
            guard await MicAccess.requestAccess() else {
                micDenied = true
                micPhase = .failed
                micResult = AvSummary.micDenied
                return
            }
            micDenied = false
            micResult = "Recording 3s…"
            let input = micDevice
            let output = speakerDevice
            run({ [weak self] (r: Result<MicTestResult, Error>) in
                guard let self else { return }
                switch r {
                case let .success(v):
                    self.micPhase = .done
                    self.micResult = AvSummary.micTest(v)
                case let .failure(e):
                    if AvSummary.isUnknownDevice(e), self.pendingHeal == nil {
                        self.pendingHeal = .mic
                        self.micResult = "Rescanning devices…"
                        self.rescanDevices()
                    } else {
                        self.micPhase = .failed
                        self.micResult = AvSummary.friendlyError(e)
                    }
                }
            }, work: { try RustCore.micTestOn(seconds: 3, input: input, output: output) })
        }
    }

    public func runTonePlay() {
        guard speakerPhase != .running else { return }
        speakerPhase = .running
        speakerResult = "Playing 1s…"
        let output = speakerDevice
        run({ [weak self] (r: Result<TonePlayResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.speakerPhase = .done
                self.speakerResult = AvSummary.tone(frames: v.frames, msecs: 1000)
            case let .failure(e):
                if AvSummary.isUnknownDevice(e), self.pendingHeal == nil {
                    self.pendingHeal = .speaker
                    self.speakerResult = "Rescanning devices…"
                    self.rescanDevices()
                } else {
                    self.speakerPhase = .failed
                    self.speakerResult = AvSummary.friendlyError(e)
                }
            }
        }, work: { try RustCore.tonePlayOn(msecs: 1000, output: output) })
    }

    // MARK: Diagnostics (unchanged behavior, raw output)

    public func refreshCaps() {
        run({ [weak self] (r: Result<AvInfo, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.caps = "mic=\(v.mic) cam=\(v.camera) disp=\(v.display) pkt=\(v.packetizer)"
            case let .failure(e):
                self.caps = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.avInfo() })
    }

    public func refreshProbe() {
        // The probe opens the input stream (a TCC prompt on fresh
        // machines), so it waits for the Test-owned grant like the meter.
        guard MicAccess.status() == .authorized else {
            probe = AvSummary.probePending
            return
        }
        run({ [weak self] (r: Result<MicProbe, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.probe = "input=\(v.input ? "yes" : "no") output=\(v.output ? "yes" : "no")"
            case let .failure(e):
                self.probe = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.micProbe() })
    }

    public func runToneCheck() {
        run({ [weak self] (r: Result<ToneCheckResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.check = String(
                    format: "echo=%@ delay=%.0fms corr=%.2f",
                    v.detected ? "yes" : "no", v.delay_ms, v.correlation_peak)
            case let .failure(e):
                self.check = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.toneCheck() })
    }

    public func runDryRun() {
        run({ [weak self] (r: Result<DryRunResult, Error>) in
            guard let self else { return }
            switch r {
            case let .success(v):
                self.dry = "a \(v.audio_received)/\(v.audio_sent) echo=\(v.echo_detected ? "yes" : "no")" +
                    " v pkts=\(v.video_packets) nals=\(v.video_nals)"
            case let .failure(e):
                self.dry = "failed: \(e.localizedDescription)"
            }
        }, work: { try RustCore.callDryRun() })
    }

    /// Native round-trip: encode a marker frame, decode it back, show it.
    public func runRoundTrip() {
        decode = "encoding…"
        run({ [weak self] (r: Result<CGImage, Error>) in
            guard let self else { return }
            switch r {
            case let .success(img):
                self.decodedImage = img
                self.decode = "\(img.width)x\(img.height) VT round-trip"
            case let .failure(e):
                self.decode = "failed: \(e.localizedDescription)"
            }
        }, work: {
            let w = 320, h = 240
            var bgra = Data(repeating: 64, count: w * h * 4)
            bgra.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let p = dst.baseAddress!
                for row in 0 ..< h / 2 {
                    for col in 0 ..< w / 2 {
                        let o = (row * w + col) * 4
                        p.storeBytes(of: UInt8(220), toByteOffset: o, as: UInt8.self)
                        p.storeBytes(of: UInt8(220), toByteOffset: o + 1, as: UInt8.self)
                        p.storeBytes(of: UInt8(220), toByteOffset: o + 2, as: UInt8.self)
                    }
                }
            }
            let (sps, pps, slices) = try H264Encode.encode(
                bgra: bgra, width: w, height: h)
            var nals = [sps, pps]
            nals.append(contentsOf: slices)
            return try H264Decode.decode(nals: nals)
        })
    }

    /// Full join check (offline): VT-encode a marker frame, push the NALs,
    /// run the engine packetize/SRTP/depacketize path, decode the AU back.
    public func runLiveLoopback() {
        loop = "encoding…"
        run({ [weak self] (r: Result<CGImage, Error>) in
            guard let self else { return }
            switch r {
            case let .success(img):
                self.remoteImage = img
                self.loop = "\(img.width)x\(img.height) live loopback"
            case let .failure(e):
                self.loop = "failed: \(e.localizedDescription)"
            }
        }, work: {
            let w = 320, h = 240
            var bgra = Data(repeating: 64, count: w * h * 4)
            bgra.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let p = dst.baseAddress!
                for row in 0 ..< h / 2 {
                    for col in 0 ..< w / 2 {
                        let o = (row * w + col) * 4
                        p.storeBytes(of: UInt8(40), toByteOffset: o, as: UInt8.self)
                        p.storeBytes(of: UInt8(120), toByteOffset: o + 1, as: UInt8.self)
                        p.storeBytes(of: UInt8(220), toByteOffset: o + 2, as: UInt8.self)
                    }
                }
            }
            guard let enc = H264StreamEncoder(width: w, height: h, path: "loopback") else {
                throw CoreCallError.failed("no VT encoder")
            }
            let nals = try enc.encode(bgra: bgra)
            _ = try RustCore.videoSendPush(nals: nals)
            let lb = try RustCore.liveLoopback()
            guard lb.aus >= 1 else {
                throw CoreCallError.failed("loopback produced no AU")
            }
            let poll = try RustCore.videoPollIncoming()
            guard let au = poll.au else {
                throw CoreCallError.failed("incoming queue empty")
            }
            guard let img = try H264StreamDecoder(path: "loopback").decode(nals: au.nals) else {
                throw CoreCallError.failed("no slice NALs in AU")
            }
            return img
        })
    }

    /// Round-trip a synthetic I420 frame through the remote slot and show it.
    public func runRemoteLoopback() {
        run({ [weak self] (r: Result<CGImage, Error>) in
            guard let self else { return }
            switch r {
            case let .success(img):
                self.remoteImage = img
                self.decode = "\(img.width)x\(img.height) remote-slot loopback"
            case let .failure(e):
                self.decode = "failed: \(e.localizedDescription)"
            }
        }, work: {
            // 64x64 mid-gray I420 with a bright quadrant marker.
            let w = 64, h = 64
            var y = Data(repeating: 128, count: w * h)
            for row in 0 ..< h / 2 {
                for col in 0 ..< w / 2 { y[row * w + col] = 220 }
            }
            var i420 = y
            i420.append(Data(repeating: 128, count: w * h / 4))
            i420.append(Data(repeating: 128, count: w * h / 4))
            try RustCore.videoPushRemote(i420: i420, width: w, height: h)
            let poll = try RustCore.videoPollRemote()
            guard let f = poll.frame,
                  let img = YUVConvert.cgImage(i420: f.data, width: f.width, height: f.height)
            else {
                throw CoreCallError.failed("remote loopback empty")
            }
            return img
        })
    }
}
