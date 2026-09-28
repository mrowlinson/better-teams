// GhostModeTests.swift — f1-ghost: read-privacy controls.
//
// Ghost mode suppresses OWN outbound signals only (read-receipt PUTs,
// presence writes). Incoming receipts/presence still render; local
// unread badges still clear on open (accept-3 choice (i)); presence
// ghost is a pure freeze — enabling writes nothing (accept-4
// choice (ii), no Offline mask).
import XCTest

@testable import OstMacCore

private final class GhostSendBox: @unchecked Sendable {
    var calls: [(String, String)] = []
}

private final class GhostSetBox: @unchecked Sendable {
    var calls: [String] = []
}

@MainActor
final class GhostModeTests: XCTestCase {
    private func ghostDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-ghost-\(UUID().uuidString)") ?? .standard
    }

    private func ghost(
        master: Bool = false, receipts: Bool = false, presence: Bool = false
    ) -> GhostStore {
        let g = GhostStore(defaults: ghostDefaults())
        g.master = master
        g.suppressReceipts = receipts
        g.suppressPresence = presence
        return g
    }

    /// Window covering the whole local day (any weekday).
    private func allDayEntry(status: PresenceStatus = .busy) -> PresenceScheduleEntry {
        PresenceScheduleEntry(
            window: QuietHoursWindow(
                enabled: true, startMinutes: 0, endMinutes: 23 * 60 + 59,
                days: [1, 2, 3, 4, 5, 6, 7]),
            status: status)
    }

    // MARK: - master/sub matrix (accept 6)

    func testMasterOffForcesLiveAllCombos() {
        for receipts in [false, true] {
            for presence in [false, true] {
                let g = ghost(master: false, receipts: receipts, presence: presence)
                XCTAssertFalse(g.shouldSuppressReceipts, "r=\(receipts) p=\(presence)")
                XCTAssertFalse(g.shouldSuppressPresence, "r=\(receipts) p=\(presence)")
            }
        }
    }

    func testMasterOnAppliesSubsIndependently() {
        for receipts in [false, true] {
            for presence in [false, true] {
                let g = ghost(master: true, receipts: receipts, presence: presence)
                XCTAssertEqual(g.shouldSuppressReceipts, receipts)
                XCTAssertEqual(g.shouldSuppressPresence, presence)
            }
        }
    }

    // MARK: - receipt suppression (accepts 1-2)

    func testReceiptGhostOnSendsZero() async {
        let box = GhostSendBox()
        let g = ghost(master: true, receipts: true)
        let store = ReceiptStore(
            sender: { chat, mid in box.calls.append((chat, mid)) },
            fetcher: { _ in [] })
        store.ghost = g
        // Open + scroll-to-bottom + tail-follow + jump: all suppressed.
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        store.sendReadPosition(chatID: "c1", latestID: "m2")
        store.sendReadPosition(chatID: "c1", latestID: "m3")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.calls.count, 0)
        XCTAssertNil(store.sent["c1"]) // stays retryable (failure rule)
        XCTAssertNil(store.lastError) // suppression is not a failure
        XCTAssertEqual(g.suppressedReceipts, 3)
    }

    func testReceiptGhostOffSendsNormally() async {
        let box = GhostSendBox()
        let g = ghost(master: false, receipts: true) // sub on, master off
        let store = ReceiptStore(
            sender: { chat, mid in box.calls.append((chat, mid)) },
            fetcher: { _ in [] })
        store.ghost = g
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        await waitFor { store.sent["c1"] == "m1" }
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(g.suppressedReceipts, 0)
    }

    func testReceiptPresenceOnlyDoesNotGateReceipts() async {
        let box = GhostSendBox()
        let g = ghost(master: true, presence: true) // receipts sub off
        let store = ReceiptStore(
            sender: { chat, mid in box.calls.append((chat, mid)) },
            fetcher: { _ in [] })
        store.ghost = g
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        await waitFor { store.sent["c1"] == "m1" }
        XCTAssertEqual(box.calls.count, 1)
    }

    func testReceiptPeersStillMergeWhileGhosted() async {
        let g = ghost(master: true, receipts: true)
        let store = ReceiptStore(
            sender: { _, _ in XCTFail("no sends while ghosted") },
            fetcher: { _ in [ReadReceipt(user: "peer", message_id: "m2")] })
        store.ghost = g
        store.refresh(threadID: "c1")
        await waitFor { store.peerReadIDs(for: "c1") == ["m2"] }
        XCTAssertNil(store.lastError)
    }

    func testReceiptLiftSendsCurrentTailOnce() async {
        let box = GhostSendBox()
        let g = ghost(master: true, receipts: true)
        let store = ReceiptStore(
            sender: { chat, mid in box.calls.append((chat, mid)) },
            fetcher: { _ in [] })
        store.ghost = g
        store.sendReadPosition(chatID: "c1", latestID: "m1")
        store.sendReadPosition(chatID: "c1", latestID: "m2")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(box.calls.isEmpty)
        // Lift: next tail view sends the CURRENT tail once (no backlog).
        g.master = false
        store.sendReadPosition(chatID: "c1", latestID: "m3")
        await waitFor { store.sent["c1"] == "m3" }
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(box.calls.first?.1, "m3")
    }

    // MARK: - read-local contract (accept 3, choice (i))

    func testLocalBadgesStillClearWhileGhosted() {
        // Ghost suppresses server sends ONLY: opening a chat still
        // clears its local unread badge + dock (no ghost seam on
        // UnreadStore by design — least surprise).
        _ = ghost(master: true, receipts: true)
        let dock = FakeDockBadge()
        let unread = UnreadStore(dock: dock)
        unread.markUnread(chatID: "c1")
        XCTAssertTrue(unread.isUnread(chatID: "c1"))
        unread.markRead(chatID: "c1")
        XCTAssertFalse(unread.isUnread(chatID: "c1"))
    }

    // MARK: - presence suppression (accepts 4-5)

    func testPresenceGhostOnHoldsManualSets() async {
        let box = GhostSetBox()
        let g = ghost(master: true, presence: true)
        let store = PresenceStore(setFetcher: { want in
            box.calls.append(want)
            return PresenceResponse(ok: true, availability: "Busy", activity: "Busy")
        })
        store.ghost = g
        var hookFired = false
        store.manualSetHook = { hookFired = true }
        store.set(status: .busy)
        store.set(status: .away)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(box.calls.count, 0)
        XCTAssertNil(store.own) // unchanged (no echo adopted)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.setting) // no spinner state for held sets
        XCTAssertFalse(hookFired) // held sets never pause the schedule
        XCTAssertEqual(g.heldPresence, 2)
    }

    func testPresenceGhostOffResumesNoReplay() async {
        let box = GhostSetBox()
        let g = ghost(master: true, presence: true)
        let store = PresenceStore(setFetcher: { want in
            box.calls.append(want)
            return PresenceResponse(ok: true, availability: "Available", activity: "Available")
        })
        store.ghost = g
        store.set(status: .busy) // held…
        g.master = false // …then dropped, never replayed
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(box.calls.isEmpty)
        // First post-ghost set goes through immediately.
        store.set(status: .available)
        await waitFor { store.own?.availability == "Available" }
        XCTAssertEqual(box.calls, ["available"])
    }

    func testPresenceReceiptsOnlyDoesNotGatePresence() async {
        let box = GhostSetBox()
        let g = ghost(master: true, receipts: true) // presence sub off
        let store = PresenceStore(setFetcher: { want in
            box.calls.append(want)
            return PresenceResponse(ok: true, availability: "Busy", activity: "Busy")
        })
        store.ghost = g
        store.set(status: .busy)
        await waitFor { store.own?.availability == "Busy" }
        XCTAssertEqual(box.calls.count, 1)
    }

    func testPresenceReadsContinueWhileGhosted() async {
        // refreshOwn is a read (never gated): the dot shows last known.
        let g = ghost(master: true, presence: true)
        let store = PresenceStore(
            ownFetcher: { PresenceResponse(ok: true, availability: "Busy", activity: "InACall") },
            setFetcher: { _ in
                XCTFail("no writes while ghosted")
                return PresenceResponse(ok: true, availability: "Busy", activity: "Busy")
            })
        store.ghost = g
        await store.refreshOwn()
        XCTAssertEqual(store.own?.availability, "Busy")
    }

    func testGhostEnableWritesNothingPureFreeze() async {
        // Accept-4 choice (ii): enabling ghost performs ZERO presence
        // writes (no Offline mask — the last server value lingers).
        let box = GhostSetBox()
        let g = ghost()
        let store = PresenceStore(setFetcher: { want in
            box.calls.append(want)
            return PresenceResponse(ok: true, availability: "Available", activity: "Available")
        })
        store.ghost = g
        g.master = true
        g.suppressPresence = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(box.calls.isEmpty)
        XCTAssertEqual(g.heldPresence, 0) // enabling itself holds nothing
    }

    // MARK: - scheduled sets held (accept 4, e2-attention path)

    func testScheduleSetsHeldWhileGhosted() async {
        let box = GhostSetBox()
        let g = ghost(master: true, presence: true)
        let sched = PresenceScheduleStore(
            defaults: ghostDefaults(),
            setFetcher: { want in
                box.calls.append(want)
                return PresenceResponse(ok: true, availability: "Busy", activity: "Busy")
            })
        sched.ghost = g
        sched.enabled = true
        _ = sched.addEntry(allDayEntry(status: .busy))
        sched.tick()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(box.calls.isEmpty)
        XCTAssertNil(sched.appliedEntryID) // transition still pending
        XCTAssertNil(sched.lastStatus)
        XCTAssertNil(sched.error)
        XCTAssertEqual(g.heldPresence, 1)
    }

    func testScheduleResumesCurrentWindowOnLift() async {
        let box = GhostSetBox()
        let g = ghost(master: true, presence: true)
        let sched = PresenceScheduleStore(
            defaults: ghostDefaults(),
            setFetcher: { want in
                box.calls.append(want)
                return PresenceResponse(ok: true, availability: "Busy", activity: "Busy")
            })
        sched.ghost = g
        sched.enabled = true
        _ = sched.addEntry(allDayEntry(status: .busy))
        sched.tick()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(box.calls.isEmpty)
        g.master = false
        sched.tick()
        await waitFor { sched.lastStatus == .busy }
        XCTAssertEqual(box.calls, ["busy"]) // current window, once
    }

    // MARK: - persistence + sign-out (accept 6)

    func testTogglesRoundTrip() {
        let defaults = ghostDefaults()
        let g = GhostStore(defaults: defaults)
        g.master = true
        g.suppressReceipts = true
        g.suppressPresence = false
        let rebuilt = GhostStore(defaults: defaults)
        XCTAssertTrue(rebuilt.master)
        XCTAssertTrue(rebuilt.suppressReceipts)
        XCTAssertFalse(rebuilt.suppressPresence)
    }

    func testDefaultsOff() {
        let g = GhostStore(defaults: ghostDefaults())
        XCTAssertFalse(g.master)
        XCTAssertFalse(g.suppressReceipts)
        XCTAssertFalse(g.suppressPresence)
        XCTAssertFalse(g.shouldSuppressReceipts)
        XCTAssertFalse(g.shouldSuppressPresence)
    }

    func testSignOutClearsCountersKeepsToggles() {
        let g = ghost(master: true, receipts: true, presence: true)
        g.noteSuppressedReceipt()
        g.noteHeldPresence()
        XCTAssertEqual(g.suppressedReceipts, 1)
        XCTAssertEqual(g.heldPresence, 1)
        g.clear()
        XCTAssertEqual(g.suppressedReceipts, 0)
        XCTAssertEqual(g.heldPresence, 0)
        XCTAssertTrue(g.master)
        XCTAssertTrue(g.suppressReceipts)
        XCTAssertTrue(g.suppressPresence)
    }

    // MARK: - diagnostics (accept 7)

    func testGhostLine() {
        XCTAssertEqual(
            DiagnosticsFormat.ghostLine(
                master: false, receipts: false, presence: false,
                suppressed: 0, held: 0),
            "off · 0 suppressed · 0 held")
        XCTAssertEqual(
            DiagnosticsFormat.ghostLine(
                master: true, receipts: true, presence: true,
                suppressed: 3, held: 1),
            "on (receipts + presence) · 3 suppressed · 1 held")
        XCTAssertEqual(
            DiagnosticsFormat.ghostLine(
                master: true, receipts: true, presence: false,
                suppressed: 2, held: 0),
            "on (receipts) · 2 suppressed · 0 held")
        // Master off reads off even with stale sub-toggles.
        XCTAssertEqual(
            DiagnosticsFormat.ghostLine(
                master: false, receipts: true, presence: true,
                suppressed: 0, held: 0),
            "off · 0 suppressed · 0 held")
    }

    // MARK: - helpers

    /// Spin until `cond` holds (mock transports resolve in ms; 2s cap).
    private func waitFor(
        _ cond: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0 ..< 100 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met in 2s", file: file, line: line)
    }
}
