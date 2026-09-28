// ContactsTests.swift — om-f2-contacts lane: directory search + speed dial.
import XCTest

@testable import OstMacCore

@MainActor
final class ContactsTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(
            suiteName: "test-contacts-\(UUID().uuidString)") ?? .standard
    }

    private nonisolated static func person(
        id: String, name: String = "Ava",
        userId: String? = nil, email: String? = nil
    ) -> TeamMember {
        TeamMember(
            id: id, displayName: name,
            userId: userId ?? id, email: email)
    }

    // MARK: - Search

    func testSearchReplacesRows() async {
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                XCTAssertEqual(q, "ava")
                return PeopleSearchResponse(
                    ok: true, query: q,
                    people: [Self.person(id: "u1", name: "Ava")])
            },
            defaults: freshSuite())
        await store.search(query: "ava")
        XCTAssertEqual(store.results.map(\.id), ["u1"])
        XCTAssertEqual(store.lastQuery, "ava")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isSearching)
    }

    func testBlankQueryClearsWithoutCoreCall() async {
        let calls = ContactCallCounter()
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                calls.increment()
                return PeopleSearchResponse(ok: true, query: q, people: [])
            },
            defaults: freshSuite())
        await store.search(query: "   ")
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertTrue(store.lastQuery.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isSearching)
    }

    func testStaleCompletionDropped() async {
        // Deterministic order (was two `async let`s with no start-order
        // guarantee, so "fast" could claim the older generation): "fast"
        // starts only after the searcher has entered "slow", and "slow"
        // completes only after "fast" has landed.
        let slowEntered = AsyncStream<Void>.makeStream()
        let releaseSlow = DispatchSemaphore(value: 0)
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                if q == "slow" {
                    slowEntered.continuation.yield()
                    releaseSlow.wait()
                }
                return PeopleSearchResponse(
                    ok: true, query: q,
                    people: [TeamMember(
                        id: q, displayName: q, userId: q)])
            },
            defaults: freshSuite())
        let slow = Task { await store.search(query: "slow") }
        var entered = slowEntered.stream.makeAsyncIterator()
        _ = await entered.next()
        await store.search(query: "fast")
        releaseSlow.signal()
        await slow.value
        XCTAssertEqual(store.results.map(\.id), ["fast"])
        XCTAssertEqual(store.lastQuery, "fast")
    }

    func testErrorSurfacesAndRetryReruns() async {
        let calls = ContactCallCounter()
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                let n = calls.increment()
                if n == 1 { throw CoreCallError.failed("directory down") }
                return PeopleSearchResponse(
                    ok: true, query: q,
                    people: [TeamMember(id: "u1", displayName: "Ava", userId: "u1")])
            },
            defaults: freshSuite())
        await store.search(query: "ava")
        XCTAssertEqual(store.error, "directory down")
        XCTAssertTrue(store.results.isEmpty)
        store.retry()
        for _ in 0 ..< 50 {
            if calls.value >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(store.results.map(\.id), ["u1"])
        XCTAssertNil(store.error)
    }

    func testRetryWithoutQueryIsNoop() async {
        let calls = ContactCallCounter()
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                calls.increment()
                return PeopleSearchResponse(ok: true, query: q, people: [])
            },
            defaults: freshSuite())
        store.retry()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(calls.value, 0)
    }

    func testClearDropsRowsButKeepsPins() async {
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                PeopleSearchResponse(
                    ok: true, query: q,
                    people: [Self.person(id: "u1")])
            },
            defaults: freshSuite())
        await store.search(query: "a")
        store.pin(Self.person(id: "u1"))
        store.clear()
        XCTAssertTrue(store.results.isEmpty)
        XCTAssertTrue(store.lastQuery.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.pinnedIDs, ["u1"])
    }

    func testAdoptSetsRows() {
        let store = ContactsStore(defaults: freshSuite())
        store.adopt([Self.person(id: "u1"), Self.person(id: "u2")])
        XCTAssertEqual(store.results.map(\.id), ["u1", "u2"])
        XCTAssertNil(store.error)
    }

    // MARK: - Speed dial

    func testPinPersistsAcrossRelaunch() {
        let suite = freshSuite()
        let first = ContactsStore(defaults: suite)
        first.pin(Self.person(id: "u1"))
        first.pin(Self.person(id: "u2"))
        XCTAssertEqual(first.pinnedIDs, ["u1", "u2"])
        let second = ContactsStore(defaults: suite)
        XCTAssertEqual(second.pinnedIDs, ["u1", "u2"])
        // Re-pin keeps the original pin time (no reorder, no dupe).
        second.pin(Self.person(id: "u1"))
        XCTAssertEqual(second.pinnedIDs, ["u1", "u2"])
    }

    func testUnpinRemovesWithoutTouchingDirectory() async {
        let suite = freshSuite()
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                PeopleSearchResponse(
                    ok: true, query: q,
                    people: [Self.person(id: "u1")])
            },
            defaults: suite)
        await store.search(query: "a")
        store.pin(Self.person(id: "u1"))
        XCTAssertTrue(store.isPinned(Self.person(id: "u1")))
        store.unpin(Self.person(id: "u1"))
        XCTAssertTrue(store.pinnedIDs.isEmpty)
        XCTAssertFalse(store.isPinned(Self.person(id: "u1")))
        // The directory row survives the unpin.
        XCTAssertEqual(store.results.map(\.id), ["u1"])
        // Unknown unpins are a no-op (no write).
        store.unpin(ref: "nope")
        XCTAssertTrue(
            ContactsStore(defaults: suite).pinnedIDs.isEmpty)
    }

    func testPinnedContactsResolveKnownAndDegradeUnknown() {
        let suite = freshSuite()
        let first = ContactsStore(defaults: suite)
        first.pin(Self.person(id: "u1", name: "Ava"))
        first.pin(TeamMember(
            id: "x", displayName: "No Ref", userId: "", email: "  "))
        // Ref-less hits can't pin (no stable ref).
        XCTAssertEqual(first.pinnedIDs, ["u1"])
        // Relaunch: details are session-only, so the pin degrades to
        // the raw ref (never blank) with the ref re-attached as id.
        let second = ContactsStore(defaults: suite)
        let pins = second.pinnedContacts()
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins[0].displayName, "u1")
        XCTAssertEqual(pins[0].userId, "u1")
        XCTAssertEqual(ContactsStore.pinID(for: pins[0]), "u1")
    }

    func testEmailPinDegradesToEmail() {
        let mail = TeamMember(
            id: "m1", displayName: "M", email: "m@example.com")
        let fallback = ContactsStore.fallbackPerson(
            for: ContactsStore.pinID(for: mail)!)
        XCTAssertEqual(fallback.email, "m@example.com")
        XCTAssertNil(fallback.userId)
        XCTAssertEqual(ContactsStore.pinID(for: fallback), "m@example.com")
    }

    // MARK: - Presence

    func testPresenceMergesByUserID() async {
        let presence = PresenceStore(userFetcher: { id in
            UserPresenceResponse(
                ok: true, id: id, availability: "Busy",
                activity: "InACall")
        })
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                PeopleSearchResponse(
                    ok: true, query: q, people: [
                        TeamMember(
                            id: "h1", displayName: "Hit",
                            userId: "u1"),
                        // Ref-less hits never fetch (dot stays unknown).
                        TeamMember(
                            id: "h2", displayName: "NoRef",
                            userId: "", email: "  "),
                    ])
            },
            defaults: freshSuite())
        store.presence = presence
        await store.search(query: "a")
        XCTAssertEqual(store.presenceIDs(), ["u1"])
        XCTAssertEqual(presence.peers["u1"]?.availability, "Busy")
        XCTAssertNil(presence.peers["h2"])
    }

    func testPresenceFailureKeepsRowsAndStaleDots() async {
        let presence = PresenceStore(userFetcher: { _ in
            throw CoreCallError.failed("presence down")
        })
        presence.adoptPeer(UserPresenceResponse(
            ok: true, id: "u1", availability: "Available",
            activity: "Available"))
        let store = ContactsStore(
            peopleSearcher: { q, _ in
                PeopleSearchResponse(
                    ok: true, query: q,
                    people: [Self.person(id: "u1")])
            },
            defaults: freshSuite())
        store.presence = presence
        await store.search(query: "a")
        // Rows land; the stale dot survives the failed refresh.
        XCTAssertEqual(store.results.map(\.id), ["u1"])
        XCTAssertEqual(presence.peers["u1"]?.availability, "Available")
        XCTAssertNotNil(presence.error)
    }

    func testPresenceIDsCapAtPageSize() {
        let store = ContactsStore(defaults: freshSuite())
        store.adopt((0 ..< 30).map { Self.person(id: "u\($0)") })
        XCTAssertEqual(
            store.presenceIDs().count,
            Int(FilePeopleSearchStore.pageSize))
    }

    func testRefreshPresenceWithoutStoreIsNoop() async {
        let store = ContactsStore(defaults: freshSuite())
        store.adopt([Self.person(id: "u1")])
        await store.refreshPresence() // must not trap
        XCTAssertEqual(store.presenceIDs(), ["u1"])
    }

    // MARK: - person11 reuse (no forked logic)

    func testPinIDReusesPersonChatUserRef() {
        let idHit = Self.person(id: "u1")
        XCTAssertEqual(
            ContactsStore.pinID(for: idHit),
            PersonChat.userRef(for: idHit))
        let mailHit = TeamMember(
            id: "m1", displayName: "M", email: "m@example.com")
        XCTAssertEqual(
            ContactsStore.pinID(for: mailHit), "m@example.com")
        let refLess = TeamMember(
            id: "x", displayName: "X", userId: " ", email: "")
        XCTAssertNil(ContactsStore.pinID(for: refLess))
        XCTAssertNil(PersonChat.userRef(for: refLess))
    }

    // MARK: - Demo fixtures

    func testDemoContactPresenceMatchesSearchIndex() {
        let people = DemoData.peopleSearchResponse(for: "").people
        let dots = DemoData.contactPresence()
        XCTAssertEqual(
            Set(dots.map(\.id)), Set(people.compactMap(\.userId)))
    }
}

/// Locked call counter (mock searchers run off-main).
private final class ContactCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Increment; returns the new count.
    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
