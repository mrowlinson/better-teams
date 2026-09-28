// TranscriptsWiringTests.swift — transcripts-wiring lane: views show displayName.
import AVKit
import XCTest

@testable import OstMacCore

/// Pins the view wiring: rows render `item.displayName` (both
/// browsers) and the turns/player cards take the legible title from
/// the ViewModel (`contentTitle`/`playTitle`), never the raw server
/// filename.
@MainActor
final class TranscriptsWiringTests: XCTestCase {
    func testTranscriptContentTitleIsDisplayName() async throws {
        let m = TranscriptsViewModel(
            listFetcher: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: TranscriptsTests.listJSON())
            },
            searchFetcher: { q in
                TranscriptsSearchResponse(ok: true, query: q, transcripts: [])
            },
            downloadFetcher: { _, _, dest in dest },
            recordingLookup: { _ in nil },
            openURL: { _ in true })
        await m.load()
        m.select(m.items[0])
        XCTAssertEqual(m.items[0].name, "Weekly Sync-20260924.vtt")
        XCTAssertEqual(m.contentTitle, m.items[0].displayName)
        XCTAssertEqual(m.contentTitle, "Weekly Sync · Sep 24, 2026")
    }

    func testRecordingPlayTitleIsDisplayName() async throws {
        let m = RecordingsViewModel(
            listFetcher: {
                try JSONDecoder().decode(
                    RecordingsResponse.self, from: RecordingsTests.listJSON())
            },
            searchFetcher: { q in
                RecordingsSearchResponse(ok: true, query: q, recordings: [])
            },
            downloadFetcher: { _, _, dest in dest },
            playerFactory: { _ in AVPlayer() },
            openURL: { _ in true })
        await m.load()
        m.play(m.items[0])
        XCTAssertEqual(m.items[0].name, "Weekly Sync-20260924.mp4")
        XCTAssertEqual(m.playTitle, m.items[0].displayName)
        XCTAssertEqual(m.playTitle, "Weekly Sync · Sep 24, 2026")
        m.closePlayer()
    }

    /// Rows strip server codes + exts even when no date parses.
    func testRowDisplayNamesStripServerCodes() {
        let t = TranscriptItem(id: "t", name: "Standup-20260924 [AB12-X9].vtt")
        XCTAssertEqual(t.displayName, "Standup · Sep 24, 2026")
        let r = RecordingItem(id: "r", name: "Standup-20260924 (AB12-X9).mp4")
        XCTAssertEqual(r.displayName, "Standup · Sep 24, 2026")
        let bare = TranscriptItem(id: "b", name: "Q3 Review with Tom Becker.vtt")
        XCTAssertEqual(bare.displayName, "Q3 Review with Tom Becker")
        XCTAssertFalse(bare.displayName.contains(".vtt"))
    }
}
