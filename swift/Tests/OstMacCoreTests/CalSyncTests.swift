// CalSyncTests.swift — guard-pinned tests for the CalSync lane.
// Every safety guard has at least one test; delete to weaken a guard and
// these go red. Mock transport/sinks only: zero network, zero EventKit.
import XCTest
@testable import OstMacCore

final class CalSyncTests: XCTestCase {
    private let upn = "tester@example.com"
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func config(_ mutate: (inout CalSyncConfig) -> Void = { _ in }) -> CalSyncConfig {
        var c = CalSyncConfig(targetUPN: upn)
        mutate(&c)
        return c
    }

    private func deltaPage() -> CalDeltaPage {
        CalDeltaPage(
            events: [
                GraphDeltaEvent(
                    id: "g1", subject: "Standup",
                    start: "2026-09-28T09:00:00", end: "2026-09-28T09:15:00",
                    updatedAt: "2026-09-26T10:00:00"),
                GraphDeltaEvent(id: "g-gone", deleted: true),
            ],
            deltaLink: "dl-1")
    }

    // MARK: - Guard 3: allowlist

    func testEmptyAllowlistRefusesInbound() {
        let c = CalSyncConfig(targetUPN: nil)
        XCTAssertThrowsError(try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)) { err in
            XCTAssertEqual(err as? CalSyncError, .allowlistEmpty)
        }
    }

    func testEmptyAllowlistRefusesOutbound() {
        let c = CalSyncConfig(targetUPN: "  ")
        XCTAssertThrowsError(try CalSyncPlanner.planOutbound(
            changes: [EKEventChange(localID: "l1")], config: c,
            accountUPN: upn, now: now)) { err in
            XCTAssertEqual(err as? CalSyncError, .allowlistEmpty)
        }
    }

    func testMismatchRefusesAllOps() {
        let c = config()
        XCTAssertThrowsError(try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: "intruder@evil.com", now: now)) { err in
            XCTAssertEqual(
                err as? CalSyncError,
                .allowlistMismatch(expected: upn, got: "intruder@evil.com"))
        }
        XCTAssertThrowsError(try CalSyncPlanner.planOutbound(
            changes: [EKEventChange(localID: "l1")], config: c,
            accountUPN: "intruder@evil.com", now: now)) { err in
            XCTAssertEqual(
                err as? CalSyncError,
                .allowlistMismatch(expected: upn, got: "intruder@evil.com"))
        }
    }

    func testAllowlistMatchIsCaseInsensitive() throws {
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: config(),
            accountUPN: "TESTER@example.com", now: now)
        XCTAssertEqual(plan.accountUPN, upn)
    }

    // MARK: - Guard 2: window

    func testDefaultWindowIs30() {
        XCTAssertEqual(CalSyncConfig.defaultWindowDays, 30)
        XCTAssertEqual(CalSyncConfig().windowDays, 30)
    }

    func testWindowOver90Rejected() {
        let c = config { $0.windowDays = 91 }
        XCTAssertThrowsError(try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)) { err in
            XCTAssertEqual(
                err as? CalSyncError,
                .windowTooLarge(requestedDays: 91, maxDays: 90))
        }
    }

    func testWindow90Accepted() throws {
        let c = config { $0.windowDays = 90 }
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)
        XCTAssertEqual(plan.window.radiusDays, 90)
    }

    func testZeroWindowClampedToDefault() throws {
        let c = config { $0.windowDays = 0 }
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)
        XCTAssertEqual(plan.window.radiusDays, 30)
        XCTAssertTrue(plan.log.contains { $0.kind == "window" })
    }

    // MARK: - Guard 1: dry-run

    func testDryRunDefaultOn() {
        XCTAssertTrue(CalSyncConfig().dryRun)
        XCTAssertFalse(CalSyncConfig().liveWritesEnabled)
        XCTAssertFalse(CalSyncConfig().liveExecutionAllowed)
    }

    func testDryRunExecutesNothing() throws {
        let c = config() // dryRun=true
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)
        XCTAssertFalse(plan.ekOps.isEmpty) // work was planned...
        let ek = MockEKSink()
        let gr = MockGraphSink()
        let receipt = try CalSyncExecutor.execute(
            plan: plan, config: c, ekSink: ek, graphSink: gr, now: now)
        XCTAssertEqual(receipt.executedTotal, 0)
        XCTAssertEqual(ek.calls.count, 0) // ...but zero sink calls
        XCTAssertEqual(gr.calls.count, 0)
        XCTAssertEqual(receipt.wouldExecuteEK, plan.ekOps.count)
        XCTAssertTrue(receipt.dryRun)
    }

    func testLiveWithoutFlagRefusesAndCallsNothing() throws {
        let c = config { $0.dryRun = false } // live flag still OFF
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)
        let ek = MockEKSink()
        let gr = MockGraphSink()
        XCTAssertThrowsError(try CalSyncExecutor.execute(
            plan: plan, config: c, ekSink: ek, graphSink: gr, now: now)) { err in
            XCTAssertEqual(err as? CalSyncError, .liveWritesNotEnabled)
        }
        XCTAssertEqual(ek.calls.count, 0)
        XCTAssertEqual(gr.calls.count, 0)
    }

    func testLiveWithBothFlagsExecutesMocks() throws {
        let c = config { $0.dryRun = false; $0.liveWritesEnabled = true }
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)
        let ek = MockEKSink()
        let gr = MockGraphSink()
        let receipt = try CalSyncExecutor.execute(
            plan: plan, config: c, ekSink: ek, graphSink: gr, now: now)
        XCTAssertFalse(receipt.dryRun)
        XCTAssertEqual(receipt.executedEK, plan.ekOps.count)
        XCTAssertEqual(ek.calls.count, 1)
    }

    // MARK: - Guard 4: deletes held

    func testDeletesHeldWithoutFlag() throws {
        let c = config() // deletionPropagationEnabled=false
        XCTAssertFalse(c.deletionPropagationEnabled)
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: ["g1"], config: c,
            accountUPN: upn, now: now)
        XCTAssertTrue(plan.ekOps.allSatisfy { !$0.isDelete })
        XCTAssertEqual(plan.heldDeletes.count, 1)
        XCTAssertEqual(plan.heldDeletes[0].graphID, "g-gone")
        XCTAssertTrue(plan.log.contains { $0.kind == "delete-held" })
    }

    func testOutboundDeletesHeldWithoutFlag() throws {
        let c = config()
        let plan = try CalSyncPlanner.planOutbound(
            changes: [EKEventChange(localID: "l9", graphID: "g9", deleted: true)],
            config: c, accountUPN: upn, now: now)
        XCTAssertTrue(plan.graphOps.isEmpty)
        XCTAssertEqual(plan.heldDeletes.count, 1)
        XCTAssertEqual(plan.heldDeletes[0].direction, "outbound")
    }

    func testDeletesFlowWithFlag() throws {
        let c = config { $0.deletionPropagationEnabled = true }
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: ["g1"], config: c,
            accountUPN: upn, now: now)
        XCTAssertEqual(plan.heldDeletes.count, 0)
        XCTAssertTrue(plan.ekOps.contains { $0 == .delete(graphID: "g-gone") })
    }

    func testHeldDeletesNeverExecuteEvenLive() throws {
        let c = config {
            $0.dryRun = false; $0.liveWritesEnabled = true
            // delete flag stays OFF
        }
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: ["g1"], config: c,
            accountUPN: upn, now: now)
        let ek = MockEKSink()
        let receipt = try CalSyncExecutor.execute(
            plan: plan, config: c, ekSink: ek,
            graphSink: MockGraphSink(), now: now)
        XCTAssertEqual(receipt.heldDeletes, 1)
        XCTAssertTrue(ek.calls.flatMap(\.self).allSatisfy { !$0.isDelete })
    }

    // MARK: - Planner mapping

    func testInboundMapsCreateVsUpdate() throws {
        let page = CalDeltaPage(events: [
            GraphDeltaEvent(id: "known", subject: "K"),
            GraphDeltaEvent(id: "new", subject: "N"),
        ])
        let plan = try CalSyncPlanner.planInbound(
            delta: page, knownGraphIDs: ["known"], config: config(),
            accountUPN: upn, now: now)
        XCTAssertTrue(plan.ekOps.contains {
            if case .update("known", _, _, _) = $0 { return true }
            return false
        })
        XCTAssertTrue(plan.ekOps.contains {
            if case .create("new", _, _, _) = $0 { return true }
            return false
        })
    }

    func testOutboundMapsCreateVsUpdate() throws {
        let plan = try CalSyncPlanner.planOutbound(
            changes: [
                EKEventChange(localID: "l1", graphID: "g1", subject: "U"),
                EKEventChange(localID: "l2", subject: "C"),
            ],
            config: config(), accountUPN: upn, now: now)
        XCTAssertTrue(plan.graphOps.contains {
            if case .update("g1", _, _, _) = $0 { return true }
            return false
        })
        XCTAssertTrue(plan.graphOps.contains {
            if case .create("l2", _, _, _) = $0 { return true }
            return false
        })
    }

    func testOutboundLocalDeleteWithoutGraphIDDropped() throws {
        let plan = try CalSyncPlanner.planOutbound(
            changes: [EKEventChange(localID: "lX", deleted: true)],
            config: config { $0.deletionPropagationEnabled = true },
            accountUPN: upn, now: now)
        XCTAssertTrue(plan.graphOps.isEmpty)
        XCTAssertTrue(plan.heldDeletes.isEmpty)
        XCTAssertTrue(plan.log.contains { $0.kind == "delete-drop" })
    }

    // MARK: - Conflict rule: Teams-wins-with-log

    func testConflictTeamsWinsWithLog() throws {
        let page = CalDeltaPage(events: [
            GraphDeltaEvent(id: "g1", subject: "Teams version"),
        ])
        let plan = try CalSyncPlanner.planBidirectional(
            delta: page, knownGraphIDs: ["g1"],
            localChanges: [
                EKEventChange(
                    localID: "l1", graphID: "g1", subject: "Local version"),
                EKEventChange(localID: "l2", subject: "No conflict"),
            ],
            config: config(), accountUPN: upn, now: now)
        XCTAssertEqual(plan.conflictsTeamsWon, ["g1"])
        XCTAssertFalse(plan.ekOps.isEmpty) // Graph side kept
        XCTAssertEqual(plan.graphOps.count, 1) // only the clean create
        XCTAssertTrue(plan.log.contains { $0.kind == "conflict-teams-wins" })
    }

    // MARK: - Delta apply

    func testDeltaApplyUpsertsAndDrops() {
        let cached = [
            MeetingItem(meetingId: "g1", subject: "Old"),
            MeetingItem(meetingId: "g-gone", subject: "Doomed"),
        ]
        let (merged, applied, dropped) = CalDeltaApply.apply(
            cached: cached, delta: deltaPage())
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(
            merged.first { $0.meetingId == "g1" }?.subject, "Standup")
        XCTAssertFalse(merged.contains { $0.meetingId == "g-gone" })
    }

    func testDeltaApplyKeepsJoinAndOrganizerOnUpdatedRow() {
        let cached = [MeetingItem(
            meetingId: "g1", subject: "Old", joinURL: "https://teams.microsoft.com/l/meetup-join/x",
            organizer: "Laura Bennett", organizerEmail: "laura@contoso.com",
            isOrganizer: true, isOnline: true)]
        let (merged, applied, _) = CalDeltaApply.apply(
            cached: cached, delta: deltaPage())
        XCTAssertEqual(applied, 1)
        let row = merged.first { $0.meetingId == "g1" }
        XCTAssertEqual(row?.subject, "Standup")
        XCTAssertEqual(row?.joinURL, "https://teams.microsoft.com/l/meetup-join/x")
        XCTAssertEqual(row?.organizer, "Laura Bennett")
        XCTAssertEqual(row?.organizerEmail, "laura@contoso.com")
        XCTAssertEqual(row?.isOrganizer, true)
        XCTAssertEqual(row?.isOnline, true)
    }

    func testDeltaApplyEmptyPageIsNoop() {
        let cached = [MeetingItem(meetingId: "g1", subject: "Keep")]
        let (merged, applied, dropped) = CalDeltaApply.apply(
            cached: cached, delta: CalDeltaPage(events: [], deltaLink: "dl"))
        XCTAssertEqual(applied, 0)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(merged, cached)
    }

    // MARK: - Mock transport

    func testMockTransportRecordsWindow() throws {
        let c = config { $0.windowDays = 14 }
        let radius = try c.validatedWindowRadius()
        let window = CalSyncWindow(radiusDays: radius, now: now)
        let t = MockGraphTransport(firstPage: deltaPage())
        let page = try t.fetchDelta(since: nil, window: window)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(t.fetches.count, 1)
        XCTAssertEqual(t.fetches[0].radiusDays, 14)
        // Window really spans +-14d.
        XCTAssertEqual(
            window.end.timeIntervalSince(window.start), 28 * 86_400,
            accuracy: 1)
    }

    func testEndToEndMockFetchPlanDryRun() throws {
        let c = config()
        let window = CalSyncWindow(
            radiusDays: try c.validatedWindowRadius(), now: now)
        let t = MockGraphTransport(firstPage: deltaPage())
        let page = try t.fetchDelta(since: nil, window: window)
        let plan = try CalSyncPlanner.planInbound(
            delta: page, knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)
        let ek = MockEKSink()
        let receipt = try CalSyncExecutor.execute(
            plan: plan, config: c, ekSink: ek,
            graphSink: MockGraphSink(), now: now)
        XCTAssertEqual(t.fetches.count, 1)
        XCTAssertEqual(receipt.executedTotal, 0)
        XCTAssertEqual(ek.calls.count, 0)
    }

    // MARK: - Diagnostics hook

    func testDiagnosticsSnapshot() throws {
        let c = config()
        let plan = try CalSyncPlanner.planInbound(
            delta: deltaPage(), knownGraphIDs: [], config: c,
            accountUPN: upn, now: now)
        let d = CalSyncDiagnostics.snapshot(config: c, lastPlan: plan)
        XCTAssertTrue(d.targetUPNSet)
        XCTAssertTrue(d.dryRun)
        XCTAssertFalse(d.liveWritesEnabled)
        XCTAssertEqual(d.windowDays, 30)
        XCTAssertFalse(d.deletionPropagationEnabled)
        XCTAssertEqual(d.lastPlanWrites, plan.pendingWriteCount)
        XCTAssertFalse(d.logTail.isEmpty)
    }
}
