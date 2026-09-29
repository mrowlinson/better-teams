// GraphSweepTests.swift — own status and single presence reads ride the
// Teams presence service, never Graph (GRAPHSWEEP). Fake transport only.
import Foundation
import XCTest
@testable import OstMacCore

private final class SweepFetcher: TeamsAuthFetcher, @unchecked Sendable {
    struct Call { let method: String; let url: URL; let headers: [String: String]; let body: Data? }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var status = 200
    var reply = Data("[]".utf8)
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> AuthHTTPResponse {
        lock.lock(); _calls.append(Call(method: method, url: url, headers: headers, body: body)); lock.unlock()
        return AuthHTTPResponse(status: status, data: reply)
    }
}

final class GraphSweepTests: XCTestCase {
    private let oid = "11111111-aaaa-4aaa-8aaa-111111111111"
    private let token: UnifiedPresence.TokenSource = { "FIXTURE-PRESENCE" }

    private func json(_ d: Data?) -> [String: String] {
        (d.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: String]) ?? [:]
    }

    // MARK: set own status (was Graph setUserPreferredPresence)

    func testSetOwnPutsForceAvailabilityOnPresenceService() async throws {
        let f = SweepFetcher()
        for (status, availability, activity) in [
            ("available", "Available", "Available"), ("busy", "Busy", "Busy"),
            ("dnd", "DoNotDisturb", "DoNotDisturb"), ("brb", "BeRightBack", "BeRightBack"),
            ("away", "Away", "Away"), ("offline", "Offline", "OffWork"), ("  DND ", "DoNotDisturb", "DoNotDisturb"),
        ] {
            let r = try await UnifiedPresence.setOwn(status: status, token: token, fetcher: f)
            XCTAssertEqual(r, PresenceResponse(ok: true, availability: availability, activity: activity), status)
            let c = try XCTUnwrap(f.calls.last)
            XCTAssertEqual(c.method, "PUT")
            XCTAssertEqual(c.url.absoluteString, "https://presence.teams.microsoft.com/v1/me/forceavailability/")
            XCTAssertEqual(c.headers["Authorization"], "Bearer FIXTURE-PRESENCE")
            XCTAssertEqual(c.headers["Content-Type"], "application/json")
            XCTAssertEqual(json(c.body), ["availability": availability], status)
        }
        XCTAssertFalse(f.calls.contains { $0.url.host?.contains("graph.microsoft.com") == true })
    }

    func testSetOwnRejectsUnknownStatusBeforeNetwork() async {
        let f = SweepFetcher()
        for bad in ["", "online", "InACall"] {
            do {
                _ = try await UnifiedPresence.setOwn(status: bad, token: token, fetcher: f)
                XCTFail("accepted \(bad)")
            } catch CoreCallError.failed(let m) {
                XCTAssertTrue(m.hasPrefix("presence_set: Unknown status"), m)
            } catch { XCTFail("wrong error \(error)") }
        }
        XCTAssertTrue(f.calls.isEmpty)
    }

    func testSetOwnServiceRefusalThrows() async {
        let f = SweepFetcher()
        f.status = 403
        do {
            _ = try await UnifiedPresence.setOwn(status: "busy", token: token, fetcher: f)
            XCTFail("403 reported as applied")
        } catch CoreCallError.failed(let m) {
            XCTAssertEqual(m, "presence_set: HTTP 403")
        } catch { XCTFail("wrong error \(error)") }
    }

    // MARK: single reads (was Graph /me/presence, /users/{id}/presence)

    func testOneReadsGetPresenceForTheObjectID() async throws {
        let f = SweepFetcher()
        f.reply = Data(#"[{"mri":"8:orgid:\#(oid)","presence":{"availability":"Busy","activity":"InAMeeting"}}]"#.utf8)
        let r = try await UnifiedPresence.one(id: oid.uppercased(), token: token, fetcher: f)
        XCTAssertEqual(r.id, oid.uppercased(), "keyed by the id as given")
        XCTAssertEqual(r.availability, "Busy")
        XCTAssertEqual(r.activity, "InAMeeting")
        let c = try XCTUnwrap(f.calls.first)
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.url.absoluteString, UnifiedPresence.endpoint)
        XCTAssertEqual(f.calls.count, 1)
    }

    func testOneRefusesUPNsAndMissingAnswersInsteadOfGuessing() async {
        let f = SweepFetcher()
        do {
            _ = try await UnifiedPresence.one(id: "someone@example.com", token: token, fetcher: f)
            XCTFail("UPN accepted")
        } catch CoreCallError.failed(let m) {
            XCTAssertEqual(m, "presence: not an object id")
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertTrue(f.calls.isEmpty, "no network for an id the service can't key on")
        f.reply = Data("[]".utf8)
        do {
            _ = try await UnifiedPresence.one(id: oid, token: token, fetcher: f)
            XCTFail("empty answer reported as a status")
        } catch CoreCallError.failed(let m) {
            XCTAssertEqual(m, "presence: no presence returned")
        } catch { XCTFail("wrong error \(error)") }
        f.status = 403
        do {
            _ = try await UnifiedPresence.one(id: oid, token: token, fetcher: f)
            XCTFail("403 reported as a status")
        } catch CoreCallError.failed(let m) {
            XCTAssertEqual(m, "presence: HTTP 403")
        } catch { XCTFail("wrong error \(error)") }
    }

    func testOwnUsesOwnObjectIDAndCarriesNote() async throws {
        let f = SweepFetcher()
        f.reply = Data(#"[{"mri":"8:orgid:\#(oid)","presence":{"availability":"Away","activity":"Away","note":{"message":"Back soon"}}}]"#.utf8)
        let r = try await UnifiedPresence.own(ownID: oid, token: token, fetcher: f)
        XCTAssertEqual(r.availability, "Away")
        XCTAssertEqual(r.statusMessage, "Back soon")
        do {
            _ = try await UnifiedPresence.own(ownID: nil, token: token, fetcher: f)
            XCTFail("signed-out read reported a status")
        } catch CoreCallError.failed(let m) {
            XCTAssertEqual(m, "presence: not signed in")
        } catch { XCTFail("wrong error \(error)") }
    }
}
