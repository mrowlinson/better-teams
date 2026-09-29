// MeetingsTests.swift — om-meet-join lane: wire decode, lobby machine,
// join hints, ViewModel flow, pre-join toggles. No hardware is touched:
// camera/mic assertions cover published defaults and toggle-off paths
// only (start() would prompt TCC), so the suite degrades cleanly
// headless.
import XCTest

@testable import OstMacCore

@MainActor
final class MeetingsTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func meetingsJSON() -> MeetingsResponse {
        let json = """
            {"ok":true,"meetings":[\
            {"id":"E1","subject":"Standup","start":"2024-05-06T09:00:00.0000000",\
            "end":"2024-05-06T09:15:00.0000000",\
            "join_url":"https://teams.microsoft.com/l/meetup-join/19:abc@thread.v2/0",\
            "organizer":"Doe, Jane","is_online":true},\
            {"id":"E2","subject":"Room lunch","start":null,"end":null,\
            "join_url":null,"organizer":null,"is_online":false}]}
            """
        return try! decodeOrThrow(MeetingsResponse.self, from: Data(json.utf8))
    }

    nonisolated static func parseJSON(
        kind: String, thread: String? = nil, meeting: String? = nil, url: String
    ) -> JoinParseResponse {
        var target = #"{"kind":"\#(kind)","url":"\#(url)""#
        target += thread.map { #","thread_id":"\#($0)""# } ?? #","thread_id":null"#
        target += meeting.map { #","meeting_id":"\#($0)""# } ?? #","meeting_id":null"#
        target += "}"
        let json = #"{"ok":true,"target":\#(target)}"#
        return try! decodeOrThrow(JoinParseResponse.self, from: Data(json.utf8))
    }

    // MARK: - Wire decode

    func testDecodeMeetings() {
        let response = Self.meetingsJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.meetings.count, 2)
        let first = response.meetings[0]
        XCTAssertEqual(first.id, "E1")
        XCTAssertEqual(first.subject, "Standup")
        XCTAssertEqual(first.start, "2024-05-06T09:00:00.0000000")
        XCTAssertEqual(first.organizer, "Doe, Jane")
        XCTAssertTrue(first.isOnline)
        XCTAssertTrue(first.isJoinable)
        // Routes through ChatMessage rules (local + locale clock; exact
        // pins live in FidTimeTests with explicit zone/locale).
        XCTAssertEqual(first.displayStart, ChatMessage.shortTime("2024-05-06T09:00:00.0000000"))
        let second = response.meetings[1]
        XCTAssertFalse(second.isOnline)
        XCTAssertFalse(second.isJoinable)
        XCTAssertNil(second.displayStart)
    }

    func testDecodeJoinTargetKinds() {
        let thread = Self.parseJSON(
            kind: "thread", thread: "19:abc@thread.v2",
            url: "https://teams.microsoft.com/l/meetup-join/x").target
        XCTAssertTrue(thread.canJoinInApp)
        XCTAssertFalse(thread.canOpenExternally)
        XCTAssertEqual(thread.threadID, "19:abc@thread.v2")

        let live = Self.parseJSON(
            kind: "meeting-id", meeting: "9347123456789",
            url: "https://teams.live.com/meet/9347123456789").target
        XCTAssertFalse(live.canJoinInApp)
        XCTAssertTrue(live.canOpenExternally)

        let url = Self.parseJSON(kind: "url", url: "https://example.com/x").target
        XCTAssertFalse(url.canJoinInApp)
        XCTAssertTrue(url.canOpenExternally)

        let unknown = Self.parseJSON(kind: "unknown", url: "hello").target
        XCTAssertFalse(unknown.canJoinInApp)
        XCTAssertFalse(unknown.canOpenExternally)
        XCTAssertNil(unknown.threadID)
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"meetings","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(MeetingsResponse.self, from: Data(json.utf8)))
    }

    // MARK: - Lobby machine (mirrors Rust lobby_next)

    func testLobbyHappyPath() {
        var s = LobbyState.idle
        s = LobbyMachine.next(s, .start)
        XCTAssertEqual(s, .joining)
        s = LobbyMachine.next(s, .placed)
        XCTAssertEqual(s, .joining)
        s = LobbyMachine.next(s, .admit)
        XCTAssertEqual(s, .admitted)
    }

    func testLobbyWaitingRoomPath() {
        var s = LobbyMachine.next(.idle, .start)
        s = LobbyMachine.next(s, .lobbySignal)
        XCTAssertEqual(s, .lobby)
        s = LobbyMachine.next(s, .placed) // stale progress ignored
        XCTAssertEqual(s, .lobby)
        s = LobbyMachine.next(s, .admit)
        XCTAssertEqual(s, .admitted)
    }

    func testLobbyRejectAndRetry() {
        var s = LobbyMachine.next(.idle, .start)
        s = LobbyMachine.next(s, .lobbySignal)
        s = LobbyMachine.next(s, .reject)
        XCTAssertEqual(s, .failed)
        XCTAssertEqual(LobbyMachine.next(s, .admit), .failed)
        XCTAssertEqual(LobbyMachine.next(s, .start), .joining)
        XCTAssertEqual(LobbyMachine.next(s, .reset), .idle)
    }

    func testLobbyResetAndBanners() {
        for s in [LobbyState.idle, .joining, .lobby, .admitted, .failed] as [LobbyState] {
            XCTAssertEqual(LobbyMachine.next(s, .reset), .idle)
        }
        XCTAssertNil(LobbyMachine.banner(for: .idle))
        XCTAssertNil(LobbyMachine.banner(for: .admitted))
        XCTAssertEqual(LobbyMachine.banner(for: .joining), "Joining…")
        XCTAssertTrue(LobbyMachine.banner(for: .lobby)?.contains("lobby") ?? false)
        XCTAssertTrue(LobbyMachine.banner(for: .failed, detail: "declined")?.contains("declined") ?? false)
    }

    // MARK: - Join hints

    func testJoinHints() {
        XCTAssertEqual(
            MeetJoin.hint(for: nil), "Paste a Teams meeting link or thread id")
        XCTAssertNil(MeetJoin.hint(for: JoinTarget(kind: "thread", threadID: "t", url: "t")))
        // FIXPACK F12: personal Teams links are joined in this app, never a browser.
        XCTAssertTrue(
            MeetJoin.hint(for: JoinTarget(kind: "meeting-id", url: "u"))?.contains("in this app") ?? false)
        XCTAssertTrue(
            MeetJoin.hint(for: JoinTarget(kind: "url", url: "u"))?.contains("browser") ?? false)
        XCTAssertTrue(
            MeetJoin.hint(for: JoinTarget(kind: "unknown", url: "u"))?.contains("Not a Teams") ?? false)
        XCTAssertEqual(MeetJoin.buttonLabel(for: nil), "Join")
        XCTAssertEqual(
            MeetJoin.buttonLabel(for: JoinTarget(kind: "url", url: "u")), "Open")
    }

    // MARK: - ViewModel states

    func testLoadPopulatesAndCounts() async {
        let response = Self.meetingsJSON()
        let model = MeetingsViewModel(meetingsFetcher: { response })
        XCTAssertEqual(model.state, .loading)
        await model.load()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.meetings.count, 2)
        XCTAssertEqual(model.fetchedCount, 2)
    }

    func testLoadEmpty() async {
        let model = MeetingsViewModel(
            meetingsFetcher: { MeetingsResponse(ok: true, meetings: []) })
        await model.load()
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(model.fetchedCount, 0)
    }

    func testLoadError() async {
        let model = MeetingsViewModel(
            meetingsFetcher: { () -> MeetingsResponse in
                throw CoreCallError.failed("boom")
            })
        await model.load()
        XCTAssertEqual(model.state, .error("boom"))
    }

    // MARK: - Join routing

    func testSubmitThreadArmsPreJoin() async {
        let parsed = Self.parseJSON(
            kind: "thread", thread: "19:abc@thread.v2",
            url: "https://teams.microsoft.com/l/meetup-join/x")
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            opener: { _ in XCTFail("thread must not open externally") })
        model.joinText = "https://teams.microsoft.com/l/meetup-join/x"
        model.submitJoin()
        await waitFor { model.target != nil }
        XCTAssertTrue(model.canJoin)
        XCTAssertNil(model.joinHint)
        XCTAssertTrue(model.showPreJoin)
        XCTAssertEqual(model.pendingJoin?.threadID, "19:abc@thread.v2")
    }

    func testSubmitURLLinksOpensExternally() async {
        let parsed = Self.parseJSON(kind: "url", url: "https://example.com/x")
        let opened = Box<[URL]>([])
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            opener: { opened.value.append($0) })
        model.joinText = "https://example.com/x"
        model.submitJoin()
        await waitFor { model.target != nil }
        XCTAssertFalse(model.showPreJoin)
        XCTAssertEqual(opened.value, [URL(string: "https://example.com/x")!])
    }

    func testSubmitUnknownShowsHintAndNeverDials() async {
        let parsed = Self.parseJSON(kind: "unknown", url: "hello")
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            opener: { _ in XCTFail("unknown must never open") })
        model.joinText = "hello"
        model.submitJoin()
        await waitFor { model.target != nil }
        XCTAssertFalse(model.canJoin)
        XCTAssertFalse(model.showPreJoin)
        XCTAssertTrue(model.joinHint?.contains("Not a Teams") ?? false)
    }

    func testJoinMeetingUsesRowURL() async {
        let parsed = Self.parseJSON(
            kind: "thread", thread: "19:abc@thread.v2", url: "https://t/x")
        let model = MeetingsViewModel(parseFetcher: {
            XCTAssertTrue($0.contains("meetup-join"))
            return parsed
        })
        model.joinMeeting(Self.meetingsJSON().meetings[0])
        await waitFor { model.target != nil }
        XCTAssertEqual(model.pendingJoin?.threadID, "19:abc@thread.v2")
        // Rows without links are no-ops (no parse, no sheet).
        let quiet = MeetingsViewModel(parseFetcher: { _ in
            XCTFail("linkless row must not parse")
            return parsed
        })
        quiet.joinMeeting(Self.meetingsJSON().meetings[1])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(quiet.target)
        XCTAssertFalse(quiet.showPreJoin)
    }

    // MARK: - Confirm + lobby drive

    func testConfirmJoinAdmitted() async {
        let parsed = Self.parseJSON(
            kind: "thread", thread: "19:abc@thread.v2", url: "https://t/x")
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            joinRunner: { _ in CallResult(ok: true, accepted: true) },
            lobbyGraceSecs: 3600)
        model.joinText = "x"
        model.submitJoin()
        await waitFor { model.showPreJoin }
        model.confirmJoin(micOn: true, cameraOn: false)
        await waitFor { model.lobby == .admitted }
        XCTAssertEqual(model.joinCount, 1)
        XCTAssertFalse(model.showPreJoin)
        XCTAssertNil(model.lobbyBanner) // admitted shows no banner
        model.dismissLobby()
        XCTAssertEqual(model.lobby, .idle)
    }

    func testConfirmJoinRejectedFailsWithDetail() async {
        let parsed = Self.parseJSON(
            kind: "thread", thread: "19:abc@thread.v2", url: "https://t/x")
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            joinRunner: { _ in CallResult(ok: true, accepted: false, rejection: "declined") },
            lobbyGraceSecs: 3600)
        model.joinText = "x"
        model.submitJoin()
        await waitFor { model.showPreJoin }
        model.confirmJoin(micOn: true, cameraOn: true)
        await waitFor { model.lobby == .failed }
        XCTAssertTrue(model.lobbyBanner?.contains("declined") ?? false)
        model.dismissLobby()
        XCTAssertEqual(model.lobby, .idle)
        XCTAssertNil(model.lobbyBanner)
    }

    func testSlowRunnerParksInLobbyBeforeAdmit() async {
        let parsed = Self.parseJSON(
            kind: "thread", thread: "19:abc@thread.v2", url: "https://t/x")
        let gate = DispatchSemaphore(value: 0)
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            joinRunner: { _ in
                gate.wait()
                return CallResult(ok: true, accepted: true)
            },
            lobbyGraceSecs: 0.02)
        model.joinText = "x"
        model.submitJoin()
        await waitFor { model.showPreJoin }
        model.confirmJoin(micOn: true, cameraOn: true)
        await waitFor { model.lobby == .lobby }
        XCTAssertTrue(model.lobbyBanner?.contains("lobby") ?? false)
        gate.signal()
        await waitFor { model.lobby == .admitted }
        model.dismissLobby()
    }

    func testCancelPreJoinDialsNothing() async {
        let parsed = Self.parseJSON(
            kind: "thread", thread: "19:abc@thread.v2", url: "https://t/x")
        let model = MeetingsViewModel(
            parseFetcher: { _ in parsed },
            joinRunner: { _ in
                XCTFail("cancelled join must not run")
                return CallResult(ok: true)
            })
        model.joinText = "x"
        model.submitJoin()
        await waitFor { model.showPreJoin }
        model.cancelPreJoin()
        XCTAssertFalse(model.showPreJoin)
        XCTAssertNil(model.pendingJoin)
        XCTAssertEqual(model.lobby, .idle)
        XCTAssertEqual(model.joinCount, 0)
    }

    // MARK: - Pre-join toggles (no hardware)

    func testPreJoinDefaultsAndToggleOff() {
        let pre = PreJoinModel()
        XCTAssertTrue(pre.micOn)
        XCTAssertTrue(pre.cameraOn)
        XCTAssertEqual(pre.level, 0)
        XCTAssertFalse(pre.levelLive)
        XCTAssertFalse(pre.micDenied)
        // Toggle-off paths touch no hardware (camera never started).
        pre.cameraOn = false
        pre.micOn = false
        pre.stop() // safe without start
        XCTAssertFalse(pre.micOn)
        XCTAssertFalse(pre.cameraOn)
    }

    // MARK: - Diagnostics line

    func testMeetingsLine() {
        XCTAssertEqual(
            DiagnosticsFormat.meetingsLine(fetched: 3, joins: 1, lobby: "lobby"),
            "3 upcoming · 1 joins · lobby")
        XCTAssertEqual(
            DiagnosticsFormat.meetingsLine(fetched: 0, joins: 0, lobby: "idle"),
            "0 upcoming · 0 joins · idle")
    }

    // MARK: - Helpers

    /// Main-actor-confined mutable box for closure captures.
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Spin until `cond` holds (mock fetchers resolve in ms; 2s cap).
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
