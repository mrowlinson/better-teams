// PersonChatTests.swift — om-lt5-person11: person-pick opens 1:1.
// Pure `PersonChat` ref rules + `{ok,chat}` wire decode. No FFI.
import XCTest

@testable import OstMacCore

@MainActor
final class PersonChatTests: XCTestCase {
    // MARK: - userRef

    func testUserRefPrefersUserId() {
        let p = TeamMember(
            id: "u1", displayName: "Ava", userId: "aad-1",
            email: "ava@x")
        XCTAssertEqual(PersonChat.userRef(for: p), "aad-1")
    }

    func testUserRefFallsBackToEmail() {
        let p = TeamMember(
            id: "u1", displayName: "Ava", userId: nil,
            email: "ava@x")
        XCTAssertEqual(PersonChat.userRef(for: p), "ava@x")
    }

    func testUserRefBlankUserIdFallsBackToEmail() {
        let p = TeamMember(
            id: "u1", displayName: "Ava", userId: "  ",
            email: "ava@x")
        XCTAssertEqual(PersonChat.userRef(for: p), "ava@x")
    }

    func testUserRefNilWhenBothMissing() {
        let p = TeamMember(id: "u1", displayName: "Ava")
        XCTAssertNil(PersonChat.userRef(for: p))
        let blank = TeamMember(
            id: "u1", displayName: "Ava", userId: " ",
            email: "")
        XCTAssertNil(PersonChat.userRef(for: blank))
    }

    // MARK: - demo id

    func testDemoChatIDShape() {
        let p = TeamMember(
            id: "demo-u-ava", displayName: "Ava",
            userId: "demo-u-ava", email: "ava@example.com")
        XCTAssertEqual(
            PersonChat.demoChatID(for: p), "demo-1:1-demo-u-ava")
        XCTAssertTrue(
            DemoData.isDemoID(PersonChat.demoChatID(for: p)))
    }

    func testDemoChatIDFallsBackToEmail() {
        let p = TeamMember(
            id: "u9", displayName: "Zed", userId: nil,
            email: "zed@x")
        XCTAssertEqual(
            PersonChat.demoChatID(for: p), "demo-1:1-zed@x")
    }

    // MARK: - wire

    func testCreateResponseDecodesChat() throws {
        let data = """
            {"ok":true,"chat":{
              "id":"19:one@unq.v1","name":"Ava","is_group":false,
              "last_message_time":null,"last_message_sender":null,
              "last_message_preview":null}}
            """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(
            ChatCreateResponse.self, from: data)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.chat.chatId, "19:one@unq.v1")
        XCTAssertEqual(resp.chat.name, "Ava")
        XCTAssertFalse(resp.chat.is_group)
    }

    func testCoreErrorThrows() {
        let data = """
            {"ok":false,"error":"chat_create","detail":"boom"}
            """.data(using: .utf8)!
        XCTAssertThrowsError(
            try decodeOrThrow(ChatCreateResponse.self, from: data))
    }
}
