// AvPanelTests.swift — om-av-polish: panel models, summaries, FFI wiring.
// No hardware asserted: device tests use bogus names (deterministic miss)
// or shape checks that hold on headless machines too.
import XCTest

@testable import OstMacCore

/// Thread-safe one-way flag for gating fake runners (they run off-main).
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@MainActor
final class AvPanelTests: XCTestCase {
    // MARK: - Model decode (pure)

    func testAudioDevicesDecode() throws {
        let j = """
        {"ok":true,"inputs":["MacBook Pro Microphone"],"outputs":["MacBook Pro Speakers"],
         "default_input":"MacBook Pro Microphone","default_output":"MacBook Pro Speakers"}
        """
        let v = try JSONDecoder().decode(AudioDevices.self, from: Data(j.utf8))
        XCTAssertTrue(v.ok)
        XCTAssertEqual(v.inputs, ["MacBook Pro Microphone"])
        XCTAssertEqual(v.default_output, "MacBook Pro Speakers")
    }

    func testAudioDevicesDecodeNullDefaults() throws {
        // Headless: empty lists, null defaults.
        let v = try JSONDecoder().decode(
            AudioDevices.self,
            from: Data(#"{"ok":true,"inputs":[],"outputs":[],"default_input":null,"default_output":null}"#.utf8))
        XCTAssertTrue(v.inputs.isEmpty)
        XCTAssertNil(v.default_input)
        XCTAssertNil(v.default_output)
    }

    func testMicLevelDecode() throws {
        let v = try JSONDecoder().decode(
            MicLevel.self, from: Data(#"{"ok":true,"peak_db":-23.5,"has_input":true}"#.utf8))
        XCTAssertTrue(v.has_input)
        XCTAssertEqual(v.peak_db, -23.5)
    }

    // MARK: - Level mapping (pure)

    func testLevelFraction() {
        XCTAssertEqual(AvLevel.fraction(db: -60), 0)
        XCTAssertEqual(AvLevel.fraction(db: -50), 0)
        XCTAssertEqual(AvLevel.fraction(db: -25), 0.5)
        XCTAssertEqual(AvLevel.fraction(db: 0), 1)
        // Clamped both ends.
        XCTAssertEqual(AvLevel.fraction(db: -120), 0)
        XCTAssertEqual(AvLevel.fraction(db: 6), 1)
    }

    // MARK: - Summaries (pure, numbers-first, no key=value)

    func testMicTestSummary() throws {
        let r = try JSONDecoder().decode(
            MicTestResult.self,
            from: Data(#"{"ok":true,"frames":150,"seconds":3.0,"peak_db":-12.4,"played_back":true}"#.utf8))
        XCTAssertEqual(AvSummary.micTest(r), "3.0s · peak -12dB · played back")
    }

    func testMicTestSummaryNoPlayback() throws {
        let r = try JSONDecoder().decode(
            MicTestResult.self,
            from: Data(#"{"ok":true,"frames":150,"seconds":2.9,"peak_db":-60.0,"played_back":false}"#.utf8))
        XCTAssertEqual(AvSummary.micTest(r), "2.9s · peak -60dB · no playback")
    }

    func testToneSummary() {
        XCTAssertEqual(AvSummary.tone(frames: 50, msecs: 1000), "1.0s · 50 frames")
    }

    func testCameraStatsSummary() throws {
        let s = try JSONDecoder().decode(
            CameraStats.self,
            from: Data(#"{"ok":true,"running":true,"width":320,"height":240,"fps_want":15,"frames":240,"dropped":3,"fps_actual":14.5,"last_bytes":115200}"#.utf8))
        XCTAssertEqual(AvSummary.cameraStats(s), "240 frames · 14.5 fps · 3 dropped")
    }

    func testCameraStatusWords() {
        XCTAssertEqual(AvSummary.cameraStatus("idle"), "Off")
        XCTAssertEqual(AvSummary.cameraStatus("stopped"), "Off")
        XCTAssertEqual(AvSummary.cameraStatus("capturing"), "Live")
        XCTAssertEqual(AvSummary.cameraStatus("starting…"), "Starting…")
        XCTAssertEqual(AvSummary.cameraStatus("failed: no device"), "Failed — no device")
        // Unknown shapes pass through.
        XCTAssertEqual(AvSummary.cameraStatus("weird"), "weird")
    }

    func testFriendlyErrors() {
        XCTAssertEqual(
            AvSummary.friendlyError(CoreCallError.failed("no_input: No audio input device found")),
            "Microphone unavailable")
        XCTAssertEqual(
            AvSummary.friendlyError(CoreCallError.failed("no_output: No audio output device found")),
            "Speaker unavailable")
        XCTAssertEqual(
            AvSummary.friendlyError(CoreCallError.failed("unknown_device: Unknown audio input device: X")),
            "Device unplugged — pick another")
        XCTAssertEqual(
            AvSummary.friendlyError(CoreCallError.failed("open_failed: Failed to open audio input device 'X': boom")),
            "Couldn't open device — try again")
        // Unknown codes pass through untouched.
        XCTAssertEqual(
            AvSummary.friendlyError(CoreCallError.failed("boom: details")),
            "boom: details")
    }

    func testPhaseRunning() {
        XCTAssertTrue(TestPhase.running.isRunning)
        XCTAssertFalse(TestPhase.idle.isRunning)
        XCTAssertFalse(TestPhase.done.isRunning)
        XCTAssertFalse(TestPhase.failed.isRunning)
    }

    // MARK: - Mic denial + stale-pick heal (om-avfix, pure)

    func testMicDeniedPointsAtSettings() {
        XCTAssertTrue(AvSummary.micDenied.contains("System Settings"))
        XCTAssertTrue(AvSummary.micDenied.contains("Microphone"))
    }

    func testIsUnknownDevice() {
        XCTAssertTrue(AvSummary.isUnknownDevice(
            CoreCallError.failed("unknown_device: Unknown audio input device: X")))
        XCTAssertFalse(AvSummary.isUnknownDevice(
            CoreCallError.failed("no_input: No audio input device found")))
        XCTAssertFalse(AvSummary.isUnknownDevice(
            CoreCallError.failed("open_failed: Failed to open audio input device 'X': boom")))
        XCTAssertFalse(AvSummary.isUnknownDevice(
            CoreCallError.failed("boom: details")))
        XCTAssertFalse(AvSummary.isUnknownDevice(CoreCallError.badUTF8))
    }

    func testHealAction() {
        // No stale pick (default path) is never healed.
        XCTAssertEqual(AvHeal.action(pick: nil, devices: ["A"]), .valid)
        XCTAssertEqual(AvHeal.action(pick: "", devices: ["A"]), .valid)
        // Pick back in the fresh list: transient error, keep it.
        XCTAssertEqual(AvHeal.action(pick: "A", devices: ["A", "B"]), .valid)
        // Empty fresh list: HAL wedge, keep the pick.
        XCTAssertEqual(AvHeal.action(pick: "A", devices: []), .wedge)
        // Non-empty fresh list without the pick: true unplug, heal.
        XCTAssertEqual(AvHeal.action(pick: "A", devices: ["B"]), .unplugged)
    }

    func testHealMessages() {
        XCTAssertTrue(AvSummary.healedMic("B").contains("B"))
        XCTAssertTrue(AvSummary.healedMic(nil).contains("System Default"))
        XCTAssertTrue(AvSummary.healedSpeaker("S").contains("S"))
        XCTAssertTrue(AvSummary.wedgeKept("A").contains("A"))
        XCTAssertTrue(AvSummary.wedgeKept(nil).contains("selection"))
        XCTAssertFalse(AvSummary.deviceBack.isEmpty)
    }

    func testProbePendingPlaceholder() {
        XCTAssertEqual(AvSummary.probePending, "pending mic access")
    }

    func testMicAccessReadsNeverPrompt() {
        // Status reads are prompt-free on any machine (incl. the sandbox).
        let _ = MicAccess.status()
        let _ = MicAccess.denied
        XCTAssertEqual(
            MicAccess.privacyURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    // MARK: - FFI wiring (staticlib linked into the test bundle)

    func testAudioDevicesShape() throws {
        // Holds headless: shape only, no device asserted.
        let v = try RustCore.audioDevices()
        XCTAssertTrue(v.ok)
        if let d = v.default_input { XCTAssertTrue(v.inputs.contains(d)) }
        if let d = v.default_output { XCTAssertTrue(v.outputs.contains(d)) }
    }

    func testMicLevelBogusDeviceHasNoInput() throws {
        // Deterministic on any machine: a bogus name never matches, never throws.
        let v = try RustCore.micLevel(msecs: 50, input: "ostmac-no-such-device")
        XCTAssertTrue(v.ok)
        XCTAssertFalse(v.has_input)
        XCTAssertEqual(v.peak_db, -60.0)
    }

    func testNamedMicTestBogusDeviceThrows() {
        XCTAssertThrowsError(
            try RustCore.micTestOn(seconds: 1, input: "ostmac-no-such-device", output: nil))
    }

    func testNamedTonePlayBogusDeviceThrows() {
        XCTAssertThrowsError(
            try RustCore.tonePlayOn(msecs: 100, output: "ostmac-no-such-device"))
    }

    func testCameraDeviceListingNeverCrashes() {
        // Listing needs no permission; may be empty in the test sandbox.
        let devices = CameraCapture.videoDevices()
        for d in devices {
            XCTAssertFalse(d.id.isEmpty)
            XCTAssertFalse(d.name.isEmpty)
        }
    }

    // MARK: - Bounded scan (smoke-av F4, injected runner)

    private nonisolated func fakeDevices(inputs: [String] = ["Mic A"], outputs: [String] = ["Spk B"]) throws -> AudioDevices {
        let j = """
        {"ok":true,"inputs":\(jsonStrs(inputs)),"outputs":\(jsonStrs(outputs)),
         "default_input":"\(inputs.first ?? "")","default_output":"\(outputs.first ?? "")"}
        """
        return try JSONDecoder().decode(AudioDevices.self, from: Data(j.utf8))
    }

    private nonisolated func jsonStrs(_ ss: [String]) -> String {
        "[" + ss.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// Poll `devicesLoaded` (the scan completes off-main). Returns loaded.
    private func waitLoaded(_ m: AvPanelModel, timeout: TimeInterval = 5) async -> Bool {
        await TestWait.until(ceiling: max(timeout, TestWait.hangCeiling)) { m.devicesLoaded }
        return m.devicesLoaded
    }

    /// The model adopts persisted picks; isolate tests from real defaults.
    private func withCleanMicDefaults<T>(_ body: () throws -> T) rethrows -> T {
        let d = UserDefaults.standard
        let oldMic = d.string(forKey: AvPanelModel.micKey)
        let oldSpk = d.string(forKey: AvPanelModel.speakerKey)
        d.removeObject(forKey: AvPanelModel.micKey)
        d.removeObject(forKey: AvPanelModel.speakerKey)
        defer {
            if let oldMic { d.set(oldMic, forKey: AvPanelModel.micKey) } else { d.removeObject(forKey: AvPanelModel.micKey) }
            if let oldSpk { d.set(oldSpk, forKey: AvPanelModel.speakerKey) } else { d.removeObject(forKey: AvPanelModel.speakerKey) }
        }
        return try body()
    }

    func testScanTimeoutShowsErrorWithinBudget() async throws {
        // Wedged runner (never returns in-test) -> honest UI at N sec.
        let m = withCleanMicDefaults { AvPanelModel() }
        m.scanTimeout = 0.2
        // Wedge is an explicit gate (closed until the end of the test), not a
        // 30 s sleep raced against a stopwatch.
        let wedge = DispatchSemaphore(value: 0)
        let wedgeReturned = LockedFlag()
        m.deviceRunner = {
            _ = wedge.wait(timeout: .now() + TestWait.hangCeiling)
            wedgeReturned.set()
            throw CoreCallError.failed("scan_stuck: forced hang")
        }
        m.refreshDevices()
        let wedgedLoaded = await waitLoaded(m)
        XCTAssertTrue(wedgedLoaded, "scan must resolve even when the runner wedges")
        XCTAssertFalse(wedgeReturned.value, "UI must give up at N sec, not at the wedge")
        wedge.signal()
        XCTAssertEqual(m.devicesError, AvSummary.scanTimedOut)
        XCTAssertTrue(m.micDevices.isEmpty)
        XCTAssertTrue(m.speakerDevices.isEmpty)
        m.stopLevelPolling()
    }

    func testScanTimeoutMessage() {
        XCTAssertTrue(AvSummary.scanTimedOut.contains("Rescan"))
        XCTAssertTrue(AvSummary.scanTimedOut.contains("timed out"))
    }

    func testLateSuccessClearsTimeoutError() async throws {
        // Timeout fires first, then the slow scan lands and self-heals.
        let m = withCleanMicDefaults { AvPanelModel() }
        m.scanTimeout = 0.2
        // The slow scan is held on a gate so the timeout provably fires first.
        let slow = DispatchSemaphore(value: 0)
        m.deviceRunner = {
            _ = slow.wait(timeout: .now() + TestWait.hangCeiling)
            return try self.fakeDevices()
        }
        m.refreshDevices()
        let lateLoaded = await waitLoaded(m)
        XCTAssertTrue(lateLoaded)
        XCTAssertEqual(m.devicesError, AvSummary.scanTimedOut)
        slow.signal()
        await TestWait.until { m.devicesError == nil }
        XCTAssertNil(m.devicesError, "late success must clear the timeout error")
        XCTAssertEqual(m.micDevices, ["Mic A"])
        XCTAssertEqual(m.speakerDevices, ["Spk B"])
        m.stopLevelPolling()
    }

    func testScanFailureShowsFriendlyError() async throws {
        let m = withCleanMicDefaults { AvPanelModel() }
        m.scanTimeout = 5
        m.deviceRunner = { throw CoreCallError.failed("no_input: No audio input device found") }
        m.refreshDevices()
        let failLoaded = await waitLoaded(m)
        XCTAssertTrue(failLoaded)
        XCTAssertEqual(m.devicesError, "Microphone unavailable")
        XCTAssertTrue(m.micDevices.isEmpty)
        m.stopLevelPolling()
    }

    func testScanSuccessAdoptsDevicesAndClearsError() async throws {
        let m = withCleanMicDefaults { AvPanelModel() }
        m.scanTimeout = 5
        m.deviceRunner = { try self.fakeDevices() }
        m.refreshDevices()
        let okLoaded = await waitLoaded(m)
        XCTAssertTrue(okLoaded)
        XCTAssertNil(m.devicesError)
        XCTAssertEqual(m.micDevices, ["Mic A"])
        XCTAssertEqual(m.speakerDevices, ["Spk B"])
        XCTAssertEqual(m.micDevice, "Mic A")
        XCTAssertEqual(m.speakerDevice, "Spk B")
        m.stopLevelPolling()
    }

    func testStaleScanCompletionDropped() async throws {
        // Slow first scan + fast rescan: the late first result must not clobber.
        let m = withCleanMicDefaults { AvPanelModel() }
        m.scanTimeout = 10
        let staleGate = DispatchSemaphore(value: 0)
        let staleReturned = LockedFlag()
        m.deviceRunner = {
            _ = staleGate.wait(timeout: .now() + TestWait.hangCeiling)
            staleReturned.set()
            return try self.fakeDevices(inputs: ["Old Mic"], outputs: ["Old Spk"])
        }
        m.refreshDevices()
        m.deviceRunner = { try self.fakeDevices(inputs: ["New Mic"], outputs: ["New Spk"]) }
        m.rescanDevices()
        let rescanLoaded = await waitLoaded(m)
        XCTAssertTrue(rescanLoaded)
        XCTAssertEqual(m.micDevices, ["New Mic"])
        staleGate.signal() // now let the stale scan finish
        await TestWait.until { staleReturned.value }
        // Negative window: the stale result must not land. Its main-actor hop
        // has no observable (the generation guard drops it silently).
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(m.micDevices, ["New Mic"], "stale completion must drop")
        XCTAssertEqual(m.speakerDevices, ["New Spk"])
        m.stopLevelPolling()
    }

    func testRescanClearsErrorAndRescans() async throws {
        let m = withCleanMicDefaults { AvPanelModel() }
        m.scanTimeout = 5
        m.deviceRunner = { throw CoreCallError.failed("boom: details") }
        m.refreshDevices()
        let errLoaded = await waitLoaded(m)
        XCTAssertTrue(errLoaded)
        XCTAssertNotNil(m.devicesError)
        m.deviceRunner = { try self.fakeDevices() }
        m.rescanDevices()
        XCTAssertNil(m.devicesError, "rescan clears the error while scanning")
        XCTAssertFalse(m.devicesLoaded)
        let healedLoaded = await waitLoaded(m)
        XCTAssertTrue(healedLoaded)
        XCTAssertNil(m.devicesError)
        XCTAssertEqual(m.micDevices, ["Mic A"])
        m.stopLevelPolling()
    }
}
