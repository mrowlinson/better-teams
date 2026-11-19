// EchoFixBannerTests.swift — ECHO-FIX: banner cells (importance level
// + trimmed subject) derive from the decoded message.
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class EchoFixBannerTests: XCTestCase {
    private func message(importance: String? = nil, subject: String? = nil) -> ChatMessage {
        ChatMessage(id: "1", sender: "Ann", timestamp: "2026-11-19T18:28:32Z",
                    content: "hi", importance: importance, subject: subject)
    }

    func testImportantWithSubject() {
        let (level, subject) = MessageRowView.bannerCells(
            for: message(importance: "high", subject: "Weekly sync"))
        XCTAssertEqual(level, .important)
        XCTAssertEqual(subject, "Weekly sync")
    }

    func testUrgent() {
        let (level, subject) = MessageRowView.bannerCells(for: message(importance: "urgent"))
        XCTAssertEqual(level, .urgent)
        XCTAssertEqual(subject, "")
    }

    func testNormalRendersNothing() {
        let (level, subject) = MessageRowView.bannerCells(for: message())
        XCTAssertEqual(level, .normal)
        XCTAssertEqual(subject, "")
        let (blankLevel, blankSubject) = MessageRowView.bannerCells(
            for: message(importance: "bogus", subject: "   "))
        XCTAssertEqual(blankLevel, .normal)
        XCTAssertEqual(blankSubject, "")
    }
}
