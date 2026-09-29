// UnifiedPresenceTests.swift — unified presence (ids, wire parse, batch
// POST), the store's batch/poll/diffed apply, and the card's calendar
// fields (getSchedule parse, zones, shared files).
import Combine
import Foundation
import XCTest
@testable import OstMacCore

/// Records every request; replies from a closure.
private final class RecordingAuthFetcher: TeamsAuthFetcher, @unchecked Sendable {
    let lock = NSLock()
    var requests: [(method: String, url: URL, headers: [String: String], body: Data?)] = []
    var reply: @Sendable (Data?) -> AuthHTTPResponse = { _ in AuthHTTPResponse(status: 200, data: Data("[]".utf8)) }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> AuthHTTPResponse {
        lock.lock(); requests.append((method, url, headers, body)); lock.unlock()
        return reply(body)
    }
}

private let a = "11111111-aaaa-4aaa-8aaa-111111111111"
private let b = "22222222-bbbb-4bbb-8bbb-222222222222"
private let me = "33333333-cccc-4ccc-8ccc-333333333333"

private func entry(_ oid: String, _ availability: String, _ activity: String, extra: String = "") -> String {
    #"{"mri":"8:orgid:\#(oid)","presence":{"availability":"\#(availability)","activity":"\#(activity)"\#(extra)},"status":20000}"#
}

final class UnifiedPresenceTests: XCTestCase {
    // MARK: ids

    func testMriAndPeerIDs() {
        XCTAssertEqual(UnifiedPresence.mri(forUserID: a.uppercased()), "8:orgid:" + a)
        XCTAssertEqual(UnifiedPresence.mri(forUserID: "8:orgid:" + b), "8:orgid:" + b)
        XCTAssertNil(UnifiedPresence.mri(forUserID: "tom@example.com"), "UPNs need a directory hop")
        XCTAssertNil(UnifiedPresence.mri(forUserID: "demo-u-tom"))
        let oneOnOne = "19:\(me)_\(a)@unq.gbl.spaces"
        XCTAssertEqual(UnifiedPresence.peerUserID(chatID: oneOnOne, ownUserID: me.uppercased()), a)
        XCTAssertEqual(UnifiedPresence.peerUserID(chatID: "19:\(a)_\(me)@unq.gbl.spaces", ownUserID: me), a)
        XCTAssertNil(UnifiedPresence.peerUserID(chatID: "19:abc@thread.v2", ownUserID: me), "group chat")
        XCTAssertNil(UnifiedPresence.peerUserID(chatID: "19:\(a)_\(b)@unq.gbl.spaces", ownUserID: me), "not ours")
        XCTAssertNil(UnifiedPresence.peerUserID(chatID: oneOnOne, ownUserID: nil))
        XCTAssertNil(UnifiedPresence.peerUserID(chatID: "19:\(me)_28:bot@unq.gbl.spaces", ownUserID: me), "bot")
    }

    // MARK: parse

    func testParseReadsAvailabilityNoteAndOutOfOffice() {
        let json = "[" + [
            entry(a, "Busy", "InAMeeting", extra: #","note":{"message":"Heads&nbsp;down <b>today</b>","expiry":"9999-01-01T00:00:00Z"}"#),
            entry(b, "Away", "OutOfOffice", extra: #","calendarData":{"isOutOfOffice":true,"outOfOfficeNote":{"message":"Back Monday","expiry":"9999-01-01T00:00:00.000Z"}}"#),
            entry(me, "Available", "Available", extra: #","note":{"message":"old","expiry":"2001-01-01T00:00:00Z"}"#),
            #"{"mri":"8:orgid:44444444-dddd-4ddd-8ddd-444444444444","presence":{}}"#,
            #"{"mri":"28:bot","presence":{"availability":"Available"}}"#,
        ].joined(separator: ",") + "]"
        let map = UnifiedPresence.parse(Data(json.utf8), now: Date())
        XCTAssertEqual(map.count, 3, "no availability → skipped, never 'unknown'")
        XCTAssertEqual(map[a]?.label, "In a meeting")
        XCTAssertEqual(map[a]?.statusMessage, "Heads down today")
        XCTAssertEqual(map[b]?.outOfOffice, true)
        XCTAssertEqual(map[b]?.outOfOfficeNote, "Back Monday")
        XCTAssertNil(map[me]?.statusMessage, "expired note dropped")
        XCTAssertEqual(UnifiedPresence.parse(Data("{}".utf8)).count, 0)
    }

    // MARK: fetch

    func testFetchPostsOneBatchPerFiftyAndKeysByGivenID() async throws {
        let f = RecordingAuthFetcher()
        f.reply = { body in
            let mris = ((try? JSONSerialization.jsonObject(with: body ?? Data())) as? [[String: String]] ?? [])
                .compactMap { $0["mri"] }
            let out = mris.map { #"{"mri":"\#($0)","presence":{"availability":"Available","activity":"Available"}}"# }
            return AuthHTTPResponse(status: 200, data: Data(("[" + out.joined(separator: ",") + "]").utf8))
        }
        var ids = (0..<59).map { String(format: "%08d-0000-4000-8000-000000000000", $0) }
        ids.append(a.uppercased())
        ids.append("tom@example.com")
        let map = try await UnifiedPresence.fetch(ids: ids, token: { "tok" }, fetcher: f)
        XCTAssertEqual(f.requests.count, 2, "60 MRIs → 50 + 10")
        XCTAssertEqual(f.requests[0].method, "POST")
        XCTAssertEqual(f.requests[0].url.absoluteString, UnifiedPresence.endpoint)
        XCTAssertEqual(f.requests[0].headers["Authorization"], "Bearer tok")
        XCTAssertEqual(map.count, 60, "UPN omitted")
        XCTAssertEqual(map[a.uppercased()]?.availability, "Available", "keyed by the id as given")
    }

    func testFetchThrowsOnHTTPError() async {
        let f = RecordingAuthFetcher()
        f.reply = { _ in AuthHTTPResponse(status: 401, data: Data()) }
        do {
            _ = try await UnifiedPresence.fetch(ids: [a], token: { "t" }, fetcher: f)
            XCTFail("expected a throw")
        } catch {
            XCTAssertTrue(String(describing: error).contains("HTTP 401"))
        }
        let none = try? await UnifiedPresence.fetch(ids: ["x@y.z"], token: { XCTFail("no token without ids"); return "" },
                                                   fetcher: f)
        XCTAssertEqual(none?.count, 0)
    }

    // MARK: store

    @MainActor
    private func store(_ replies: @escaping @Sendable ([String]) -> [String: UserPresenceResponse],
                       calls: PresenceCallBox) -> PresenceStore {
        let s = PresenceStore(ownFetcher: { XCTFail("own goes through the batch"); throw CoreCallError.failed("x") },
                              setFetcher: { _ in throw CoreCallError.failed("no set") },
                              userFetcher: { _ in XCTFail("peers go through the batch"); throw CoreCallError.failed("x") },
                              resolveFetcher: { _ in XCTFail("no directory hop"); throw CoreCallError.failed("x") })
        s.batchFetcher = { ids in calls.add(ids); return replies(ids) }
        s.ownIDProvider = { me }
        return s
    }

    private static func resp(_ id: String, _ availability: String, note: String? = nil) -> UserPresenceResponse {
        UserPresenceResponse(ok: true, id: id, availability: availability, activity: availability, statusMessage: note)
    }

    @MainActor
    func testBatchPollCoversOwnWatchedAndOneOnOneChatsAndAppliesDiff() async {
        let calls = PresenceCallBox()
        let state = PresenceStateBox()
        let s = store({ ids in
            var out: [String: UserPresenceResponse] = [:]
            for id in ids { out[id] = Self.resp(id, state.value[id] ?? "Available") }
            return out
        }, calls: calls)
        let chat = "19:\(a)_\(me)@unq.gbl.spaces"
        s.chatIDsProvider = { [chat, "19:group@thread.v2"] }
        s.watch([b, b.uppercased()])
        XCTAssertEqual(s.watched, [b], "case-insensitive dedupe")

        var peerPublishes = 0
        var chatPublishes = 0
        let c1 = s.$peers.dropFirst().sink { _ in peerPublishes += 1 }
        let c2 = s.$chatPeers.dropFirst().sink { _ in chatPublishes += 1 }
        defer { c1.cancel(); c2.cancel() }

        await s.pollOnce()
        XCTAssertEqual(calls.count, 1, "one request for everyone")
        XCTAssertEqual(Set(calls.last ?? []), [me, b, a])
        XCTAssertEqual(s.own?.availability, "Available")
        XCTAssertEqual(s.availabilityForChat(chat), "Available", "1:1 dot from the chat id alone")
        XCTAssertEqual(peerPublishes, 1)
        XCTAssertEqual(chatPublishes, 1)

        await s.pollOnce() // nothing changed
        XCTAssertEqual(peerPublishes, 1, "unchanged poll publishes nothing")
        XCTAssertEqual(chatPublishes, 1)

        state.value[a] = "Busy"
        await s.pollOnce()
        XCTAssertEqual(s.availabilityForChat(chat), "Busy")
        XCTAssertEqual(peerPublishes, 2)
        XCTAssertEqual(chatPublishes, 2)
    }

    @MainActor
    func testRefreshPeersAndChatMriUseOneBatchWithoutDirectoryHop() async {
        let calls = PresenceCallBox()
        let s = store({ ids in
            Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.resp($0, "Busy", note: "In clinic")) })
        }, calls: calls)
        await s.refreshPeers(ids: [a, b])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(s.peers[a]?.statusMessage, "In clinic")
        await s.refreshChatPeerMri(chatID: "19:x@unq.gbl.spaces", mri: "8:orgid:" + b)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(s.availabilityForChat("19:x@unq.gbl.spaces"), "Busy")
        await s.refreshOwn()
        XCTAssertEqual(calls.last ?? [], [me])
        XCTAssertEqual(s.own?.statusMessage, "In clinic")
    }

    @MainActor
    func testBatchFailureKeepsStaleValues() async {
        let calls = PresenceCallBox()
        let fail = PresenceStateBox()
        let s = PresenceStore()
        s.ownIDProvider = { me }
        s.batchFetcher = { ids in
            calls.add(ids)
            if fail.value["x"] != nil { throw CoreCallError.failed("presence: HTTP 503") }
            return [a: Self.resp(a, "Busy")]
        }
        await s.refreshPeers(ids: [a])
        fail.value["x"] = "1"
        await s.refreshPeers(ids: [a])
        XCTAssertEqual(s.peers[a]?.availability, "Busy", "stale value kept")
        XCTAssertNotNil(s.error)
        s.clear()
        XCTAssertTrue(s.watched.isEmpty)
        XCTAssertTrue(s.chatPins.isEmpty)
    }

    @MainActor
    func testCardPresencePrefersUnifiedCacheWithNotes() {
        let presence = PresenceStore()
        presence.adoptPeer(UserPresenceResponse(ok: true, id: a, availability: "Away", activity: "OutOfOffice",
                                                statusMessage: "Travelling", outOfOffice: true,
                                                outOfOfficeNote: "Back Monday"))
        let cards = ContactStore()
        cards.presence = presence
        cards.adopt(ContactCard(profile: ContactProfile(id: a, displayName: "Megan Harper"),
                                presence: ContactPresence(availability: "PresenceUnknown", activity: "")),
                    for: ContactRef(name: "Megan Harper", userID: a, email: nil))
        let p = cards.presence(for: ContactRef(name: "Megan Harper", userID: a, email: nil))
        XCTAssertEqual(p?.availability, "Away")
        XCTAssertEqual(p?.statusMessage, "Travelling")
        XCTAssertEqual(p?.outOfOfficeNote, "Back Monday")
    }

    // MARK: calendar fields

    private let now = ISO8601DateFormatter().date(from: "2026-09-28T15:10:00Z")!

    func testScheduleBusyNowMergesBackToBackSlots() {
        let json = #"""
        {"value":[{"scheduleId":"x@example.com","availabilityView":"22",
         "scheduleItems":[
          {"status":"busy","start":{"dateTime":"2026-09-28T15:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-28T15:30:00.0000000","timeZone":"UTC"}},
          {"status":"tentative","start":{"dateTime":"2026-09-28T15:30:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-28T16:00:00.0000000","timeZone":"UTC"}},
          {"status":"busy","start":{"dateTime":"2026-09-28T18:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-28T19:00:00.0000000","timeZone":"UTC"}}],
         "workingHours":{"daysOfWeek":["monday"],"startTime":"08:30:00.0000000","endTime":"17:00:00.0000000",
          "timeZone":{"name":"GMT Standard Time"}}}]}
        """#
        let s = ContactExtrasReads.parseSchedule(Data(json.utf8), now: now)
        XCTAssertEqual(s?.state, .busy)
        XCTAssertEqual(s?.until, ISO8601DateFormatter().date(from: "2026-09-28T16:00:00Z"), "runs through the tentative slot")
        XCTAssertEqual(s?.timeZoneID, "Europe/London")
        XCTAssertEqual(s?.workStart, "08:30:00")
        XCTAssertEqual(s?.workEnd, "17:00:00")
    }

    func testScheduleFreeUntilNextSlotAndErrorsAreNil() {
        let free = #"{"value":[{"scheduleItems":[{"status":"free","start":{"dateTime":"2026-09-28T15:00:00"},"end":{"dateTime":"2026-09-28T16:00:00"}},{"status":"oof","start":{"dateTime":"2026-09-28T17:00:00"},"end":{"dateTime":"2026-09-29T17:00:00"}}],"workingHours":{"timeZone":{"name":"America/Chicago"}}}]}"#
        let s = ContactExtrasReads.parseSchedule(Data(free.utf8), now: now)
        XCTAssertEqual(s?.state, .free)
        XCTAssertEqual(s?.until, ISO8601DateFormatter().date(from: "2026-09-28T17:00:00Z"))
        XCTAssertEqual(s?.timeZoneID, "America/Chicago", "IANA names pass through")
        let denied = #"{"value":[{"scheduleId":"x@other.com","error":{"message":"not found","responseCode":"ErrorMailRecipientNotFound"}}]}"#
        XCTAssertNil(ContactExtrasReads.parseSchedule(Data(denied.utf8), now: now))
        XCTAssertNil(WindowsTimeZones.ianaID(for: "Customized Time Zone"))
        XCTAssertEqual(WindowsTimeZones.ianaID(for: "Pacific Standard Time"), "America/Los_Angeles")
        let body = String(decoding: ContactExtrasReads.scheduleBody(mail: "x@example.com", now: now), as: UTF8.self)
        XCTAssertTrue(body.contains(#""schedules":["x@example.com"]"#))
        XCTAssertTrue(body.contains("2026-09-28T15:09:00"))
    }

    func testFilesPathAndParse() {
        let path = ContactExtrasReads.filesPath(sharedBy: "o'neil@example.com")
        XCTAssertTrue(path.hasPrefix("/me/insights/shared?$filter="))
        XCTAssertTrue(path.contains("o%27%27neil@example.com"), path)
        XCTAssertFalse(path.contains(" "))
        let json = #"""
        {"value":[
         {"id":"f1","lastShared":{"sharedDateTime":"2026-09-20T10:00:00Z"},"resourceVisualization":{"title":"Plan.docx","type":"Word"},"resourceReference":{"webUrl":"https://example.sharepoint.com/plan","id":"r1"}},
         {"id":"f2","lastShared":{"sharedDateTime":"2026-09-25T10:00:00.123Z"},"resourceVisualization":{"title":"Numbers.xlsx","type":"Excel"},"resourceReference":{"webUrl":"javascript:alert(1)"}},
         {"id":"f3","resourceVisualization":{"title":"  "}}]}
        """#
        let files = ContactExtrasReads.parseFiles(Data(json.utf8))
        XCTAssertEqual(files.map(\.title), ["Numbers.xlsx", "Plan.docx"], "newest first, blank titles dropped")
        XCTAssertNil(files[0].webURL, "only https links open")
        XCTAssertEqual(files[1].webURL?.host, "example.sharepoint.com")
    }

    func testCardReadsScheduleForHoverAndFilesForFullCard() throws {
        let get = PathFetcher()
        get.routes = [
            ("/users/u1?", #"{"id":"u1","displayName":"Tom Becker","mail":"tom@example.com"}"#),
            ("/me/insights/shared", #"{"value":[{"id":"f1","resourceVisualization":{"title":"Plan.docx","type":"Word"}}]}"#),
        ]
        let posts = PresenceCallBox()
        let post: ContactExtrasReads.Poster = { url, headers, body in
            posts.add([url.path, headers["Prefer"] ?? ""])
            return ReadHTTPResponse(status: 200, data: Data(#"{"value":[{"scheduleItems":[],"workingHours":{"timeZone":{"name":"W. Europe Standard Time"}}}]}"#.utf8))
        }
        let hover = try ContactReads.card(key: "u1", org: false, token: "t", http: get, post: post, now: now)
        XCTAssertEqual(hover.schedule?.timeZoneID, "Europe/Berlin")
        XCTAssertEqual(hover.schedule?.state, .free)
        XCTAssertNil(hover.sharedFiles, "hover card skips files")
        XCTAssertEqual(posts.last, ["/v1.0/me/calendar/getSchedule", #"outlook.timezone="UTC""#])
        let full = try ContactReads.card(key: "u1", org: true, token: "t", http: get, post: post, now: now)
        XCTAssertEqual(full.sharedFiles?.map(\.title), ["Plan.docx"])
    }
}

/// Thread-safe call recorder.
final class PresenceCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ ids: [String]) { lock.lock(); calls.append(ids); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var last: [String]? { lock.lock(); defer { lock.unlock() }; return calls.last }
}

final class PresenceStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [String: String] = [:]
    var value: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Graph GET by path prefix (200s only; everything else 404).
private final class PathFetcher: ReadFetcher, @unchecked Sendable {
    var routes: [(String, String)] = []
    func get(url: URL, headers: [String: String]) throws -> ReadHTTPResponse {
        let path = String(url.absoluteString.dropFirst(CoreReads.graphBase.count))
        guard let hit = routes.first(where: { path.hasPrefix($0.0) }) else {
            return ReadHTTPResponse(status: 404, data: Data(#"{"error":{}}"#.utf8))
        }
        return ReadHTTPResponse(status: 200, data: Data(hit.1.utf8))
    }
}
