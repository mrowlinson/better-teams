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
}
