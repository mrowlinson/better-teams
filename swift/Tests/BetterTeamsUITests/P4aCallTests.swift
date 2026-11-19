// P4aCallTests.swift — P4a pins (UI-SPEC §8, DL1): a core-driven
// (remote) end tears down either host, the Show calls setting applies
// from the next call, the controls' state mapping, and the duration
// ticker's text.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P4aCallTests: XCTestCase {
    private func makeModel() -> WindowModel {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "p4a-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "p4a-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav
        addTeardownBlock { _ = nav }
        return model
    }

    /// §8 End, remote: the core slot going `ended` (other side or
    /// server) detaches the stage and releases the session in both
    /// hosts; the call window closes; the main window leaves `.call`.
    func testRemoteEndTearsDownBothHosts() {
        let model = makeModel()
        let store = CallStore(demo: true)

        store.seedDemo(state: "active")
        let main = model.beginCall(.person(name: "Jane Doe", thread: "19:p4a"), presentation: .mainWindow,
                                   store: store)
        XCTAssertEqual(model.nav.section, .call)
        XCTAssertEqual(main?.connected, true)
        let host = CallStageHostController()
        host.attach(main?.stage)
        XCTAssertTrue(main?.stage.parent === host)
        store.seedDemo(state: "ended")
        XCTAssertEqual(main?.endedRemotely, true)
        XCTAssertNil(model.call)
        XCTAssertNil(main?.stage.parent)
        XCTAssertNotEqual(model.nav.section, .call)

        // A leftover ended slot never ends the next call; its own end does.
        let sep = model.beginCall(.test, presentation: .separateWindow, show: false, store: store)
        XCTAssertEqual(sep?.ended, false)
        store.seedDemo(state: "active")
        let wc = sep?.makeWindowHost()
        XCTAssertNotNil(wc)
        XCTAssertNotNil(sep?.stage.parent)
        store.seedDemo(state: "ended")
        XCTAssertEqual(sep?.endedRemotely, true)
        XCTAssertNil(sep?.window)
        XCTAssertNil(sep?.stage.parent)
        XCTAssertNil(model.call)
    }

    /// DL1: the session reads Show calls when it starts; a change while
    /// a call runs applies to the next call only. Separate window →
    /// toolbar call item everywhere, no rail item; main window → rail
    /// item, toolbar item only outside the call section.
    func testShowCallsAppliesFromNextCall() {
        let model = makeModel()
        CallSettings.shared.useVolatileStorage(.separateWindow)
        defer { CallSettings.shared.useVolatileStorage() }

        let a = model.beginCall(.test, show: false)
        XCTAssertEqual(a?.presentation, .separateWindow)
        CallSettings.shared.presentation = .mainWindow
        XCTAssertEqual(a?.presentation, .separateWindow)
        XCTAssertEqual(a?.showsToolbarItem(in: .call), true)
        XCTAssertEqual(a?.showsRailItem, false)
        a?.leave()

        let b = model.beginCall(.test, show: false)
        XCTAssertEqual(b?.presentation, .mainWindow)
        XCTAssertEqual(b?.showsRailItem, true)
        XCTAssertEqual(b?.showsToolbarItem(in: .call), false)
        XCTAssertEqual(b?.showsToolbarItem(in: .chat), true)
        b?.leave()
        XCTAssertEqual(b?.showsRailItem, false)
    }

    /// §8 controls: symbols show state, labels name the action; before
    /// Join Now the Mute/Camera items drive the pre-join toggles (core
    /// untouched), after it the core slot; Share needs a joined call.
    func testControlsStateMapping() {
        let pre = CallControlsState(joined: false, muted: false, cameraOn: false, sharing: false)
        XCTAssertEqual(pre.mute.symbol, "mic.fill")
        XCTAssertEqual(pre.mute.label, "Mute")
        XCTAssertEqual(pre.camera.symbol, "video.slash.fill")
        XCTAssertEqual(pre.camera.menuTitle, "Turn Camera On")
        XCTAssertFalse(pre.share.enabled)
        let on = CallControlsState(joined: true, muted: true, cameraOn: true, sharing: true)
        XCTAssertEqual(on.mute.symbol, "mic.slash.fill")
        XCTAssertEqual(on.mute.menuTitle, "Unmute Microphone")
        XCTAssertEqual(on.camera.symbol, "video.fill")
        XCTAssertEqual(on.share.label, "Stop Sharing")
        XCTAssertTrue(on.share.enabled)

        let model = makeModel()
        let store = CallStore(demo: true)
        let s = model.beginCall(.meeting(id: "m1", subject: "Standup"), presentation: .mainWindow, show: false,
                                store: store)
        s?.toggleMute()
        XCTAssertEqual(s?.controls.muted, true)
        XCTAssertFalse(store.muted)
        XCTAssertEqual(CallSection().validate(CallCommands.mute, arg: nil, model).title, "Unmute Microphone")
        XCTAssertFalse(CallSection().validate(CallCommands.share, arg: nil, model).enabled)
        s?.joinNow()
        XCTAssertTrue(store.muted)
        XCTAssertEqual(s?.controls.muted, true)
        s?.toggleMute()
        XCTAssertFalse(store.muted)
        XCTAssertEqual(s?.controls.muted, false)
        XCTAssertTrue(CallSection().validate(CallCommands.share, arg: nil, model).enabled)
        s?.leave()
    }

    /// R7 ticker text: m:ss, h:mm:ss after an hour; VoiceOver minutes.
    /// The stage grid picks the largest tile (4 tiles at 16:9 → 2×2).
    func testDurationTextAndGrid() {
        XCTAssertEqual(CallDuration.text(0), "0:00")
        XCTAssertEqual(CallDuration.text(5), "0:05")
        XCTAssertEqual(CallDuration.text(754), "12:34")
        XCTAssertEqual(CallDuration.text(3600), "1:00:00")
        XCTAssertEqual(CallDuration.text(3723), "1:02:03")
        XCTAssertEqual(CallDuration.text(-3), "0:00")
        XCTAssertEqual(CallDuration.accessibility(754), "Current call, 12 minutes")
        XCTAssertEqual(CallDuration.accessibility(60), "Current call, 1 minute")
        XCTAssertEqual(CallDuration.accessibility(nil), "Current call")
        let g = TileGridLayout.grid(count: 4, in: CGSize(width: 808, height: 458), spacing: 8, aspect: 16.0 / 9.0)
        XCTAssertEqual(g.columns, 2)
        XCTAssertEqual(g.rows, 2)
    }

    /// meetrecord faces: idle names the start action, active names the
    /// stop; both need a joined call. The status line carries the legs
    /// in words (never color alone).
    func testRecordTranscribeFaces() {
        let idle = CallControlsState(joined: false, muted: false, cameraOn: false, sharing: false)
        XCTAssertEqual(idle.record.symbol, "record.circle")
        XCTAssertEqual(idle.record.menuTitle, "Start Recording")
        XCTAssertFalse(idle.record.enabled)
        XCTAssertEqual(idle.transcribe.symbol, "captions.bubble")
        XCTAssertEqual(idle.transcribe.menuTitle, "Start Transcription")
        XCTAssertFalse(idle.transcribe.enabled)
        XCTAssertNil(idle.control("call.nope"))

        let joined = CallControlsState(joined: true, muted: false, cameraOn: false, sharing: false)
        XCTAssertTrue(joined.record.enabled)
        XCTAssertTrue(joined.transcribe.enabled)
        XCTAssertEqual(joined.control(CallCommands.record)?.menuTitle, "Start Recording")
        XCTAssertEqual(joined.control(CallCommands.transcribe)?.menuTitle, "Start Transcription")

        let active = CallControlsState(joined: true, muted: false, cameraOn: false, sharing: false,
                                       recording: true, transcribing: true)
        XCTAssertEqual(active.record.symbol, "stop.circle")
        XCTAssertEqual(active.record.menuTitle, "Stop Recording")
        XCTAssertTrue(active.record.enabled)
        XCTAssertEqual(active.transcribe.menuTitle, "Stop Transcription")

        XCTAssertEqual(CallSession.captureSuffix("12:34", recording: false, transcribing: false), "12:34")
        XCTAssertEqual(CallSession.captureSuffix("12:34", recording: true, transcribing: false),
                       "12:34 • Recording")
        XCTAssertEqual(CallSession.captureSuffix("12:34", recording: false, transcribing: true),
                       "12:34 • Transcribing")
        XCTAssertEqual(CallSession.captureSuffix("12:34", recording: true, transcribing: true),
                       "12:34 • Recording + Transcribing")
    }

    /// meetrecord guards: Record/Transcribe validate off before Join Now
    /// and flip Start/Stop with the legs; the session toggles drive the
    /// demo store and mirror back; stopping transcription leaves a
    /// running recording untouched.
    func testRecordTranscribeToggles() {
        let model = makeModel()
        let store = CallStore(demo: true)
        let s = model.beginCall(.meeting(id: "m1", subject: "Standup"), presentation: .mainWindow, show: false,
                                store: store)
        XCTAssertEqual(CallSection().validate(CallCommands.record, arg: nil, model).title, "Start Recording")
        XCTAssertFalse(CallSection().validate(CallCommands.record, arg: nil, model).enabled)
        XCTAssertFalse(CallSection().validate(CallCommands.transcribe, arg: nil, model).enabled)
        // Pre-join toggles are no-ops (nothing captured before Join Now).
        s?.toggleRecording()
        XCTAssertFalse(store.recording)
        s?.joinNow()
        XCTAssertTrue(CallSection().validate(CallCommands.record, arg: nil, model).enabled)

        s?.toggleRecording()
        XCTAssertTrue(store.recording)
        XCTAssertTrue(store.transcribing)
        XCTAssertEqual(s?.recording, true)
        XCTAssertEqual(CallSection().validate(CallCommands.record, arg: nil, model).title, "Stop Recording")
        XCTAssertEqual(CallSection().validate(CallCommands.transcribe, arg: nil, model).title, "Stop Transcription")

        // Transcribe-stop drops transcription only (recording carries on).
        s?.toggleTranscribing()
        XCTAssertFalse(store.transcribing)
        XCTAssertTrue(store.recording)
        XCTAssertEqual(s?.transcribing, false)
        XCTAssertEqual(CallSection().validate(CallCommands.transcribe, arg: nil, model).title, "Start Transcription")

        // Record-stop ends both legs.
        s?.toggleRecording()
        XCTAssertFalse(store.recording)
        XCTAssertFalse(store.transcribing)
        s?.leave()
    }

    /// meetrecord store guard: without a connected call the live store
    /// refutes capture changes (no core call) and surfaces the reason.
    func testRecordStoreGuardsWithoutCall() {
        let store = CallStore(demo: false)
        XCTAssertNil(store.call)
        store.setRecording(true)
        XCTAssertFalse(store.recording)
        XCTAssertEqual(store.controlsError, "Recording needs a connected call")
        store.dismissControlsError()
        store.setTranscribing(true)
        XCTAssertFalse(store.transcribing)
        XCTAssertEqual(store.controlsError, "Recording needs a connected call")
    }
}
