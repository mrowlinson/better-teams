// FilePeopleSearchTests.swift — om-jb-filesearch lane: file + people search.
// Store follows the om-ja-search pattern (generation guard, blank clears,
// per-section errors); rows reuse SharedFile + TeamMember shapes.
import XCTest

@testable import OstMacCore

@MainActor
final class FilePeopleSearchTests: XCTestCase {
    // MARK: - Decode (row shapes reused)

    func testFileResponseDecodesSharedFiles() throws {
        let data = """
            {"ok":true,"query":"plan","files":[
              {"id":"f1","name":"plan.md","size":48211,
               "mime":"text/markdown","web_url":"https://x/plan",
               "is_folder":false},
              {"id":"d9","name":"Design","size":0,"is_folder":true}
            ]}
            """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(FileSearchResponse.self, from: data)
        XCTAssertEqual(resp.files.count, 2)
        XCTAssertEqual(resp.files[0].name, "plan.md")
        XCTAssertEqual(resp.files[0].sizeLabel, "48 KB")
        XCTAssertTrue(resp.files[1].isFolder)
    }

    func testPeopleResponseDecodesMembers() throws {
        let data = """
            {"ok":true,"query":"ava","people":[
              {"id":"u1","display_name":"Ava Lindqvist","user_id":"u1",
               "email":"ava@x","roles":[],"is_owner":false}
            ]}
            """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PeopleSearchResponse.self, from: data)
        XCTAssertEqual(resp.people.count, 1)
        XCTAssertEqual(resp.people[0].displayName, "Ava Lindqvist")
        XCTAssertEqual(resp.people[0].email, "ava@x")
    }

    func testCoreErrorThrows() {
        let data = """
            {"ok":false,"error":"people_search","detail":"boom"}
            """.data(using: .utf8)!
        XCTAssertThrowsError(
            try decodeOrThrow(PeopleSearchResponse.self, from: data))
    }

    // MARK: - Store

    func testBlankQueryClearsWithoutFetching() async {
        let calls = FindCallCounter()
        let store = FilePeopleSearchStore(
            fileSearcher: { _, _ in calls.increment(); return FileSearchResponse(ok: true, query: "", files: []) },
            peopleSearcher: { _, _ in calls.increment(); return PeopleSearchResponse(ok: true, query: "", people: []) })
        await store.search(query: "   ")
        XCTAssertEqual(calls.value, 0)
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertTrue(store.lastQuery.isEmpty)
        XCTAssertFalse(store.isSearching)
    }

    func testSearchLoadsBothSections() async {
        let store = FilePeopleSearchStore(
            fileSearcher: { q, _ in
                XCTAssertEqual(q, "plan")
                return FileSearchResponse(
                    ok: true, query: q,
                    files: [SharedFile(id: "f1", name: "plan.md")])
            },
            peopleSearcher: { q, _ in
                XCTAssertEqual(q, "plan")
                return PeopleSearchResponse(
                    ok: true, query: q,
                    people: [TeamMember(id: "u9", displayName: "Plana Ray")])
            })
        await store.search(query: "plan")
        XCTAssertEqual(store.files.map(\.id), ["f1"])
        XCTAssertEqual(store.people.map(\.id), ["u9"])
        XCTAssertEqual(store.lastQuery, "plan")
        XCTAssertNil(store.fileError)
        XCTAssertNil(store.peopleError)
        XCTAssertFalse(store.isSearching)
    }

    func testFileErrorKeepsPeopleSection() async {
        let store = FilePeopleSearchStore(
            fileSearcher: { _, _ in throw CoreCallError.failed("drive down") },
            peopleSearcher: { q, _ in
                PeopleSearchResponse(
                    ok: true, query: q,
                    people: [TeamMember(id: "u1", displayName: "Ava")])
            })
        await store.search(query: "a")
        XCTAssertEqual(store.fileError, "drive down")
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertEqual(store.people.map(\.id), ["u1"])
        XCTAssertNil(store.peopleError)
    }

    func testPeopleErrorKeepsFileSection() async {
        let store = FilePeopleSearchStore(
            fileSearcher: { q, _ in
                FileSearchResponse(
                    ok: true, query: q, files: [SharedFile(id: "f1", name: "a")])
            },
            peopleSearcher: { _, _ in throw CoreCallError.failed("directory down") })
        await store.search(query: "a")
        XCTAssertEqual(store.peopleError, "directory down")
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertEqual(store.files.map(\.id), ["f1"])
        XCTAssertNil(store.fileError)
    }

    func testRetryRerunsLastQuery() async {
        let calls = FindQueryLog()
        let store = FilePeopleSearchStore(
            fileSearcher: { q, _ in
                calls.append(q)
                return FileSearchResponse(ok: true, query: q, files: [])
            },
            peopleSearcher: { q, _ in PeopleSearchResponse(ok: true, query: q, people: []) })
        await store.search(query: "plan")
        store.retry()
        // Retry hops through a Task; poll briefly for the second call.
        for _ in 0 ..< 50 {
            if calls.values.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(calls.values, ["plan", "plan"])
    }

    func testClearDropsEverything() async {
        let store = FilePeopleSearchStore(
            fileSearcher: { q, _ in
                FileSearchResponse(
                    ok: true, query: q, files: [SharedFile(id: "f1", name: "a")])
            },
            peopleSearcher: { _, _ in throw CoreCallError.failed("x") })
        await store.search(query: "a")
        XCTAssertFalse(store.files.isEmpty)
        XCTAssertNotNil(store.peopleError)
        store.clear()
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertNil(store.fileError)
        XCTAssertNil(store.peopleError)
        XCTAssertTrue(store.lastQuery.isEmpty)
    }

    // MARK: - Demo fixtures (offline substring index)

    func testDemoFixturesFilter() {
        let files = DemoData.fileSearchResponse(for: "plan")
        XCTAssertFalse(files.files.isEmpty)
        XCTAssertTrue(files.files.allSatisfy { $0.name.lowercased().contains("plan") })
        let people = DemoData.peopleSearchResponse(for: "ava")
        XCTAssertEqual(people.people.map(\.displayName), ["Ava Lindqvist"])
        XCTAssertFalse(DemoData.fileSearchResponse(for: "").files.isEmpty)
        XCTAssertFalse(DemoData.peopleSearchResponse(for: "").people.isEmpty)
        XCTAssertTrue(DemoData.fileSearchResponse(for: "zzz-no-such-file").files.isEmpty)
        XCTAssertTrue(DemoData.peopleSearchResponse(for: "zzz-no-such-person").people.isEmpty)
    }

    // MARK: - Live FFI guards (no network: empty query rejected in core)

    func testLiveFileSearchEmptyQueryThrows() {
        XCTAssertThrowsError(try RustCore.fileSearch(query: "  "))
    }

    func testLivePeopleSearchEmptyQueryThrows() {
        XCTAssertThrowsError(try RustCore.peopleSearch(query: ""))
    }
}

// MARK: - Locked test doubles (Sendable call counters)

/// Lock-guarded int counter for `@Sendable` mock searchers.
private final class FindCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Lock-guarded query log for `@Sendable` mock searchers.
private final class FindQueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    func append(_ q: String) {
        lock.lock()
        defer { lock.unlock() }
        queries.append(q)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }
}
