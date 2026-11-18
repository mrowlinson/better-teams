// MessageSearchQueryTests — SHORTCUTS-R2 (SRCH-02/04): operator + slash
// parsing and the client-side predicate (shared by server post-filter,
// local index, and the feed matcher).
import XCTest

@testable import OstMacCore

final class MessageSearchQueryTests: XCTestCase {
    // MARK: - Parse

    func testPlainTextPassesThrough() {
        let q = MessageSearchQuery.parse("ship it friday")
        XCTAssertEqual(q.text, "ship it friday")
        XCTAssertNil(q.slash)
        XCTAssertNil(q.from)
        XCTAssertNil(q.inScope)
        XCTAssertNil(q.date)
        XCTAssertFalse(q.hasFilters)
    }

    func testBlankParsesEmpty() {
        let q = MessageSearchQuery.parse("   ")
        XCTAssertEqual(q.text, "")
        XCTAssertFalse(q.hasFilters)
    }

    func testFromOperator() {
        let q = MessageSearchQuery.parse("ship from:ava")
        XCTAssertEqual(q.text, "ship")
        XCTAssertEqual(q.from, "ava")
        XCTAssertTrue(q.hasFilters)
    }

    func testKeysAreCaseInsensitive() {
        let q = MessageSearchQuery.parse("FROM:Ava IN:general DATE:2026-11-17")
        XCTAssertEqual(q.from, "ava")
        XCTAssertEqual(q.inScope, "general")
        XCTAssertEqual(q.date, "2026-11-17")
        XCTAssertEqual(q.text, "")
    }

    func testQuotedValuesSpanSpaces() {
        let q = MessageSearchQuery.parse("from:\"Ava Lindqvist\" ship")
        XCTAssertEqual(q.from, "ava lindqvist")
        XCTAssertEqual(q.text, "ship")
    }

    func testFirstOperatorWins() {
        let q = MessageSearchQuery.parse("from:ava from:tom")
        XCTAssertEqual(q.from, "ava")
        XCTAssertEqual(q.text, "from:tom")
    }

    func testUnknownOperatorsStayLiteral() {
        let q = MessageSearchQuery.parse("date;2026 foo:bar 9:12")
        XCTAssertEqual(q.text, "date;2026 foo:bar 9:12")
        XCTAssertNil(q.from)
        XCTAssertNil(q.inScope)
        XCTAssertNil(q.date)
    }

    func testEmptyValueStaysLiteral() {
        let q = MessageSearchQuery.parse("from: ship")
        XCTAssertEqual(q.text, "from: ship")
        XCTAssertNil(q.from)
    }

    // MARK: - Slash

    func testUnreadSlash() {
        let q = MessageSearchQuery.parse("/unread ship")
        XCTAssertEqual(q.slash, .unread)
        XCTAssertEqual(q.text, "ship")
    }

    func testSavedSlash() {
        let q = MessageSearchQuery.parse("/saved")
        XCTAssertEqual(q.slash, .saved)
        XCTAssertEqual(q.text, "")
    }

    func testUnknownSlashStaysText() {
        let q = MessageSearchQuery.parse("/later ship")
        XCTAssertNil(q.slash)
        XCTAssertEqual(q.text, "/later ship")
    }

    func testSlashOnlyAfterFirstTokenIsText() {
        let q = MessageSearchQuery.parse("ship /unread")
        XCTAssertNil(q.slash)
        XCTAssertEqual(q.text, "ship /unread")
    }

    // MARK: - Predicate

    private func hit(
        sender: String = "Ava Lindqvist", chatID: String = "19:chat1@thread.v2",
        timestamp: String = "2026-11-17T10:00:00Z"
    ) -> SearchHit {
        SearchHit(
            messageID: "m1", chatID: chatID, sender: sender,
            timestamp: timestamp, preview: "hello")
    }

    func testFromMatchesCaseInsensitively() {
        let q = MessageSearchQuery.parse("from:AVA")
        XCTAssertTrue(q.matches(hit()))
        XCTAssertFalse(q.matches(hit(sender: "Tom Becker")))
    }

    func testInMatchesIDsAndNames() {
        let q = MessageSearchQuery.parse("in:general")
        XCTAssertTrue(q.matches(hit(chatID: "chan-general")))
        XCTAssertTrue(q.matches(
            hit(chatID: "19:xyz"), chatName: { _ in "General" }))
        XCTAssertFalse(q.matches(hit()))
    }

    func testDateMatchesISOPrefix() {
        XCTAssertTrue(MessageSearchQuery.parse("date:2026-11-17").matches(hit()))
        XCTAssertTrue(MessageSearchQuery.parse("date:2026-11").matches(hit()))
        XCTAssertTrue(MessageSearchQuery.parse("date:2026").matches(hit()))
        XCTAssertFalse(MessageSearchQuery.parse("date:2026-11-18").matches(hit()))
    }

    func testUnreadNeedsTheHook() {
        let q = MessageSearchQuery.parse("/unread")
        XCTAssertFalse(q.matches(hit()))
        XCTAssertTrue(q.matches(hit(), isUnread: { _ in true }))
        XCTAssertFalse(q.matches(hit(), isUnread: { _ in false }))
    }

    func testSavedIsNotAFilter() {
        XCTAssertTrue(MessageSearchQuery.parse("/saved x").matches(hit()))
    }

    func testCombinedOperatorsAND() {
        let q = MessageSearchQuery.parse("from:ava date:2026-11-17")
        XCTAssertTrue(q.matches(hit()))
        XCTAssertFalse(q.matches(hit(sender: "Tom Becker")))
        XCTAssertFalse(q.matches(hit(timestamp: "2026-11-18T10:00:00Z")))
    }
}
