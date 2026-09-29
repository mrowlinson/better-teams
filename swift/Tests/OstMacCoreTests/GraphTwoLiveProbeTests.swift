// GraphTwoLiveProbeTests.swift — §GRAPH2 live checks, OFF by default.
// Run only after the owner signs in (fresh tokens): GRAPH2_LIVE=1.
// Two READS: the Catch Up tag list (CSA) and one person's directReports.
// Prints counts, HTTP status class and part names only — never tokens,
// ids, names or URLs. Never refreshes tokens; skips when they are stale.
import XCTest

@testable import OstMacCore

final class GraphTwoLiveProbeTests: XCTestCase {
    private func statusClass(_ error: Error) -> String {
        let raw: String = if case CoreCallError.failed(let m) = error { m } else { String(describing: error) }
        guard let r = raw.range(of: #"HTTP [0-9]{3}"#, options: .regularExpression) else { return "no-http-status" }
        return String(raw[r])
    }

    func testLiveTagsAndDirectReports() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GRAPH2_LIVE"] == "1" else {
            throw XCTSkip("set GRAPH2_LIVE=1 after the owner signs in to run the tags + directReports reads")
        }
        let ctx = try CoreReads.production()
        let slots = ctx.store.load(profile: TomlConfig.normalize(CoreLocal.activeProfileID()))
        guard let g = slots.graphToken, !g.isExpired(now: ctx.now()),
              let aad = slots.accessToken, !aad.isExpired(now: ctx.now()),
              let sk = slots.skypeToken, !sk.isExpired(now: ctx.now())
        else { throw XCTSkip("stored tokens missing or stale; not refreshing from a probe") }

        // 1. Tags: one CSA GET (teams/users/me/teams/tagCards).
        do {
            let names = try RustCore.catchUpTags()
            print("GRAPH2 tags ok count=\(names.count)")
        } catch {
            print("GRAPH2 tags FAILED \(statusClass(error)) message=\"\(CatchUpTags.failureMessage(for: error))\"")
        }

        // 2. directReports (+ manager walk, files, about) for GRAPH2_USER, else yourself.
        let claims = GraphTokenClaims.decode(g.token)
        guard let key = env["GRAPH2_USER"] ?? (claims["oid"] as? String) else { return XCTFail("no user key") }
        let card = try ContactReads.card(for: ContactRef(name: "", userID: key, email: nil), org: true)
        let failed = card.failures.keys.map(\.rawValue).sorted().joined(separator: ",")
        print("GRAPH2 card reports=\(card.reports.count) managers=\(card.managers.count) failedParts=[\(failed)]")
    }
}
