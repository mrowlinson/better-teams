// MessageImportanceTests.swift — COMPOSER-B: importance levels.
import XCTest

@testable import OstMacCore

@MainActor
final class MessageImportanceTests: XCTestCase {
    func testWireValues() {
        XCTAssertEqual(MessageImportance.normal.wireValue, "")
        XCTAssertEqual(MessageImportance.important.wireValue, "high")
        XCTAssertEqual(MessageImportance.urgent.wireValue, "urgent")
    }

    func testLabels() {
        XCTAssertEqual(MessageImportance.normal.label, "Normal")
        XCTAssertEqual(MessageImportance.important.label, "Important")
        XCTAssertEqual(MessageImportance.urgent.label, "Urgent")
    }

    func testParseTolerant() {
        XCTAssertEqual(MessageImportance.parse(""), .normal)
        XCTAssertEqual(MessageImportance.parse("normal"), .normal)
        XCTAssertEqual(MessageImportance.parse("bogus"), .normal)
        XCTAssertEqual(MessageImportance.parse("HIGH"), .important)
        XCTAssertEqual(MessageImportance.parse("important"), .important)
        XCTAssertEqual(MessageImportance.parse("urgent"), .urgent)
    }

    func testOutgoingSendDefaults() {
        let r = OutgoingSend(chatID: "c", text: "hi", clientMessageID: "m")
        XCTAssertEqual(r.importance, .normal)
        XCTAssertEqual(r.subject, "")
        XCTAssertTrue(r.mentions.isEmpty)
    }

    func testMentionRefJSON() {
        XCTAssertEqual(WireMentionRef.json(for: []), "[]")
        let refs = [WireMentionRef(token: "@channel", id: "0", display: "channel", kind: "channel")]
        let s = WireMentionRef.json(for: refs)
        XCTAssertTrue(s.contains("@channel"))
        XCTAssertTrue(s.contains("\"kind\""))
    }
}
