// P3bCalendarCallsTests.swift — P3b pure-logic pins (UI-SPEC §6.4,
// §6.5, §8, DL1): Show calls setting default + persistence, the
// presentation picks the host, Calendar's empty state, and the Calls
// missed-call row built from the realtime feed's caller id.
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P3bCalendarCallsTests: XCTestCase {
    /// DL1: default In Main Window; a change persists and is what the
    /// next launch (a fresh settings object on the same store) reads.
    func testShowCallsDefaultsToMainWindowAndPersists() {
        let suite = "p3b-call-presentation-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let s = CallSettings(defaults: d)
        XCTAssertEqual(s.presentation, .mainWindow)
        s.presentation = .separateWindow
        XCTAssertEqual(CallSettings(defaults: d).presentation, .separateWindow)
        // Demo storage is volatile: no write reaches the store.
        s.useVolatileStorage()
        s.presentation = .mainWindow
        XCTAssertEqual(CallSettings(defaults: d).presentation, .separateWindow)
    }

    /// §8: In Main Window selects the call section (stage in the main
    /// window's content area, no window); In a Separate Window leaves
    /// the main window where it is and hosts the same stage in its own
    /// window. The session keeps the presentation it started with.
    func testPresentationPicksHost() {
        let chats = ChatListViewModel(fetcher: { _ in ChatsResponse(ok: true, chats: []) })
        let graph = AccountWindowGraph(account: AccountRecord(id: "p3b-test", displayName: "Test"), chats: chats)
        let model = WindowModel(graph: graph, accountKey: "p3b-test", options: LaunchOptions(args: ["--evidence"]))
        let nav = Navigator(model: model)
        model.navigator = nav

        let main = model.beginCall(.test, presentation: .mainWindow)
        XCTAssertEqual(main?.presentation, .mainWindow)
        XCTAssertEqual(model.nav.section, .call)
        XCTAssertNil(main?.window)
        XCTAssertTrue(model.call === main)
        main?.leave()
        XCTAssertNil(model.call)
        XCTAssertNotEqual(model.nav.section, .call)

        let before = model.nav.section
        let sep = model.beginCall(.test, presentation: .separateWindow, show: false)
        XCTAssertEqual(sep?.presentation, .separateWindow)
        XCTAssertEqual(model.nav.section, before)
        XCTAssertTrue(model.call === sep)
        // A second call while one runs is refused (no mid-call move).
        XCTAssertNil(model.beginCall(.test, presentation: .mainWindow, show: false))
        sep?.leave()
    }

    /// §6 pane states: a loaded week with no meetings is the empty
    /// state ("No Meetings This Week" + New Meeting…); R12: meetings on
    /// screen win over a refresh's loading or error.
    func testCalendarEmptyState() {
        XCTAssertEqual(CalendarPaneState.resolve(.empty, count: 0, forced: nil, offline: false), .empty)
        XCTAssertEqual(CalendarPaneState.resolve(.loaded, count: 0, forced: nil, offline: false), .empty)
        XCTAssertEqual(CalendarPaneState.resolve(.loading, count: 0, forced: nil, offline: false), .loading)
        XCTAssertEqual(CalendarPaneState.resolve(.loading, count: 3, forced: nil, offline: false), .meetings)
        XCTAssertEqual(CalendarPaneState.resolve(.error("x"), count: 3, forced: nil, offline: true), .meetings)
        XCTAssertEqual(CalendarPaneState.resolve(.error("x"), count: 0, forced: nil, offline: true),
                       .error(title: CalendarPaneState.errorTitle, message: "You\u{2019}re offline."))
        XCTAssertEqual(CalendarPaneState.resolve(.loaded, count: 3, forced: .empty, offline: false), .empty)
    }

    /// §6.5 + core-a: a realtime missed call (Activity row with the
    /// caller id) that the history never saw is a Recent row keyed by
    /// that caller id; the same caller in the history within the
    /// missed-call window is one call, not two.
    func testMissedCallRowUsesCallerID() {
        let t: UInt64 = 1_790_000_000
        let feed = ActivityItem(kind: .missedCall, chatID: "19:ava", actor: "Ava Lindqvist", at: t,
                                id: "missedCall:-:ev1", callerID: "8:orgid:AVA")
        let rows = CallsRowModel.rows(history: [], activity: [feed])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, CallsRowModel.activityPrefix + "missedCall:-:ev1")
        XCTAssertEqual(rows.first?.personID, "8:orgid:AVA")
        XCTAssertEqual(rows.first?.personKey, "8:orgid:ava")
        XCTAssertEqual(rows.first?.direction, .missed)
        XCTAssertEqual(rows.first?.thread, "19:ava")
        XCTAssertEqual(rows.first?.detailLine, "Missed")

        let rec = CallRecord(id: "c1", direction: .missed, peer: "8:orgid:ava", peerName: "Ava Lindqvist",
                             startedAt: t + 60, endedAt: t + 90)
        let merged = CallsRowModel.rows(history: [rec], activity: [feed])
        XCTAssertEqual(merged.map(\.id), [CallsRowModel.recordPrefix + "c1"])
        let later = CallsRowModel.rows(history: [rec], activity: [
            ActivityItem(kind: .missedCall, chatID: "19:ava", actor: "Ava Lindqvist",
                         at: t + 60 + ActivityStore.missedCallWindow + 1, id: "missedCall:-:ev2",
                         callerID: "8:orgid:ava"),
        ])
        XCTAssertEqual(later.count, 2)
    }
}
