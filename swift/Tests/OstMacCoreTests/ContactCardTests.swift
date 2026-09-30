// ContactCardTests.swift — contact card reads (parse, presence denial,
// manager walk), the name directory, card-store dedupe, and the profile
// photo cache (disk pre-fill, ETag 304, 404 marker, dedupe, LIFO).
import AppKit
import XCTest
@testable import OstMacCore

/// Path-prefix routes (Graph paths after /v1.0); records every URL path.
private final class RouteFetcher: ReadFetcher, @unchecked Sendable {
    let lock = NSLock()
    var routes: [(String, Int, String)] = []
    private(set) var paths: [String] = []

    func get(url: URL, headers: [String: String]) throws -> ReadHTTPResponse {
        let path = String(url.absoluteString.dropFirst(CoreReads.graphBase.count))
        lock.lock(); paths.append(path); lock.unlock()
        let hit = routes.filter { path.hasPrefix($0.0) }.max { $0.0.count < $1.0.count }
        guard let hit else { return ReadHTTPResponse(status: 404, data: Data(#"{"error":{}}"#.utf8)) }
        return ReadHTTPResponse(status: hit.1, data: Data(hit.2.utf8))
    }
}

final class ContactCardTests: XCTestCase {

    // MARK: reads

    func testCardParsesProfilePresenceAndWalksManagers() throws {
        let f = RouteFetcher()
        f.routes = [
            ("/users/u1?", 200, #"{"id":"u1","displayName":"Tom Becker","jobTitle":"Engineer","department":"Eng","mail":"","userPrincipalName":"tom@example.com","businessPhones":["+1 555"],"city":"Berlin","country":"Germany"}"#),
            ("/users/u1/presence", 200, #"{"availability":"Busy","activity":"InAMeeting","statusMessage":{"message":{"content":"Heads&nbsp;down<br>until 3"},"expiryDateTime":{"dateTime":"9999-01-01T00:00:00.0000000"}},"outOfOfficeSettings":{"isOutOfOffice":true}}"#),
            ("/users/u1/manager", 200, #"{"id":"m1","displayName":"Megan Harper","jobTitle":"Manager"}"#),
            ("/users/m1/manager", 200, #"{"id":"m2","displayName":"Jordan Fox"}"#),
            ("/users/u1/directReports", 200, #"{"value":[{"id":"r2","displayName":"Zoe Park"},{"id":"r1","displayName":"Adam Lee"},{"id":"x","displayName":null}]}"#),
        ]
        // Presence rides the Teams presence service (GRAPHSWEEP), injected here.
        let note = ContactReads.parsePresence(Data(f.routes[1].2.utf8))
        var asked: [String] = []
        let card = try ContactReads.card(key: "u1", org: true, token: "t", http: f,
                                         presence: { asked.append($0); return note })
        XCTAssertEqual(asked, ["u1"], "presence asked for the resolved profile id")
        XCTAssertFalse(f.paths.contains { $0.hasSuffix("/presence") }, "no Graph presence GET")
        XCTAssertEqual(card.profile.email, "tom@example.com", "blank mail falls back to the UPN")
        XCTAssertEqual(card.profile.subtitle, "Engineer · Eng")
        XCTAssertEqual(card.profile.location, "Berlin, Germany")
        XCTAssertEqual(card.profile.workPhone, "+1 555")
        XCTAssertEqual(card.presence?.statusMessage, "Heads down until 3")
        XCTAssertEqual(card.presence?.outOfOffice, true)
        XCTAssertEqual(card.managers.map(\.id), ["m1", "m2"], "nearest first; m2's 404 ends the walk")
        XCTAssertEqual(card.reports.map(\.displayName), ["Adam Lee", "Zoe Park"], "sorted, nameless dropped")
        XCTAssertTrue(card.orgLoaded)
        XCTAssertTrue(f.paths[0].contains("$select=" + ContactReads.profileSelect))
    }

    func testCardNeverAsksGraphForPresenceAndSkipsOrgForHover() throws {
        let f = RouteFetcher()
        f.routes = [
            ("/users/u1?", 200, #"{"id":"u1","displayName":"Tom Becker"}"#),
        ]
        let first = try ContactReads.card(key: "u1", org: false, token: "t", http: f)
        XCTAssertNil(first.presence, "no presence source injected")
        XCTAssertFalse(first.orgLoaded)
        XCTAssertFalse(f.paths.contains { $0.hasSuffix("/presence") }, "Graph presence is never asked (403 on the Teams token)")
        XCTAssertFalse(f.paths.contains { $0.contains("manager") || $0.contains("directReports") })
    }

    func testExpiredStatusNoteIsDropped() {
        let json = #"{"availability":"Available","activity":"Available","statusMessage":{"message":{"content":"old"},"expiryDateTime":{"dateTime":"2020-01-01T00:00:00.0000000"}}}"#
        XCTAssertNil(ContactReads.parsePresence(Data(json.utf8))?.statusMessage)
    }

    func testRefEncodingAndMriKeys() {
        let ref = ContactRef(name: "Tom Becker", userID: "8:orgid:abc", email: "tom@example.com")
        XCTAssertEqual(ref.userID, "abc")
        XCTAssertEqual(ContactRef(encoded: ref.encoded), ref)
        XCTAssertEqual(ContactRef(encoded: "Ava Lindqvist")?.graphKey, nil)
        XCTAssertEqual(ContactReads.userPath("a/b#c"), "/users/a%2Fb%23c")
    }

    func testTokenClaimsDecodeLocally() {
        let payload = Data(#"{"oid":"x-1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(GraphTokenClaims.decode("h.\(payload).s")["oid"] as? String, "x-1")
        XCTAssertTrue(GraphTokenClaims.decode("garbage").isEmpty)
    }

    // MARK: directory + store

    @MainActor
    func testDirectoryDropsAmbiguousNamesAndResolvesUniqueHits() async {
        let dir = ContactDirectory(searcher: { name in
            name == "Ava Lindqvist"
                ? [TeamMember(id: "a", displayName: "Ava Lindqvist", userId: "a", email: nil),
                   TeamMember(id: "b", displayName: "Ava Lindqvist-Berg", userId: "b", email: nil)]
                : []
        })
        dir.learn(name: "Sam Park", userID: "s1", email: nil)
        dir.learn(name: "Sam Park", userID: "s2", email: nil)
        XCTAssertNil(dir.ref(named: "sam park"), "two ids for one name never resolve")
        let found = await dir.resolve(name: "Ava Lindqvist")
        XCTAssertEqual(found?.userID, "a", "exact unique match wins over prefix hits")
        let miss = await dir.resolve(name: "Nobody Here")
        XCTAssertNil(miss)
    }

    @MainActor
    func testStoreDedupesInFlightAndServesCacheWithinTTL() async throws {
        let calls = ContactLoadCounter()
        let store = ContactStore(directory: ContactDirectory()) { ref, org in
            calls.bump()
            return ContactCard(profile: ContactProfile(id: ref.userID ?? "?", displayName: ref.name), orgLoaded: org)
        }
        let ref = ContactRef(name: "Tom Becker", userID: "u1")
        store.load(ref)
        store.load(ref)
        try await waitUntil { store.card(for: ref) != nil }
        store.load(ref)
        XCTAssertEqual(calls.value, 1)
        store.load(ref, org: true)   // hover card cached, full card needs org
        try await waitUntil { store.card(for: ref)?.orgLoaded == true }
        XCTAssertEqual(calls.value, 2)
        // Name-only ref reaches the same card once the directory knows it.
        XCTAssertNotNil(store.card(for: ContactRef(name: "tom becker")))
    }

    @MainActor
    func testDemoCardHasAbstractOrg() {
        let card = ContactDemo.card(for: ContactRef(name: "Megan Harper"), org: true)
        XCTAssertEqual(card?.managers.map(\.displayName), [DemoData.ownerDisplayName])
        XCTAssertEqual(card?.reports.map(\.displayName), ["Ava Lindqvist", "Tom Becker"])
        XCTAssertNotNil(DemoPhotos.png(for: "demo-u-tom"))
        XCTAssertNil(DemoPhotos.png(for: "someone-else"))
    }

    func testTeamsParityFieldsProfileTabAndLinkedIn() throws {
        let f = RouteFetcher()
        f.routes = [
            ("/users/u1?", 200, #"{"id":"u1","displayName":"Tom Becker","mail":"tom@example.com","userPrincipalName":"tom@example.com","imAddresses":["","sip:tom@example.com"]}"#),
            ("/users/u1?$select=aboutMe", 200, #"{"aboutMe":"<p>Builds&nbsp;things</p>","birthday":"0001-01-01T08:00:00Z","hireDate":"2019-04-01T00:00:00Z","skills":["Swift"," "],"interests":[],"schools":null}"#),
        ]
        let card = try ContactReads.card(key: "u1", org: true, token: "t", http: f)
        XCTAssertTrue(ContactReads.profileSelect.contains("imAddresses"))
        XCTAssertEqual(card.profile.chatAddress, "sip:tom@example.com", "first non-blank chat address")
        XCTAssertEqual(ContactProfile(id: "x", userPrincipalName: "x@example.com").chatAddress, "x@example.com")
        let about = try XCTUnwrap(card.about)
        XCTAssertEqual(about.aboutMe, "Builds things")
        XCTAssertNil(about.birthday, "year 0001 = unset")
        XCTAssertNotNil(about.hireDate)
        XCTAssertEqual(about.skills, ["Swift"])
        XCTAssertFalse(about.isEmpty)
        XCTAssertTrue(ContactAbout().isEmpty)
        XCTAssertNil(card.linkedIn, "no persona-card token, no LinkedIn read")

        let unbound = ContactExtrasReads.parseLinkedIn(Data(#"{"bound":false,"bindUrl":"https://www.linkedin.com/oauth/bind","joinNowUrl":"https://www.linkedin.com/signup","persons":[],"resultTemplate":"x"}"#.utf8))
        XCTAssertEqual(unbound, ContactLinkedIn(bound: false, bindURL: URL(string: "https://www.linkedin.com/oauth/bind"),
                                                joinURL: URL(string: "https://www.linkedin.com/signup")))
        let bound = ContactExtrasReads.parseLinkedIn(Data(#"{"bound":true,"persons":[{"member":{"name":"x","linkedInProfileUrl":"https://www.linkedin.com/in/example"}}]}"#.utf8))
        XCTAssertEqual(bound?.profileURL?.absoluteString, "https://www.linkedin.com/in/example")
        let search = ContactLinkedIn.searchURL(name: "Tom Becker", company: "Example Ltd")?.absoluteString ?? ""
        XCTAssertTrue(search.hasPrefix("https://www.linkedin.com/search/results/people/?keywords=Tom%20Becker%20Example"), search)
        let url = ContactExtrasReads.linkedInURL(id: "u1", mail: "tom@example.com")?.absoluteString ?? ""
        XCTAssertTrue(url.contains("/api/v1/linkedin/profiles/full?AadObjectId=u1&Smtp=tom@example.com&PersonaType=User"), url)

        let demo = ContactDemo.card(for: ContactRef(name: "Megan Harper"), org: true)
        XCTAssertEqual(demo?.profile.chatAddress, "megan@example.com")
        XCTAssertEqual(demo?.about?.skills.isEmpty, false)
        XCTAssertNotNil(demo?.linkedIn)
        XCTAssertNil(ContactDemo.card(for: ContactRef(name: "Megan Harper"), org: false)?.about, "hover load skips tabs")
    }

    // MARK: photos

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static let png: Data = {
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }()

    @MainActor
    func testPhotoCachesToDiskAndPrefillsNextLaunch() async throws {
        let dir = tempDir()
        let log = FetchLog()
        let fetcher: ProfilePhotoStore.Fetcher = { key, etag in
            log.add(key, etag)
            return etag == "e1" ? PhotoFetchResult(status: 304) : PhotoFetchResult(status: 200, data: Self.png, etag: "e1")
        }
        let ref = ContactRef(name: "Tom Becker", userID: "u1")
        let a = ProfilePhotoStore(directory: ContactDirectory(), cacheDir: dir, fetcher: fetcher)
        XCTAssertNil(a.slot(for: ref).image)
        a.request(ref)
        a.request(ref)   // in flight: deduped
        try await waitUntil { a.slot(for: ref).image != nil }
        XCTAssertEqual(log.entries.count, 1)

        // Next launch: photo is there before any network (no initials flash).
        let b = ProfilePhotoStore(directory: ContactDirectory(), cacheDir: dir, fetcher: fetcher)
        XCTAssertNotNil(b.slot(for: ref).image)
        b.request(ref)   // fresh (24 h default max-age): no fetch
        XCTAssertEqual(log.entries.count, 1)

        // Stale: revalidates with the ETag; 304 keeps the photo.
        b.now = { Date().addingTimeInterval(2 * 24 * 3600) }
        b.request(ref)
        try await waitUntil { log.entries.count == 2 && b.fetchCount == 1 }
        try await waitUntil { b.slot(for: ref).image != nil }
        XCTAssertEqual(log.entries.last?.1, "e1")
    }

    @MainActor
    func testNoPhotoMarkerStopsRefetchUntilStale() async throws {
        let log = FetchLog()
        let store = ProfilePhotoStore(directory: ContactDirectory(), cacheDir: tempDir()) { key, etag in
            log.add(key, etag)
            return PhotoFetchResult(status: 404)
        }
        let ref = ContactRef(name: "Ava Lindqvist", userID: "u2")
        store.request(ref)
        try await waitUntil { log.entries.count == 1 && store.fetchCount == 1 }
        try await Task.yield()
        store.request(ref)
        XCTAssertEqual(store.fetchCount, 1, "404 marker is fresh for noneMaxAge")
        XCTAssertNil(store.slot(for: ref).image)
    }

    @MainActor
    func testQueueIsLIFOAndCapped() async throws {
        let log = FetchLog()
        let gate = DispatchSemaphore(value: 0)
        let store = ProfilePhotoStore(directory: ContactDirectory(), cacheDir: nil) { key, etag in
            log.add(key, etag)
            if key == "first" { gate.wait() }
            return PhotoFetchResult(status: 404)
        }
        store.maxConcurrent = 1
        store.request(ContactRef(name: "A", userID: "first"))
        store.request(ContactRef(name: "B", userID: "older"))
        store.request(ContactRef(name: "C", userID: "newer"))
        store.cancel(ContactRef(name: "B", userID: "older"))   // scrolled away
        XCTAssertEqual(store.fetchCount, 1, "cap of 1 in flight")
        gate.signal()
        try await waitUntil { log.entries.count == 2 }
        XCTAssertEqual(log.entries.map(\.0), ["first", "newer"], "latest first; cancelled row never fetched")
    }

    func testMaxAgeHeader() {
        XCTAssertEqual(GraphPhotoFetcher.parseMaxAge("private, max-age=3600"), 3600)
        XCTAssertNil(GraphPhotoFetcher.parseMaxAge("no-cache"))
    }

    // MARK: helpers

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath,
                           line: UInt = #line) async throws {
        // Waits on the condition itself (TestWait): under a saturated full
        // suite the photo/card work runs on the shared blocking executor
        // behind other suites' parked jobs. The 60 s ceiling only bounds a hang.
        let met = await TestWait.until(interval: 0.005) { condition() }
        if !met { XCTFail("condition not met", file: file, line: line) }
    }
}

private final class ContactLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String?)] = []
    var entries: [(String, String?)] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ key: String, _ etag: String?) { lock.lock(); items.append((key, etag)); lock.unlock() }
}
