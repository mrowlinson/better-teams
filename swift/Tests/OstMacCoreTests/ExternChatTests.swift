// ExternChatTests.swift — EXTERNCHAT lane: outside accounts start at
// the directory search (userType through the FFI into TeamMember),
// badge via `isExternal`, and open 1:1 (group + external refuses).
// No FFI, no network: mock searchers + demo AppState.
import XCTest

@testable import OstMacCore

@MainActor
final class ExternChatTests: XCTestCase {
    private func internalPerson() -> TeamMember {
        TeamMember(
            id: "u1", displayName: "Ava Lindqvist", userId: "aad-1",
            email: "ava@x", userType: "Member")
    }

    private func guestPerson() -> TeamMember {
        TeamMember(
            id: "g9", displayName: "Gus Guest",
            email: "gus@partner.example", userType: "Guest")
    }

    private func federatedPerson() -> TeamMember {
        TeamMember(
            id: "oid-priya", displayName: "Priya Nair",
            userId: "8:orgid:oid-priya", email: "priya@partner.example",
            userType: "Federated")
    }

    // MARK: - isExternal

    func testIsExternalMarksOnlyNonMembers() {
        XCTAssertFalse(internalPerson().isExternal)
        XCTAssertFalse(TeamMember(id: "u", displayName: "No Type").isExternal)
        XCTAssertFalse(TeamMember(id: "u", displayName: "Blank", userType: "  ").isExternal)
        XCTAssertFalse(TeamMember(id: "u", displayName: "Lower", userType: "member").isExternal)
        XCTAssertTrue(guestPerson().isExternal)
        XCTAssertTrue(federatedPerson().isExternal)
        XCTAssertTrue(TeamMember(id: "s", displayName: "Skype", userType: "SkypeConsumer").isExternal)
    }

    // MARK: - wire (FFI `people` rows)

    func testPeopleSearchResponseDecodesUserType() throws {
        let data = """
            {"ok":true,"query":"priya","people":[
              {"id":"oid-priya","display_name":"Priya Nair",
               "user_id":"8:orgid:oid-priya","email":"priya@partner.example",
               "roles":[],"is_owner":false,"user_type":"Federated"},
              {"id":"g9","display_name":"Gus Guest","user_id":"g9",
               "email":null,"roles":[],"is_owner":false,"user_type":"Guest"}]}
            """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PeopleSearchResponse.self, from: data)
        XCTAssertEqual(resp.people.map(\.userType), ["Federated", "Guest"])
        XCTAssertTrue(resp.people.allSatisfy(\.isExternal))
    }

    func testPeopleSearchResponseToleratesMissingUserType() throws {
        let data = """
            {"ok":true,"people":[
              {"id":"u1","display_name":"Ava","user_id":"aad-1",
               "email":"ava@x","roles":[],"is_owner":false}]}
            """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(PeopleSearchResponse.self, from: data)
        XCTAssertNil(resp.people.first?.userType)
        XCTAssertFalse(resp.people.first?.isExternal ?? true)
    }

    // MARK: - ref (1:1 create carries the MRI)

    func testUserRefPassesFederatedMRIThrough() {
        XCTAssertEqual(PersonChat.userRef(for: federatedPerson()), "8:orgid:oid-priya")
    }

    // MARK: - store (markers survive search)

    func testSearchKeepsExternalMarkers() async {
        let people = [internalPerson(), federatedPerson()]
        let store = ContactsStore(
            peopleSearcher: { _, _ in PeopleSearchResponse(ok: true, query: "priya", people: people) },
            defaults: MemoryDefaults())
        await store.search(query: "priya")
        XCTAssertEqual(store.results.filter(\.isExternal).map(\.displayName), ["Priya Nair"])
    }

    // MARK: - openNewChat

    func testGroupWithExternalRefusesOneToOneOnly() async {
        defer { RichMediaCache.memoryOnly = false } // process-global (demo AppState sets it)
        let app = AppState(args: ["--demo"])
        let ok = await app.openNewChat(people: [internalPerson(), federatedPerson()], topic: nil)
        XCTAssertFalse(ok)
        XCTAssertEqual(app.newChatError, "External contacts can only be messaged 1:1.")
    }

    func testSingleExternalOpensOneToOneDemo() async {
        defer { RichMediaCache.memoryOnly = false } // process-global (demo AppState sets it)
        let app = AppState(args: ["--demo"])
        let person = federatedPerson()
        let ok = await app.openNewChat(people: [person], topic: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(app.openChatID, PersonChat.demoChatID(for: person))
    }

    func testDemoDirectoryIncludesExternalBadgeRow() {
        let people = DemoData.peopleSearchResponse(for: "priya").people
        let ext = try? XCTUnwrap(people.first { $0.displayName == "Priya Nair" })
        XCTAssertTrue(ext?.isExternal ?? false)
    }
}
