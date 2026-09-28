// TranscriptsFixTests.swift — transcripts-fix lane: displayName matrix.
import XCTest

@testable import OstMacCore

final class TranscriptsFixTests: XCTestCase {
    // MARK: - displayName end to end

    func testDisplayNameMatrix() {
        // Spec example first.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Title-20260924.vtt"),
            "Title · Sep 24, 2026")
        // Siblings render identically across exts.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Weekly Sync-20260924.mp4"),
            "Weekly Sync · Sep 24, 2026")
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Weekly Sync-20260924.vtt"),
            "Weekly Sync · Sep 24, 2026")
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Weekly Sync-20260924-transcript.docx"),
            "Weekly Sync · Sep 24, 2026")
        // Time suffix dropped.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Standup-20260924_101530.vtt"),
            "Standup · Sep 24, 2026")
        // No date -> bare title, ext stripped.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Q3 Review with Tom Becker.vtt"),
            "Q3 Review with Tom Becker")
        XCTAssertEqual(MeetingDisplayName.displayName(for: "noext"), "noext")
        // Server codes stripped.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Standup-20260924 [AB12-X9].vtt"),
            "Standup · Sep 24, 2026")
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Standup-20260924 (AB12-X9).mp4"),
            "Standup · Sep 24, 2026")
        // Human parens kept.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Q3 (final).vtt"),
            "Q3 (final)")
        // Invalid dates stay in the title.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Sync-20261345.vtt"),
            "Sync-20261345")
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Sync-20260230.vtt"),
            "Sync-20260230") // Feb 30 is not real
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Sync-20240229.vtt"),
            "Sync · Feb 29, 2024") // leap day is real
    }

    // MARK: - Calendar join

    func testCalendarJoinMatrix() {
        // Exact (case-insensitive) -> calendar casing wins.
        XCTAssertEqual(
            MeetingDisplayName.displayName(
                for: "weekly sync-20260924.vtt", calendarTitle: "Weekly Sync"),
            "Weekly Sync · Sep 24, 2026")
        // Contains -> calendar wins.
        XCTAssertEqual(
            MeetingDisplayName.displayName(
                for: "Weekly Sync with Ava-20260924.vtt", calendarTitle: "Weekly Sync"),
            "Weekly Sync · Sep 24, 2026")
        // Unrelated -> parsed title kept.
        XCTAssertEqual(
            MeetingDisplayName.displayName(
                for: "Random-20260924.vtt", calendarTitle: "Weekly Sync"),
            "Random · Sep 24, 2026")
        // Short calendar titles never join (avoid "Q3" hijacks).
        XCTAssertEqual(
            MeetingDisplayName.displayName(
                for: "Sprint Q3 Planning-20260924.vtt", calendarTitle: "Q3"),
            "Sprint Q3 Planning · Sep 24, 2026")
        // Join never drops the date part.
        XCTAssertEqual(
            MeetingDisplayName.displayName(for: "Sync-20260924.vtt", calendarTitle: ""),
            "Sync · Sep 24, 2026")
    }

    // MARK: - Row coverage (recordings + transcripts)

    func testRowDisplayNamesShareTransform() {
        let t = TranscriptItem(id: "t1", name: "Weekly Sync-20260924.vtt")
        let r = RecordingItem(id: "r1", name: "Weekly Sync-20260924.mp4")
        XCTAssertEqual(t.displayName, "Weekly Sync · Sep 24, 2026")
        XCTAssertEqual(r.displayName, "Weekly Sync · Sep 24, 2026")
        XCTAssertEqual(t.displayName, r.displayName) // siblings identical
        let d = TranscriptItem(id: "t2", name: "Q3 Review transcript.docx")
        XCTAssertEqual(d.displayName, "Q3 Review")
    }

    // MARK: - Steps

    func testStripExtensionMatrix() {
        XCTAssertEqual(MeetingDisplayName.stripExtension("a.vtt"), "a")
        XCTAssertEqual(MeetingDisplayName.stripExtension("a.vtt.txt"), "a.vtt")
        XCTAssertEqual(MeetingDisplayName.stripExtension("noext"), "noext")
        XCTAssertEqual(MeetingDisplayName.stripExtension("/tmp/x/a.mp4"), "a")
    }

    func testIsServerCodeMatrix() {
        XCTAssertTrue(MeetingDisplayName.isServerCode("AB12-X9"))
        XCTAssertTrue(MeetingDisplayName.isServerCode("ABCD"))
        XCTAssertFalse(MeetingDisplayName.isServerCode("abc")) // short + lower
        XCTAssertFalse(MeetingDisplayName.isServerCode("final")) // lower
        XCTAssertFalse(MeetingDisplayName.isServerCode("Q3")) // short
    }

    func testStripKindTokenMatrix() {
        XCTAssertEqual(MeetingDisplayName.stripKindToken("A-transcript"), "A")
        XCTAssertEqual(MeetingDisplayName.stripKindToken("A_transcript"), "A")
        XCTAssertEqual(MeetingDisplayName.stripKindToken("A transcript"), "A")
        XCTAssertEqual(MeetingDisplayName.stripKindToken("A-TRANSCRIPTION"), "A")
        XCTAssertEqual(MeetingDisplayName.stripKindToken("A-recording"), "A")
        XCTAssertEqual(MeetingDisplayName.stripKindToken("Transcript Weekly"), "Transcript Weekly")
    }

    func testSplitDateMatrix() {
        let (t1, d1) = MeetingDisplayName.splitDate("Title-20260924")
        XCTAssertEqual(t1, "Title")
        XCTAssertEqual(d1?.month, 9)
        XCTAssertEqual(d1?.day, 24)
        let (t2, d2) = MeetingDisplayName.splitDate("Title-20260924_101530")
        XCTAssertEqual(t2, "Title")
        XCTAssertNotNil(d2)
        let (t3, d3) = MeetingDisplayName.splitDate("No date here")
        XCTAssertEqual(t3, "No date here")
        XCTAssertNil(d3)
        let (t4, d4) = MeetingDisplayName.splitDate("Sync-20261345")
        XCTAssertEqual(t4, "Sync-20261345")
        XCTAssertNil(d4)
    }
}
