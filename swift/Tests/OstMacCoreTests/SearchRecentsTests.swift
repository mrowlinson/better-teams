// SearchRecentsTests.swift — gap-g6g7 lane: sticky palette search memory.
//
// SearchRecentsStore persists 5 recents + scope chip + last query in
// UserDefaults (throwaway suites; the real keys are never touched).
import XCTest

@testable import OstMacCore

@MainActor
final class SearchRecentsTests: XCTestCase {
    private var suites: [(UserDefaults, String)] = []

    func freshDefaults() -> UserDefaults {
        let name = "test-searchrecents-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        suites.append((d, name))
        return d
    }

    override func tearDown() {
        for (d, name) in suites {
            d.removePersistentDomain(forName: name)
        }
        suites = []
        super.tearDown()
    }

    func testRecordOrdersNewestFirst() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        store.record("ship")
        store.record("release notes")
        XCTAssertEqual(store.recents, ["release notes", "ship"])
    }

    func testRecordCapsAtFive() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        for q in ["one", "two", "three", "four", "five", "six"] {
            store.record(q)
        }
        XCTAssertEqual(store.recents, ["six", "five", "four", "three", "two"])
        XCTAssertEqual(store.recents.count, SearchRecentsStore.maxRecents)
    }

    func testRecordDedupesCaseInsensitivelyNewestWins() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        store.record("ship")
        store.record("release")
        store.record("SHIP")
        XCTAssertEqual(store.recents, ["SHIP", "release"])
    }

    func testRecordTrimsAndDropsBlanks() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        store.record("   ")
        store.record("  ship  ")
        XCTAssertEqual(store.recents, ["ship"])
    }

    func testRecordSticksLastQuery() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        store.record("ship it")
        XCTAssertEqual(store.lastQuery, "ship it")
    }

    func testClearRecentsKeepsScopeAndQuery() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        store.record("ship")
        store.noteScope("messages")
        store.clearRecents()
        XCTAssertTrue(store.recents.isEmpty)
        XCTAssertEqual(store.lastScope, "messages")
        XCTAssertEqual(store.lastQuery, "ship")
    }

    func testScopeRoundTripsAcrossInstances() {
        let d = freshDefaults()
        let first = SearchRecentsStore(defaults: d)
        first.noteScope("messages")
        let second = SearchRecentsStore(defaults: d)
        XCTAssertEqual(second.lastScope, "messages")
        XCTAssertEqual(second.recents, first.recents)
        XCTAssertEqual(second.lastQuery, first.lastQuery)
    }

    func testScopeRejectsUnknownValues() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        store.noteScope("messages")
        store.noteScope("bogus")
        XCTAssertEqual(store.lastScope, "messages")
    }

    func testRecentsPersistAcrossInstances() {
        let d = freshDefaults()
        let first = SearchRecentsStore(defaults: d)
        first.record("ship")
        first.record("release")
        let second = SearchRecentsStore(defaults: d)
        XCTAssertEqual(second.recents, ["release", "ship"])
        XCTAssertEqual(second.lastQuery, "release")
    }

    func testClearPersists() {
        let d = freshDefaults()
        let first = SearchRecentsStore(defaults: d)
        first.record("ship")
        first.clearRecents()
        let second = SearchRecentsStore(defaults: d)
        XCTAssertTrue(second.recents.isEmpty)
    }

    func testFreshDefaultsStartBlank() {
        let store = SearchRecentsStore(defaults: freshDefaults())
        XCTAssertTrue(store.recents.isEmpty)
        XCTAssertEqual(store.lastScope, "chats")
        XCTAssertEqual(store.lastQuery, "")
    }
}
