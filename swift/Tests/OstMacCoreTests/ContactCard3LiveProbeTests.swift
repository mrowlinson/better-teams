// ContactCard3LiveProbeTests.swift — opt-in live proof of the full
// card's Profile tab source (CARD3_LIVE=1, peer mail in CARD3_PEER).
// Read-only GETs: the Profile-tab projection and the card projection for
// the signed-in user and one peer, plus the persona card service's person
// record for the signed-in user. Prints status codes, key names and
// set/unset flags only, never values, tokens or URLs.
import Foundation
import XCTest
@testable import OstMacCore

final class ContactCard3LiveProbeTests: XCTestCase {
    @MainActor
    func testLiveProfileTabSource() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CARD3_LIVE"] == "1", let peer = env["CARD3_PEER"] else {
            throw XCTSkip("set CARD3_LIVE=1 and CARD3_PEER=<mail> to run the Profile-tab probe")
        }
        let ctx = try CoreReads.production()
        let profile = CoreLocal.activeProfileID()
        let graph = try CoreReads.graphToken(profile: profile, code: "probe", ctx: ctx)
        guard let oid = GraphTokenClaims.decode(graph)["oid"] as? String else { return XCTFail("no oid claim") }
        func get(_ url: String, _ token: String, _ extra: [String: String] = [:]) throws -> ReadHTTPResponse {
            var h = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
            for (k, v) in extra { h[k] = v }
            return try ctx.http.get(url: URL(string: url)!, headers: h)
        }
        func object(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }
        /// Raw keys with a value, and for dates whether they are the year-0001 "unset" sentinel.
        func shape(_ d: Data) -> String {
            object(d).filter { !($0.value is NSNull) && !$0.key.hasPrefix("@") }
                .filter { ($0.value as? [Any])?.isEmpty != true && ($0.value as? String)?.isEmpty != true }
                .map { k, v in
                    guard let s = v as? String, k == "birthday" || k == "hireDate" else { return k }
                    return k + (s.hasPrefix("0001") ? "=unset" : "=set")
                }
                .sorted().joined(separator: ",")
        }
        for (label, key) in [("self", oid), ("peer", peer)] {
            let about = try get(CoreReads.graphBase + ContactReads.userPath(key) + "?$select="
                                + ContactExtrasReads.aboutSelect, graph)
            let parsed = ContactExtrasReads.parseAbout(about.data)
            print("CARD3 \(label) profileTab status=\(about.status) raw=\(shape(about.data)) parsedEmpty=\(parsed?.isEmpty ?? true)")
            let card = try get(CoreReads.graphBase + ContactReads.userPath(key) + "?$select="
                               + ContactReads.profileSelect, graph)
            print("CARD3 \(label) card status=\(card.status) fields=\(shape(card.data))")
        }
        guard case .success(let t) = await TeamsAppService.token(profile: profile, scopes: ContactExtrasReads.lokiResource)
        else { return print("CARD3 loki token failed") }
        let me = try RustCore.appIdentity(profile: profile)
        var q = URLComponents(string: "https://nam.loki.delve.office.com/api/v2/person")!
        q.queryItems = [URLQueryItem(name: "aadObjectId", value: me.userObjectId), URLQueryItem(name: "smtp", value: me.upn),
                        URLQueryItem(name: "personaType", value: "User"), URLQueryItem(name: "ConvertGetPost", value: "true"),
                        URLQueryItem(name: "ExternalPageInstance", value: UUID().uuidString)]
        let r = try get(q.url!.absoluteString, t.token, ["X-ClientType": "Teams", "X-ClientFeature": "LivePersonaCard"])
        let person = object(r.data)["person"] as? [String: Any] ?? [:]
        for k in ["workDetails", "enhancedWorkDetails"] {
            let v = person[k]
            let inner = (v as? [String: Any]) ?? ((v as? [Any])?.first as? [String: Any]) ?? [:]
            print("CARD3 loki \(k) status=\(r.status) keys=\(inner.keys.sorted().joined(separator: ","))")
        }
    }
}
