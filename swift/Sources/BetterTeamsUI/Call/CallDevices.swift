// CallDevices.swift — the Devices popover (UI-SPEC §8): microphone,
// speaker and camera pickers + input level meter, shared by the
// pre-join step and the in-call Devices toolbar item.
//
// Live: the core A/V model (`AvPanelModel`: device scan, persisted mic
// and speaker choice, level polling), the call slot's speaker reroute
// (`CallStore.setSpeaker`), and `CameraCapture` (camera list + choice).
// Demo: fixed device lists and a fixed level; nothing reads or writes
// the person's device preferences.
import AppKit
import Combine
import Observation
import OstMacCore
import SwiftUI

@Observable
@MainActor
final class CallDevices: NSObject, NSPopoverDelegate {
    enum LevelClient: Hashable { case preJoin, popover, settings }

    private(set) var mics: [String] = []
    private(set) var speakers: [String] = []
    private(set) var cameras: [CameraDevice] = []
    private(set) var mic: String?
    private(set) var speaker: String?
    private(set) var camera: String?
    private(set) var loaded = false
    private(set) var error: String?
    /// Input level 0…1; `levelLive == false` = no input right now.
    private(set) var level = 0.0
    private(set) var levelLive = false
    /// REGFIX-C R3 device tests: a 1 s tone out of the speaker, a 3 s
    /// microphone recording played back. Core runs them live; demo shows
    /// fixed outcomes (no hardware).
    private(set) var speakerPhase = TestPhase.idle
    private(set) var speakerResult = "Not tested"
    private(set) var micPhase = TestPhase.idle
    private(set) var micResult = "Not tested"
    private(set) var micDenied = false

    @ObservationIgnored private let live: Bool
    @ObservationIgnored private let store: CallStore?
    /// The local camera the pickers select (Settings ▸ Calls previews it).
    @ObservationIgnored let capture: CameraCapture?
    @ObservationIgnored private var previewWanted = false
    @ObservationIgnored private var av: AvPanelModel?
    @ObservationIgnored private var subs: Set<AnyCancellable> = []
    @ObservationIgnored private var levelClients: Set<LevelClient> = []
    @ObservationIgnored private var popover: NSPopover?

    /// Demo fixtures (deterministic evidence).
    static let demoMics = ["MacBook Pro Microphone", "Studio Display Microphone"]
    static let demoSpeakers = ["MacBook Pro Speakers", "Studio Display Speakers"]
    static let demoCameras = [CameraDevice(id: "demo-cam-1", name: "FaceTime HD Camera"),
                              CameraDevice(id: "demo-cam-2", name: "Studio Display Camera")]
    static let demoLevel = 0.42

    init(live: Bool, store: CallStore?, camera: CameraCapture?) {
        self.live = live
        self.store = store
        capture = camera
        super.init()
    }

    /// Scans devices once per call (the session calls this at start).
    func load() {
        guard !loaded, av == nil else { return }
        guard live else {
            mics = Self.demoMics
            speakers = Self.demoSpeakers
            cameras = Self.demoCameras
            mic = mics.first
            speaker = speakers.first
            camera = cameras.first?.id
            level = Self.demoLevel
            levelLive = true
            loaded = true
            return
        }
        let a = AvPanelModel()
        av = a
        a.$micDevices.sink { [weak self] v in self?.mics = v }.store(in: &subs)
        a.$speakerDevices.sink { [weak self] v in self?.speakers = v }.store(in: &subs)
        a.$micDevice.sink { [weak self] v in self?.mic = v }.store(in: &subs)
        a.$devicesLoaded.sink { [weak self] v in self?.loaded = v }.store(in: &subs)
        a.$devicesError.sink { [weak self] v in self?.error = v }.store(in: &subs)
        a.$level.sink { [weak self] v in self?.level = v }.store(in: &subs)
        a.$levelLive.sink { [weak self] v in self?.levelLive = v }.store(in: &subs)
        a.$speakerPhase.sink { [weak self] v in self?.speakerPhase = v }.store(in: &subs)
        a.$speakerResult.sink { [weak self] v in self?.speakerResult = v }.store(in: &subs)
        a.$micPhase.sink { [weak self] v in self?.micPhase = v }.store(in: &subs)
        a.$micResult.sink { [weak self] v in self?.micResult = v }.store(in: &subs)
        a.$micDenied.sink { [weak self] v in self?.micDenied = v }.store(in: &subs)
        speaker = store?.speaker ?? a.speakerDevice
        cameras = CameraCapture.videoDevices()
        camera = capture?.selectedDeviceID ?? cameras.first?.id
        a.refreshDevices()
    }

    func selectMic(_ name: String?) {
        mic = name
        av?.micDevice = name
    }

    /// Reroutes a live call without dropping audio on failure (core).
    func selectSpeaker(_ name: String?) {
        speaker = name
        guard live else { return }
        av?.speakerDevice = name
        store?.setSpeaker(name)
    }

    /// Plays the test tone on the picked speaker.
    func testSpeaker() {
        guard live else {
            speakerPhase = .done
            speakerResult = "Played a test tone."
            return
        }
        av?.runTonePlay()
    }

    /// Records 3 s from the picked microphone and plays it back.
    func testMicrophone() {
        guard live else {
            micPhase = .done
            micResult = "Recorded 3 s and played it back."
            return
        }
        av?.runMicTest()
    }

    func selectCamera(_ id: String?) {
        camera = id
        capture?.selectedDeviceID = id
    }

    /// Settings ▸ Calls camera preview: the person turns it on; it stops
    /// when turned off or the pane closes (live only; demo shows the
    /// placeholder feed).
    func setSettingsPreview(_ on: Bool) {
        guard live, let capture else { return }
        previewWanted = on
        guard on else { capture.stop(); return }
        Task { @MainActor [weak self] in
            guard await CameraCapture.requestAccess(), self?.previewWanted == true else { return }
            capture.start()
        }
    }

    /// Level polling runs only while someone shows the meter (pre-join
    /// step, open popover, Settings ▸ Calls).
    func setLevelWanted(_ on: Bool, by client: LevelClient) {
        if on { levelClients.insert(client) } else { levelClients.remove(client) }
        guard let av else { return }
        if levelClients.isEmpty { av.stopLevelPolling() } else { av.startLevelPolling() }
    }

    // MARK: popover

    func present(from view: NSView, session: CallSession) {
        if let p = popover, p.isShown {
            p.performClose(nil)
            return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentViewController = Hosting.controller(CallDevicesForm(devices: self).padding(16).frame(width: 340),
                                                     role: .popover, model: session.model)
        popover = p
        setLevelWanted(true, by: .popover)
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
        levelClients.removeAll()
        av?.stopLevelPolling()
    }

    var isShown: Bool { popover?.isShown == true }

    func popoverDidClose(_ notification: Notification) {
        setLevelWanted(false, by: .popover)
        popover = nil
    }
}

/// Mic / speaker / camera pickers + level meter (pre-join and popover).
struct CallDevicesForm: View {
    let devices: CallDevices

    var body: some View {
        Form {
            Picker("Microphone", selection: Binding(get: { devices.mic ?? "" },
                                                    set: { devices.selectMic($0.isEmpty ? nil : $0) })) {
                if devices.mics.isEmpty { Text("No Microphone").tag("") }
                ForEach(devices.mics, id: \.description) { Text($0).tag($0) }
            }
            LabeledContent("Input Level") {
                Gauge(value: devices.levelLive ? devices.level : 0) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(maxWidth: 160)
                    .accessibilityLabel(devices.levelLive ? "Input level" : "No input")
            }
            Picker("Speaker", selection: Binding(get: { devices.speaker ?? "" },
                                                 set: { devices.selectSpeaker($0.isEmpty ? nil : $0) })) {
                Text("System Default").tag("")
                ForEach(devices.speakers, id: \.description) { Text($0).tag($0) }
            }
            Picker("Camera", selection: Binding(get: { devices.camera ?? "" },
                                                set: { devices.selectCamera($0.isEmpty ? nil : $0) })) {
                if devices.cameras.isEmpty { Text("No Camera").tag("") }
                ForEach(devices.cameras) { Text($0.name).tag($0.id) }
            }
            if let e = devices.error {
                Text(e).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .disabled(!devices.loaded)
    }
}
