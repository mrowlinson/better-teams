// MeetingsPlusTests.swift — MEETINGS-PLUS: attendance + capture
// options models, demo transports, and the 403 disabled reasons.
import XCTest
@testable import OstMacCore

@MainActor
final class MeetingsPlusTests: XCTestCase {
    func testDurationLabels() {
        XCTAssertEqual(AttendanceEntry.durationLabel(0), "0:00")
        XCTAssertEqual(AttendanceEntry.durationLabel(43), "0:43")
        XCTAssertEqual(AttendanceEntry.durationLabel(725), "12:05")
        XCTAssertEqual(AttendanceEntry.durationLabel(3723), "1:02:03")
    }

    func testSpanLabels() {
        let both = AttendanceEntry(displayName: "A", role: "attendee",
                                   joinDT: "2026-11-19T14:00:00Z",
                                   leaveDT: "2026-11-19T14:30:00Z")
        XCTAssertTrue(both.spanLabel.contains("–"))
        XCTAssertFalse(both.spanLabel.contains("…"))
        let ongoing = AttendanceEntry(displayName: "A", role: "attendee",
                                      joinDT: "2026-11-19T14:00:00Z")
        XCTAssertTrue(ongoing.spanLabel.contains("…"))
        let unknown = AttendanceEntry(displayName: "A", role: "attendee")
        XCTAssertEqual(unknown.spanLabel, "Time unknown")
    }

    func testClockFallsBackToRaw() {
        XCTAssertEqual(AttendanceEntry.clock("not-a-date"), "not-a-date")
        XCTAssertFalse(AttendanceEntry.clock("2026-11-19T14:00:00Z").isEmpty)
    }

    func testPatchBodyOnlySetsSetFields() throws {
        let opts = MeetingCaptureOptions(allowRecording: true, recordAutomatically: false)
        let body = try JSONSerialization.jsonObject(with: opts.patchBody.data(using: .utf8)!) as? [String: Bool]
        XCTAssertEqual(body, ["allowRecording": true, "recordAutomatically": false])
        let empty = MeetingCaptureOptions()
        XCTAssertEqual(empty.patchBody, "{}")
    }

    func testDemoAttendanceHasRows() throws {
        let rows = try DemoMeetingAttendanceTransport().attendance(meetingID: "M1")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].displayName, "Ava Stone")
        XCTAssertEqual(rows[0].durationSecs, 1845)
    }

    func testDemoCaptureEchoesSave() throws {
        let t = DemoMeetingCaptureTransport()
        let loaded = try t.load(meetingID: "M1")
        XCTAssertEqual(loaded.allowRecording, true)
        let next = MeetingCaptureOptions(allowRecording: false, allowTranscription: true)
        XCTAssertEqual(try t.save(meetingID: "M1", options: next), next)
    }

    func testWordMaps403ToDisabledReason() {
        XCTAssertEqual(MeetingAttendanceStore.word(CoreCallError.failed("HTTP 403 for url: denied")),
                       MeetingAttendanceStore.liveDisabledReason)
        XCTAssertEqual(MeetingCaptureStore.word(CoreCallError.failed("HTTP 403 for url: denied")),
                       MeetingCaptureStore.liveDisabledReason)
    }

    func testWordKeepsOtherFailures() {
        let other = MeetingAttendanceStore.word(CoreCallError.failed("boom"))
        XCTAssertNotEqual(other, MeetingAttendanceStore.liveDisabledReason)
        XCTAssertFalse(other.isEmpty)
    }

    func testDemoFixturesAreWesternNames() {
        for row in MeetingAttendanceDemo.entries {
            XCTAssertFalse(row.displayName.isEmpty)
        }
    }

    private func waitFor(_ cond: @escaping @MainActor () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        await TestWait.until(ceiling: timeout, interval: 0.02) { cond() }
    }

    @MainActor
    func testAttendanceStoreLoadsDemoRows() async {
        let s = MeetingAttendanceStore(meetingID: "M1", transport: DemoMeetingAttendanceTransport())
        s.load()
        let done = await waitFor { if case .loading = s.state { return false }; return true }
        XCTAssertTrue(done)
        if case let .loaded(rows) = s.state {
            XCTAssertEqual(rows.count, 3)
            XCTAssertEqual(rows[0].displayName, "Ava Stone")
        } else {
            XCTFail("expected loaded, got \(s.state)")
        }
    }

    struct FailingAttendance: MeetingAttendanceTransport {
        func attendance(meetingID _: String) throws -> [AttendanceEntry] {
            throw CoreCallError.failed("HTTP 403 for url: denied")
        }
    }

    @MainActor
    func testAttendanceStoreMaps403ToDisabledReason() async {
        let s = MeetingAttendanceStore(meetingID: "M1", transport: FailingAttendance())
        s.load()
        let done = await waitFor { if case .failed = s.state { return true }; return false }
        XCTAssertTrue(done)
        XCTAssertEqual(s.state, .failed(MeetingAttendanceStore.liveDisabledReason))
    }

    @MainActor
    func testCaptureStoreLoadsAndSavesDemo() async {
        let s = MeetingCaptureStore(meetingID: "M1", transport: DemoMeetingCaptureTransport())
        s.load()
        let done = await waitFor { !s.loading }
        XCTAssertTrue(done)
        XCTAssertEqual(s.options?.allowRecording, true)
        let next = MeetingCaptureOptions(allowRecording: false, allowTranscription: true)
        s.save(next)
        let saved = await waitFor { s.options == next && !s.saving }
        XCTAssertTrue(saved)
    }

    struct FailingCapture: MeetingCaptureTransport {
        func load(meetingID _: String) throws -> MeetingCaptureOptions {
            throw CoreCallError.failed("HTTP 403 for url: denied")
        }
        func save(meetingID _: String, options _: MeetingCaptureOptions) throws -> MeetingCaptureOptions {
            throw CoreCallError.failed("HTTP 403 for url: denied")
        }
    }

    @MainActor
    func testCaptureStoreMaps403ToDisabledReason() async {
        let s = MeetingCaptureStore(meetingID: "M1", transport: FailingCapture())
        s.load()
        let done = await waitFor { !s.loading }
        XCTAssertTrue(done)
        XCTAssertEqual(s.error, MeetingCaptureStore.liveDisabledReason)
    }
}
