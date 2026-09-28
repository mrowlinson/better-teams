// CannedResponsesTests.swift — e2-canned: templates policy + store.
import XCTest

@testable import OstMacCore

@MainActor
final class CannedResponsesTests: XCTestCase {
    // MARK: - helpers

    private static func suite(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: "test.canned.\(name)")!
    }

    private static func template(
        title: String = "Standup",
        body: String = "Standup moved to 10."
    ) -> CannedTemplate {
        CannedTemplate(title: title, body: body)
    }

    // MARK: - filter matrix

    func testFilterBlankReturnsAllInOrder() {
        let ts = [
            Self.template(title: "Standup", body: "moved to 10"),
            Self.template(title: "OOO", body: "out Friday"),
        ]
        XCTAssertEqual(CannedResponses.filtered(ts, query: "").map(\.title), ["Standup", "OOO"])
        XCTAssertEqual(CannedResponses.filtered(ts, query: "   ").map(\.title), ["Standup", "OOO"])
    }

    func testFilterMatchesTitleOrBodyCaseInsensitive() {
        let ts = [
            Self.template(title: "Standup", body: "moved to 10"),
            Self.template(title: "OOO", body: "out Friday"),
        ]
        XCTAssertEqual(CannedResponses.filtered(ts, query: "stand").map(\.title), ["Standup"])
        XCTAssertEqual(CannedResponses.filtered(ts, query: "FRIDAY").map(\.title), ["OOO"])
    }

    func testFilterNoMatchEmpty() {
        let ts = [Self.template()]
        XCTAssertTrue(CannedResponses.filtered(ts, query: "zzz-nope").isEmpty)
    }

    // MARK: - insert (APPEND decision: never clobbers the draft)

    func testInsertEmptyDraftIsBody() {
        XCTAssertEqual(CannedResponses.insert("Thanks!", into: ""), "Thanks!")
    }

    func testInsertNonEmptyDraftAppendsOneSpace() {
        XCTAssertEqual(
            CannedResponses.insert("Thanks!", into: "Hi team"),
            "Hi team Thanks!")
    }

    func testInsertTrailingSpaceDraftNoDouble() {
        XCTAssertEqual(
            CannedResponses.insert("Thanks!", into: "Hi team "),
            "Hi team Thanks!")
    }

    func testInsertBlankBodyUntouched() {
        XCTAssertEqual(CannedResponses.insert("  ", into: "Hi"), "Hi")
    }

    // MARK: - validation

    func testValidateRejectsBlankTitle() {
        XCTAssertNotNil(CannedResponses.validate(title: "  ", body: "ok"))
    }

    func testValidateRejectsBlankBody() {
        XCTAssertNotNil(CannedResponses.validate(title: "ok", body: "  "))
    }

    func testValidateAcceptsBoth() {
        XCTAssertNil(CannedResponses.validate(title: "t", body: "b"))
    }

    // MARK: - store CRUD + persistence

    func testAddRejectsBlankWithReason() {
        let store = CannedResponsesStore(defaults: Self.suite())
        XCTAssertNotNil(store.add(title: "", body: "b"))
        XCTAssertNotNil(store.add(title: "t", body: ""))
        XCTAssertTrue(store.templates.isEmpty)
    }

    func testAddUpdateDeleteRoundTrip() {
        let defaults = Self.suite()
        let store = CannedResponsesStore(defaults: defaults)
        XCTAssertNil(store.add(title: "Standup", body: "moved to 10"))
        XCTAssertEqual(store.templates.count, 1)
        let id = store.templates[0].id
        XCTAssertNil(store.update(id: id, title: "Standup!", body: "moved to 11"))
        XCTAssertEqual(store.templates[0].title, "Standup!")
        // Relaunch-equivalent: fresh store over the same suite reads back.
        let reread = CannedResponsesStore(defaults: defaults)
        XCTAssertEqual(reread.templates.count, 1)
        XCTAssertEqual(reread.templates[0].title, "Standup!")
        store.delete(id: id)
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertTrue(CannedResponsesStore(defaults: defaults).templates.isEmpty)
    }

    func testDeleteUnknownNoOp() {
        let store = CannedResponsesStore(defaults: Self.suite())
        store.delete(id: UUID())
        XCTAssertTrue(store.templates.isEmpty)
    }

    func testUpdateUnknownRejected() {
        let store = CannedResponsesStore(defaults: Self.suite())
        XCTAssertNotNil(store.update(id: UUID(), title: "t", body: "b"))
    }

    func testMoveReorders() {
        let store = CannedResponsesStore(defaults: Self.suite())
        store.add(title: "A", body: "a")
        store.add(title: "B", body: "b")
        store.add(title: "C", body: "c")
        store.move(from: 0, to: 1)
        XCTAssertEqual(store.templates.map(\.title), ["B", "A", "C"])
        store.move(from: 2, to: 0)
        XCTAssertEqual(store.templates.map(\.title), ["C", "B", "A"])
        store.move(from: 9, to: 0) // out of range = no-op
        XCTAssertEqual(store.templates.map(\.title), ["C", "B", "A"])
    }

    func testTolerantReadIgnoresGarbage() {
        let defaults = Self.suite()
        defaults.set("not-json-data", forKey: CannedResponsesStore.storageKey)
        XCTAssertTrue(CannedResponsesStore(defaults: defaults).templates.isEmpty)
    }
}
