// GraphTwoTests.swift — §GRAPH2: reads that used to fail silently now say so.
// Catch Up tag read (403 fake: an error, never an empty "no tags") and the
// contact card's separately-failing sections (organization, files, about,
// schedule) with their Retry seam. Fakes only; no network.
import XCTest

@testable import OstMacCore

private final class GraphTwoFetcher: ReadFetcher, @unchecked Sendable {
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

private final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }

final class GraphTwoTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "graph2-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    // MARK: G2 / G5 — Catch Up tags

    func testTagReadFailureIsAnErrorNotAnEmptySet() {
        let d = defaults()
        // The 403 fake: the CSA read fails. Message carries no URL or code.
        let result = CatchUpTags.load(userID: "u1", defaults: d) {
            throw CoreCallError.failed("tags: HTTP 403 for https://teams.example/api/csa/x: {secret:1}")
        }
        guard case .failure(let f) = result else { return XCTFail("a 403 must not read as no tags: \(result)") }
        XCTAssertEqual(f.message, "Teams didn\u{2019}t allow reading your tags.")
        XCTAssertFalse(f.message.contains("403") || f.message.contains("teams.example") || f.message.contains("secret"))
        XCTAssertNil(CatchUpTags.cached(userID: "u1", defaults: d), "a failure is never cached as a finding")
        // Other failure classes have their own text.
        XCTAssertEqual(CatchUpTags.failureMessage(for: CoreCallError.failed("Skype token expired. Run 'teams-cli login'.")),
                       "Sign in again to read your tags.")
        XCTAssertTrue(CatchUpTags.failureMessage(for: CoreCallError.failed("tag answer (unrecognised shape)")).contains("can\u{2019}t read"))
        XCTAssertEqual(CatchUpTags.failureMessage(for: CoreCallError.failed("boom")), "Couldn\u{2019}t read your tags from Teams.")
    }

    func testTagReadSuccessIsCachedAndAnEmptyAnswerIsARealNone() {
        let d = defaults()
        let calls = Box(0)
        let ok = CatchUpTags.load(userID: "u1", defaults: d) { calls.v += 1; return ["designers", "QA"] }
        XCTAssertEqual(try? ok.get(), ["designers", "qa"])
        // Cached: no second read.
        let again = CatchUpTags.load(userID: "u1", defaults: d) { calls.v += 1; return [] }
        XCTAssertEqual(try? again.get(), ["designers", "qa"])
        XCTAssertEqual(calls.v, 1)
        // A different user with an empty (successful) answer is success([]), distinct from a failure.
        let none = CatchUpTags.load(userID: "u2", defaults: d) { [] }
        XCTAssertEqual(try? none.get(), [])
    }

    @MainActor
    func testDigestStoreCarriesTheTagErrorAndItsRetry() {
        let store = CatchUpDigestStore(transport: CatchUpCannedTransport(), mode: { .onClick },
                                       conditions: { (false, .nominal) }, observeSystem: false,
                                       defaults: MemoryDefaults())
        XCTAssertNil(store.tagsError)
        let retried = Box(0)
        store.retryTags = { retried.v += 1 }
        store.setTagsError("Teams didn\u{2019}t allow reading your tags.")
        XCTAssertEqual(store.tagsError, "Teams didn\u{2019}t allow reading your tags.")
        store.retryTags?()
        XCTAssertEqual(retried.v, 1)
        store.setTagsError(nil)
        XCTAssertNil(store.tagsError)
    }

    // MARK: G2 / G4 — contact card sections

    private func fullCard(_ routes: [(String, Int, String)],
                          poster: ContactExtrasReads.Poster? = nil) throws -> ContactCard {
        let f = GraphTwoFetcher()
        f.routes = [("/users/u1?", 200, #"{"id":"u1","displayName":"Tom Becker","mail":"tom@example.com"}"#)] + routes
        return try ContactReads.card(key: "u1", org: true, token: "t", http: f, post: poster)
    }

    func testDirectReportsFailureIsShownNotEmpty() throws {
        let card = try fullCard([
            ("/users/u1/directReports", 403, #"{"error":{"code":"Forbidden"}}"#),
            ("/users/u1/manager", 404, "{}"),
        ])
        XCTAssertTrue(card.orgLoaded)
        XCTAssertTrue(card.reports.isEmpty)
        let why = try XCTUnwrap(card.failures[.organization], "a failed reports read must be surfaced")
        XCTAssertEqual(why, "The directory didn\u{2019}t allow this.")
        XCTAssertFalse(why.contains("403") || why.contains("graph"))
    }

    func testUnreadableDirectReportsAnswerIsAFailureToo() throws {
        let card = try fullCard([("/users/u1/directReports", 200, #"{"nope":1}"#), ("/users/u1/manager", 404, "{}")])
        XCTAssertEqual(card.failures[.organization], "Teams answered in a form this app can\u{2019}t read.")
    }

    func testManagerChainFailureIsShownButTopOfOrgIsNot() throws {
        // 404 = no manager = top of the org: not a failure.
        let top = try fullCard([("/users/u1/directReports", 200, #"{"value":[]}"#), ("/users/u1/manager", 404, "{}")])
        XCTAssertNil(top.failures[.organization], "control: a real end of chain has no failure")
        XCTAssertTrue(top.orgLoaded)
        // A 500 mid-chain is unknown, not "no manager".
        let broken = try fullCard([
            ("/users/u1/directReports", 200, #"{"value":[]}"#),
            ("/users/u1/manager", 200, #"{"id":"m1","displayName":"Megan Harper"}"#),
            ("/users/m1/manager", 500, "{}"),
        ])
        XCTAssertEqual(broken.managers.map(\.id), ["m1"], "the part that did load still shows")
        XCTAssertEqual(broken.failures[.organization], "Teams had a problem answering this.")
    }

    func testFilesAboutAndScheduleFailuresAreEachSurfaced() throws {
        let card = try fullCard([
            ("/users/u1/directReports", 200, #"{"value":[]}"#),
            ("/users/u1/manager", 404, "{}"),
            ("/me/insights/shared", 403, "{}"),
            ("/users/u1?$select=aboutMe", 403, "{}"),
        ], poster: { _, _, _ in ReadHTTPResponse(status: 403, data: Data("{}".utf8)) })
        XCTAssertNil(card.failures[.organization])
        XCTAssertNotNil(card.failures[.files])
        XCTAssertNotNil(card.failures[.about])
        XCTAssertEqual(card.failures[.schedule], "The directory didn\u{2019}t allow this.")
        XCTAssertNil(card.sharedFiles, "unknown, not an empty list")
        XCTAssertNil(card.schedule)
        // A transport failure reads as "couldn't reach", also surfaced.
        struct Down: Error {}
        let offline = try fullCard([
            ("/users/u1/directReports", 200, #"{"value":[]}"#), ("/users/u1/manager", 404, "{}"),
        ], poster: { _, _, _ in throw Down() })
        XCTAssertEqual(offline.failures[.schedule], "Couldn\u{2019}t reach Teams for this.")
    }

    func testUnreadableSharedFilesAnswerIsAFailureNotNoFiles() throws {
        let card = try fullCard([
            ("/users/u1/directReports", 200, #"{"value":[]}"#), ("/users/u1/manager", 404, "{}"),
            ("/me/insights/shared", 200, #"{"nope":1}"#),
        ])
        XCTAssertEqual(card.failures[.files], "Teams answered in a form this app can\u{2019}t read.")
        XCTAssertNil(card.sharedFiles)
    }

    func testHealthyCardHasNoFailures() throws {
        let card = try fullCard([
            ("/users/u1/directReports", 200, #"{"value":[{"id":"r1","displayName":"Adam Lee"}]}"#),
            ("/users/u1/manager", 404, "{}"),
            ("/me/insights/shared", 200, #"{"value":[]}"#),
            ("/users/u1?$select=aboutMe", 200, #"{"aboutMe":"Hello"}"#),
        ], poster: { _, _, _ in ReadHTTPResponse(status: 200, data: Data(#"{"value":[]}"#.utf8)) })
        XCTAssertTrue(card.failures.isEmpty, "\(card.failures)")
        XCTAssertEqual(card.reports.map(\.id), ["r1"])
    }

    // MARK: the card store's Retry

    @MainActor
    func testForcedReloadBypassesTheCacheAndClearsTheFailure() async {
        let state = Box(0)
        let loads = Box(0)
        let profile = ContactProfile(id: "u1", displayName: "Tom Becker")
        let store = ContactStore(loader: { _, _ in
            loads.v += 1
            var card = ContactCard(profile: profile, orgLoaded: true)
            if state.v == 0 { card.failures[.organization] = "The directory didn\u{2019}t allow this." }
            return card
        })
        let ref = ContactRef(name: "Tom Becker", userID: "u1", email: nil)
        store.load(ref, org: true)
        for _ in 0 ..< 200 where store.card(for: ref) == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(store.card(for: ref)?.failures[.organization])
        store.load(ref, org: true)
        XCTAssertEqual(loads.v, 1, "unforced load is served from the cache")
        state.v = 1
        store.load(ref, org: true, force: true)
        XCTAssertTrue(store.isRetrying(ref))
        for _ in 0 ..< 200 where store.isRetrying(ref) { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(loads.v, 2)
        XCTAssertTrue(store.card(for: ref)?.failures.isEmpty == true)
    }
}
