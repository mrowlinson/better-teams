// TenantGateR0ProbeTests.swift — MEETFIX-B-RERUN4 R0 go/no-go (test-only).
// Confirms in the xctest env that the cached config HAS an access token
// whose `tid` claim decodes (RustCore.appIdentity -> get_access_token +
// identity_from_jwt, claims read ignores expiry). Prints booleans only:
// never ids, names, tokens or URLs.
import Foundation
import XCTest
@testable import OstMacCore

final class TenantGateR0ProbeTests: XCTestCase {
    func testR0AccessTokenTidPresent() throws {
        guard ProcessInfo.processInfo.environment["MEETFIX_R0"] == "1" else {
            throw XCTSkip("set MEETFIX_R0=1 to run the tenant-gate R0 probe")
        }
        let id = try RustCore.appIdentity(profile: nil)
        let present = !id.tenantId.isEmpty
        print("R0 tenant_present=\(present) upn_present=\(!id.upn.isEmpty)")
        XCTAssertTrue(present, "R0 FAIL: access token missing or tid undecodable in xctest env")
    }
}
