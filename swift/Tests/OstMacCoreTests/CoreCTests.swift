// CoreCTests.swift — core-c gaps: meeting organizer identity, week-load
// stale-drop, per-call mute + connect time, join by meeting ID, and
// create-chat-then-call target resolution. No network, no FFI mutes.
import XCTest

@testable import OstMacCore

private final class CoreCBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    var v: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

@MainActor
final class CoreCTests: XCTestCase {
    private func spinUntil(_ done: @escaping () -> Bool, timeout: TimeInterval = 10) async {
        // Waits on the condition; the ceiling only bounds a hang. A deliberately
        // tiny timeout (the 0.05 s control below = a fixed negative window that
        // proves a stale write never lands) stays as given.
        await TestWait.until(ceiling: timeout <= 1 ? timeout : max(timeout, TestWait.hangCeiling),
                             interval: 0.001) { done() }
    }

    // MARK: 1. Organizer identity

    func testMeetingItemDecodesOrganizerIdentityAndDefaultsFalse() throws {
        let json = #"""
        [{"id":"A","subject":"Mine","organizer":"Me","organizer_email":"me@x.io",
          "is_organizer":true,"is_online":true},
         {"id":"B","subject":"Old core","is_online":false}]
        """#
        let items = try JSONDecoder().decode([MeetingItem].self, from: Data(json.utf8))
        XCTAssertTrue(items[0].isOrganizer)
        XCTAssertEqual(items[0].organizerEmail, "me@x.io")
        XCTAssertFalse(items[1].isOrganizer)
        XCTAssertNil(items[1].organizerEmail)
    }

    func testReadCoreCalendarViewCarriesIsOrganizer() throws {
        XCTAssertTrue(CoreReads.calendarViewPath(now: 0, days: 1, limit: 5).hasSuffix(",isOrganizer"))
        let body = #"""
        {"value":[{"id":"A","subject":"S","isOrganizer":true,
          "organizer":{"emailAddress":{"name":"Me","address":"me@x.io"}}},
          {"id":"B","subject":"T","organizer":{"emailAddress":{"name":"Jane","address":" "}}}]}
        """#
        let items = try CoreReads.parseCalendarView(Data(body.utf8))
        XCTAssertTrue(items[0].isOrganizer)
        XCTAssertEqual(items[0].organizerEmail, "me@x.io")
        XCTAssertFalse(items[1].isOrganizer)
        XCTAssertNil(items[1].organizerEmail)
    }

    // MARK: 2. Week stale-drop

    func testSlowEarlierWeekLoadNeverOverwritesNewerWeek() async {
        let cal = Calendar(identifier: .gregorian)
        let weekA = cal.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        let aStart = Int64(weekA.timeIntervalSince1970)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let store = CalendarWeekStore(weekStart: weekA, calendar: cal, weekFetcher: { start in
            if start == aStart {
                entered.signal()
                release.wait()
                return CalWeekResponse(ok: true, weekStart: start, days: 7, meetings: [
                    MeetingItem(meetingId: "stale-A", subject: "A")])
            }
            return CalWeekResponse(ok: true, weekStart: start, days: 7, meetings: [
                MeetingItem(meetingId: "fresh-B", subject: "B")])
        })
        let slow = Task { await store.load() }
        await Task.detached { entered.wait() }.value
        store.nextWeek() // newer load (week B) while A is still in flight
        await spinUntil({ store.meetings.map(\.id) == ["fresh-B"] })
        XCTAssertEqual(store.meetings.map(\.id), ["fresh-B"])
        release.signal()
        await slow.value
        await spinUntil({ false }, timeout: 0.05)
        XCTAssertEqual(store.meetings.map(\.id), ["fresh-B"], "stale week A must be dropped")
        XCTAssertEqual(store.state, .loaded)
        XCTAssertTrue(CalendarWeekStore.isCurrent(generation: 2, latest: 2, start: 7, weekStart: 7))
        XCTAssertFalse(CalendarWeekStore.isCurrent(generation: 1, latest: 2, start: 7, weekStart: 7))
        XCTAssertFalse(CalendarWeekStore.isCurrent(generation: 2, latest: 2, start: 7, weekStart: 8))
    }

    // MARK: 3. Mute per call + connect time

    func testCallInfoDecodesConnectedAt() throws {
        let json = #"{"id":"c","dir":"out","peer":"p","peer_name":"","thread":"t","state":"connected","started_at":10,"connected_at":25}"#
        let c = try JSONDecoder().decode(CallInfo.self, from: Data(json.utf8))
        XCTAssertEqual(c.connectedAt, 25)
        XCTAssertEqual(c.connectedDate, Date(timeIntervalSince1970: 25))
        let ringing = #"{"id":"c","dir":"in","peer":"p","peer_name":"","thread":"","state":"ringing","started_at":10}"#
        XCTAssertNil(try JSONDecoder().decode(CallInfo.self, from: Data(ringing.utf8)).connectedAt)
    }

    func testLiveCallEndResetsMuteAndExposesConnectTime() async {
        let store = CallStore()
        let slot = CoreCBox<CallInfo?>(CallInfo(
            id: "c1", dir: "out", peer: "p", state: "connected", startedAt: 5, connectedAt: 9))
        store.statusFetcher = { slot.v }
        store.refresh()
        await spinUntil({ store.call != nil })
        XCTAssertEqual(store.connectedSince, Date(timeIntervalSince1970: 9))
        store.setMuted(true) // core FFI mute: global flag only, no hardware
        await spinUntil({ store.muted })
        XCTAssertTrue(store.muted)
        slot.v = CallInfo(id: "c1", dir: "out", peer: "p", state: "ended", startedAt: 5, connectedAt: 9)
        store.refresh()
        await spinUntil({ !store.muted })
        XCTAssertFalse(store.muted, "mute must not carry into the next call")
        _ = try? RustCore.callMute(muted: false)
    }

    func testDemoEndResetsMute() {
        let store = CallStore(demo: true)
        store.echo()
        XCTAssertNotNil(store.call?.connectedAt)
        store.setMuted(true)
        store.end()
        XCTAssertFalse(store.muted)
        // Between calls (pre-join) a toggle sticks for the next call.
        store.setMuted(true)
        store.echo()
        XCTAssertTrue(store.muted)
    }

    // MARK: 4. Join by meeting ID

    func testMeetingIDResolutionParseAndInputRules() throws {
        let found = #"{"ok":true,"found":true,"join_url":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0","subject":"S","passcode_required":true}"#
        XCTAssertEqual(try MeetingIDResolution.parse(Data(found.utf8)),
                       .found(joinURL: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0", subject: "S"))
        XCTAssertEqual(try MeetingIDResolution.parse(Data(#"{"ok":true,"found":false}"#.utf8)), .notFound)
        XCTAssertEqual(try MeetingIDResolution.parse(Data(#"{"ok":false,"error":"passcode","detail":"x"}"#.utf8)), .passcodeMismatch)
        XCTAssertThrowsError(try MeetingIDResolution.parse(Data(#"{"ok":false,"error":"meetid","detail":"403"}"#.utf8)))
        XCTAssertEqual(MeetJoin.meetingIDDigits("123 456 789 012"), "123456789012")
        XCTAssertNil(MeetJoin.meetingIDDigits("12345678"))
        XCTAssertNil(MeetJoin.meetingIDDigits("１２３４５６７８９"))
    }

    /// §GRAPH2: join-by-ID never opens a browser. Resolved -> in-app
    /// pre-join; not found, lookup failure and passcode mismatch -> a
    /// visible error; a "resolved" link that is not a thread -> error.
    func testJoinByMeetingIDRoutesInAppOrShowsAnErrorNeverBrowser() async {
        let opened = CoreCBox<[URL]>([])
        let answer = CoreCBox<MeetingIDResolution>(.found(
            joinURL: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0", subject: "S"))
        let failure = CoreCBox<Bool>(false)
        let vm = MeetingsViewModel(
            meetingsFetcher: { MeetingsResponse(ok: true, meetings: []) },
            opener: { opened.v.append($0) },
            lobbyGraceSecs: -1,
            meetingIDResolver: { _, _ in
                if failure.v { throw CoreCallError.failed("meetid: HTTP 403 for https://graph.example/x: secret-detail") }
                return answer.v
            })
        vm.joinByMeetingID("123 456 789 012", passcode: "aB3")
        await spinUntil({ vm.showPreJoin })
        XCTAssertEqual(vm.lastMeetingIDRoute, .inApp)
        XCTAssertEqual(vm.pendingJoin?.threadID, "19:meeting_X@thread.v2")
        XCTAssertNil(vm.meetingIDError)
        await spinUntil({ !vm.resolvingMeetingID })
        XCTAssertFalse(vm.resolvingMeetingID, "busy ends once the thread is routed to pre-join")
        XCTAssertTrue(opened.v.isEmpty)
        vm.cancelPreJoin()

        // Not found: an error, no browser, no pre-join.
        answer.v = .notFound
        vm.joinByMeetingID("123456789012", passcode: "aB3")
        await spinUntil({ vm.meetingIDError != nil })
        XCTAssertTrue(vm.meetingIDError?.contains("couldn't find") == true, vm.meetingIDError ?? "nil")
        XCTAssertNil(vm.lastMeetingIDRoute)
        XCTAssertFalse(vm.showPreJoin)
        XCTAssertTrue(opened.v.isEmpty, "join-by-ID must not open a browser: \(opened.v)")

        // Lookup failure: its own error; the raw failure text (URL, body) never shown.
        failure.v = true
        vm.joinByMeetingID("123456789012", passcode: "aB3")
        await spinUntil({ vm.meetingIDError?.contains("look up") == true })
        XCTAssertFalse(vm.meetingIDError?.contains("secret-detail") == true)
        XCTAssertFalse(vm.meetingIDError?.contains("graph.example") == true)
        XCTAssertTrue(opened.v.isEmpty)
        failure.v = false

        answer.v = .passcodeMismatch
        vm.joinByMeetingID("123456789012", passcode: "nope")
        await spinUntil({ vm.meetingIDError?.contains("passcode") == true })
        XCTAssertTrue(opened.v.isEmpty)

        // Resolved to a link with no thread in it: still no browser.
        answer.v = .found(joinURL: "https://teams.microsoft.com/meet/123456789012?p=aB3", subject: nil)
        vm.joinByMeetingID("123456789012", passcode: "aB3")
        await spinUntil({ !vm.resolvingMeetingID })
        // The lookup only stops being busy once the error is set, so the
        // sheet (which closes when busy ends without an error) stays open.
        XCTAssertEqual(vm.meetingIDError?.contains("found that meeting"), true, vm.meetingIDError ?? "nil")
        XCTAssertNil(vm.lastMeetingIDRoute)
        XCTAssertTrue(opened.v.isEmpty, "\(opened.v)")
        XCTAssertFalse(vm.showPreJoin)

        // Bad input is refused before the resolver.
        vm.joinByMeetingID("123", passcode: "x")
        XCTAssertNotNil(vm.meetingIDError)
        vm.joinByMeetingID("123456789012", passcode: "  ")
        XCTAssertNotNil(vm.meetingIDError)
        XCTAssertTrue(opened.v.isEmpty)
    }

    /// The paste-a-link path (not join-by-ID) still opens non-thread links,
    /// so the by-ID rule above is specific to that path.
    func testPastedNonThreadLinkStillOpensExternallyOutsideJoinByID() async {
        let opened = CoreCBox<[URL]>([])
        let vm = MeetingsViewModel(
            meetingsFetcher: { MeetingsResponse(ok: true, meetings: []) },
            opener: { opened.v.append($0) }, lobbyGraceSecs: -1)
        vm.joinText = "https://example.com/x"
        vm.submitJoin()
        await spinUntil({ !opened.v.isEmpty })
        XCTAssertEqual(opened.v.first?.absoluteString, "https://example.com/x")
    }

    // MARK: 5. Create-chat-then-call

    func testCallTargetResolverOneToOneGroupDemoAndEmpty() async throws {
        let ava = TeamMember(id: "m1", displayName: "Ava Stone", userId: "u-ava")
        let tom = TeamMember(id: "m2", displayName: "Tom Carr", email: "tom@x.io")
        let nobody = TeamMember(id: "m3", displayName: "No Ref")
        let seen = CoreCBox<[String]>([])
        let one = try await CallTargetResolver.resolve(
            people: [ava, nobody], demo: false,
            oneToOne: { seen.v.append("1:\($0)"); return ChatCreateResponse(ok: true, chat: ChatItem(chatId: "19:one", name: "")) },
            group: { seen.v.append("g:\($0.joined(separator: ","))"); return ChatCreateResponse(ok: true, chat: ChatItem(chatId: "19:grp", name: "", is_group: true)) })
        XCTAssertEqual(one, CallTarget(threadID: "19:one", name: "Ava Stone"))
        let grp = try await CallTargetResolver.resolve(
            people: [ava, tom], demo: false,
            oneToOne: { _ in XCTFail("group must not use 1:1"); throw CoreCallError.failed("x") },
            group: { seen.v.append("g:\($0.joined(separator: ","))"); return ChatCreateResponse(ok: true, chat: ChatItem(chatId: "19:grp", name: "", is_group: true)) })
        XCTAssertEqual(grp, CallTarget(threadID: "19:grp", name: "Ava and Tom"))
        XCTAssertEqual(seen.v, ["1:u-ava", "g:u-ava,tom@x.io"])
        let demo = try await CallTargetResolver.resolve(people: [ava, tom], demo: true)
        XCTAssertTrue(demo.threadID.hasPrefix("demo-group-"))
        do {
            _ = try await CallTargetResolver.resolve(people: [nobody], demo: false)
            XCTFail("no refs must throw")
        } catch {
            XCTAssertEqual(error as? CallTargetResolver.Failure, .noOne)
        }
        do {
            _ = try await CallTargetResolver.resolve(
                people: [ava], demo: false,
                oneToOne: { _ in throw CoreCallError.failed("403") })
            XCTFail("create failure must throw")
        } catch {
            guard case .create = error as? CallTargetResolver.Failure else { return XCTFail("\(error)") }
        }
    }
}
