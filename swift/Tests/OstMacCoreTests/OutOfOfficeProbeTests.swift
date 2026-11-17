// OutOfOfficeProbeTests.swift — opt-in live proof of the OOO read path
// (OOO-SET R0, gap C5). Read-only GETs on the signed-in user's own
// mailboxSettings. Prints status codes, granted scopes and FIELD KEYS
// only — never values (automaticReplies holds personal message text),
// tokens or URLs.
import Foundation
import XCTest
@testable import OstMacCore

final class OutOfOfficeProbeTests: XCTestCase {
    func testLiveMailboxSettingsReads() throws {
        guard ProcessInfo.processInfo.environment["OOO_PROBE"] == "1" else {
            throw XCTSkip("set OOO_PROBE=1 to run the live OOO read-only probe")
        }
        let ctx = try CoreReads.production()
        let token = try CoreReads.graphToken(
            profile: CoreLocal.activeProfileID(), code: "probe", ctx: ctx)
        let claims = GraphTokenClaims.decode(token)
        let scopes = (claims["scp"] as? String ?? "").split(separator: " ").sorted()
        print("PROBE scopes: \(scopes.joined(separator: " "))")
        let probes: [(String, String)] = [
            ("ooo", "/me/mailboxSettings"),
            ("tz", "/me/mailboxSettings/timeZone"),
        ]
        for (label, path) in probes {
            guard let url = URL(string: CoreReads.graphBase + path) else { continue }
            let r = try ctx.http.get(url: url, headers: ["Authorization": "Bearer \(token)"])
            var detail = "bytes=\(r.data.count)"
            if let obj = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] {
                if let err = obj["error"] as? [String: Any] {
                    detail = "error=\(err["code"] as? String ?? "?")"
                } else if let oof = obj["automaticRepliesSetting"] as? [String: Any] {
                    let keys = oof.keys.sorted()
                    detail = "automaticRepliesSetting=\(keys.joined(separator: ","))"
                } else {
                    let keys = obj.filter { !($0.value is NSNull) && !$0.key.hasPrefix("@") }.keys.sorted()
                    detail = "fields=\(keys.joined(separator: ","))"
                }
            }
            print("PROBE \(label) status=\(r.status) \(detail)")
        }
    }
}
