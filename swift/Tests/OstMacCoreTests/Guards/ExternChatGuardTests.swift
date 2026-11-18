// ExternChatGuardTests — EXTERNCHAT pins (never weaken/skip without
// owner OK quoted in the commit body):
//  1. directory hits keep their external marker end to end (store);
//  2. demo Priya stays external (judge/badge coverage).
import XCTest

@testable import OstMacCore

@MainActor
final class ExternChatGuardTests: XCTestCase {
    func testDirectorySearchPreservesExternalMarkers() async {
        let ext = TeamMember(
            id: "oid-priya", displayName: "Priya Nair",
            userId: "8:orgid:oid-priya", email: "priya@partner.example",
            userType: "Federated")
        let store = ContactsStore(
            peopleSearcher: { _, _ in PeopleSearchResponse(ok: true, query: "priya", people: [ext]) },
            defaults: MemoryDefaults())
        await store.search(query: "priya")
        XCTAssertEqual(store.results.count, 1)
        XCTAssertTrue(store.results.first?.isExternal ?? false)
        XCTAssertEqual(PersonChat.userRef(for: store.results.first!), "8:orgid:oid-priya")
    }

    func testDemoExternalRowKeepsBadgeAndMRIRef() {
        let rows = DemoData.peopleSearchResponse(for: "priya").people
        let ext = try? XCTUnwrap(rows.first { $0.displayName == "Priya Nair" })
        XCTAssertEqual(ext?.userType, "Federated")
        XCTAssertTrue(ext?.isExternal ?? false)
        XCTAssertTrue((ext?.userId ?? "").hasPrefix("8:"))
    }
}
