// ContactCardLiveProbeTests.swift — opt-in live proof of the contact-card
// Graph reads (CONTACTCARD_LIVE=1). Read-only GETs on the signed-in
// user's own profile. Prints status codes and which fields came back,
// never values, tokens or URLs.
import Foundation
import XCTest
@testable import OstMacCore

final class ContactCardLiveProbeTests: XCTestCase {
    func testLiveOwnProfileReads() throws {
        guard ProcessInfo.processInfo.environment["CONTACTCARD_LIVE"] == "1" else {
            throw XCTSkip("set CONTACTCARD_LIVE=1 to run the live contact-card probe")
        }
        let ctx = try CoreReads.production()
        let token = try CoreReads.graphToken(
            profile: CoreLocal.activeProfileID(), code: "probe", ctx: ctx)
        let claims = GraphTokenClaims.decode(token)
        let scopes = (claims["scp"] as? String ?? "").split(separator: " ").sorted()
        print("PROBE scopes: \(scopes.joined(separator: " "))")
        guard let oid = claims["oid"] as? String else { return XCTFail("token has no oid claim") }
        let probes: [(String, String)] = [
            ("profile", "/users/\(oid)?$select=\(ContactReads.profileSelect)"),
            ("manager", "/users/\(oid)/manager?$select=id,displayName,jobTitle"),
            ("directReports", "/users/\(oid)/directReports?$select=id,displayName,jobTitle"),
            ("presence", "/users/\(oid)/presence"),
            ("photo", "/users/\(oid)/photos/240x240/$value"),
            ("mailboxSettings", "/users/\(oid)/mailboxSettings/timeZone"),
        ]
        for (label, path) in probes {
            guard let url = URL(string: CoreReads.graphBase + path) else { continue }
            let r = try ctx.http.get(url: url, headers: ["Authorization": "Bearer \(token)"])
            var detail = "bytes=\(r.data.count)"
            if label != "photo", let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] {
                if let value = obj["value"] as? [Any] {
                    detail = "count=\(value.count)"
                } else if let err = obj["error"] as? [String: Any] {
                    detail = "error=\(err["code"] as? String ?? "?")"
                } else {
                    let keys = obj.filter { !($0.value is NSNull) && !$0.key.hasPrefix("@") }.keys.sorted()
                    detail = "fields=\(keys.joined(separator: ","))"
                }
            }
            print("PROBE \(label) status=\(r.status) \(detail)")
        }
    }
}
