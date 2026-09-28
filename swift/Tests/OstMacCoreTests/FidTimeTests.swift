// FidTimeTests.swift — fid-time lane: D8 local-TZ render, D9 locale
// clock, D10 Yesterday/weekday rows. Exact pins with explicit zone +
// locale (never the runner's defaults).
import XCTest

@testable import OstMacCore

final class FidTimeTests: XCTestCase {
    nonisolated static var utc: TimeZone { TimeZone(identifier: "UTC")! }
    nonisolated static var newYork: TimeZone { TimeZone(identifier: "America/New_York")! }
    nonisolated static var auckland: TimeZone { TimeZone(identifier: "Pacific/Auckland")! }
    nonisolated static var us: Locale { Locale(identifier: "en_US") }
    nonisolated static var german: Locale { Locale(identifier: "de_DE") }

    nonisolated static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    nonisolated static func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Self.utc
        return c
    }

    /// ICU short-time separators evolve (U+202F today); pins assert the
    /// readable shape with spaces on both sides.
    nonisolated static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - D8: local-TZ render

    /// Fixed UTC fixture shifts under a non-UTC zone (EDT = UTC-4).
    func testShortTimeShiftsToLocalZone() {
        let now = Self.date("2026-09-22T15:00:00Z") // 11:00 EDT
        XCTAssertEqual(
            Self.norm(ChatMessage.shortTime(
                "2026-09-22T14:12:00Z", now: now,
                timeZone: Self.newYork, locale: Self.us)),
            "10:12 AM")
        XCTAssertEqual(
            Self.norm(ChatMessage.shortTime(
                "2026-09-22T14:12:00Z", now: now,
                timeZone: Self.utc, locale: Self.us)),
            "2:12 PM")
    }

    /// Day boundaries are local: 01:30Z Sep 22 is still Sep 21 in NY.
    func testDayKeyUsesLocalBoundary() {
        XCTAssertEqual(
            MessageRender.dayKey(
                "2026-09-22T01:30:00Z", timeZone: Self.newYork),
            "2026-09-21")
        XCTAssertEqual(
            MessageRender.dayKey(
                "2026-09-22T01:30:00Z", timeZone: Self.utc),
            "2026-09-22")
        // Far-east zone: 14:00Z Sep 22 is already Sep 23 in Auckland.
        XCTAssertEqual(
            MessageRender.dayKey(
                "2026-09-22T14:00:00Z", timeZone: Self.auckland),
            "2026-09-23")
    }

    /// Bubble day split follows the local key: the Sep-21-local stamp
    /// renders the older (day + clock) form on Sep 22.
    func testShortTimeOlderFormFollowsLocalDay() {
        let now = Self.date("2026-09-22T15:00:00Z")
        XCTAssertEqual(
            Self.norm(ChatMessage.shortTime(
                "2026-09-22T01:30:00Z", now: now,
                timeZone: Self.newYork, locale: Self.us)),
            "Sep 21, 9:30 PM")
    }

    /// 7-digit fractional stamps (core wire form) parse, not slice.
    func testShortTimeParsesWireFraction() {
        let now = Self.date("2026-09-22T15:00:00Z")
        XCTAssertEqual(
            Self.norm(ChatMessage.shortTime(
                "2026-09-22T14:12:06.9690000Z", now: now,
                timeZone: Self.utc, locale: Self.us)),
            "2:12 PM")
    }

    /// Garbage contract unchanged: "" -> "?", short -> passthrough.
    func testShortTimeGarbageUnchanged() {
        XCTAssertEqual(ChatMessage.shortTime(""), "?")
        XCTAssertEqual(ChatMessage.shortTime("abc"), "abc")
        XCTAssertEqual(MessageRender.dayKey(""), "")
        XCTAssertEqual(MessageRender.dayKey("not-a-date"), "not-a-date")
    }

    // MARK: - D9: locale clock

    /// US rows + bubbles use the 12h short style.
    func testUSLocaleClockIs12h() {
        let now = Self.date("2026-09-22T15:00:00Z")
        XCTAssertEqual(
            Self.norm(ChatMessage.shortTime(
                "2026-09-22T14:12:00Z", now: now,
                timeZone: Self.utc, locale: Self.us)),
            "2:12 PM")
        XCTAssertEqual(
            Self.norm(ChatListFormat.previewTime(
                "2026-09-22T10:05:00Z", now: now,
                calendar: Self.utcCalendar(), locale: Self.us)),
            "10:05 AM")
        XCTAssertEqual(
            Self.norm(CallRecord.displayTime(
                for: Self.date("2026-09-22T14:12:00Z"), now: now,
                timeZone: Self.utc, locale: Self.us)),
            "2:12 PM")
    }

    /// 24h locales keep the 24h clock (no hard-coded AM/PM).
    func test24hLocaleClock() {
        let now = Self.date("2026-09-22T15:00:00Z")
        XCTAssertEqual(
            ChatMessage.shortTime(
                "2026-09-22T14:12:00Z", now: now,
                timeZone: Self.utc, locale: Self.german),
            "14:12")
        XCTAssertEqual(
            ChatListFormat.previewTime(
                "2026-09-22T10:05:00Z", now: now,
                calendar: Self.utcCalendar(), locale: Self.german),
            "10:05")
    }

    // MARK: - D10: Yesterday + weekday rows

    /// Yesterday's row reads "Yesterday" (was the weekday).
    func testPreviewTimeYesterday() {
        let now = Self.date("2026-09-22T15:00:00Z") // a Tuesday
        XCTAssertEqual(
            ChatListFormat.previewTime(
                "2026-09-21T10:05:00Z", now: now,
                calendar: Self.utcCalendar()),
            "Yesterday")
    }

    /// 3 days ago still reads the weekday; older reads M/d.
    func testPreviewTimeWeekdayAndOlder() {
        let now = Self.date("2026-09-22T15:00:00Z") // a Tuesday
        XCTAssertEqual(
            ChatListFormat.previewTime(
                "2026-09-19T10:05:00Z", now: now,
                calendar: Self.utcCalendar()),
            "Sat")
        XCTAssertEqual(
            ChatListFormat.previewTime(
                "2026-08-01T10:05:00Z", now: now,
                calendar: Self.utcCalendar()),
            "8/1")
    }

    // MARK: - Activity time

    /// Activity rows share the call clock (locale + zone honored).
    func testActivityTimeFollowsCallClock() {
        let at = UInt64(Self.date("2026-09-22T14:12:00Z").timeIntervalSince1970)
        let item = ActivityItem(
            kind: .missedCall, chatID: "19:t@thread", chatName: "Solo",
            snippet: "Missed call", at: at)
        XCTAssertEqual(
            item.displayTime,
            CallRecord.displayTime(
                for: Date(timeIntervalSince1970: TimeInterval(at))))
    }

    /// Missed-call snippet keeps its "Missed call · <time>" shape.
    func testMissedCallSnippetShape() {
        let record = CallRecord(
            id: "m", direction: .missed, peerName: "Solo",
            startedAt: 1_700_000_000, endedAt: 1_700_000_020)
        XCTAssertTrue(record.detailLine.hasPrefix("Missed · "))
        XCTAssertTrue(record.detailLine.contains(":"))
    }
}
