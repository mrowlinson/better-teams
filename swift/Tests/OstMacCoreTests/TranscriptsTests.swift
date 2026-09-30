// TranscriptsTests.swift — om-transcripts-build lane: decode, parser, ViewModel, demo.
import XCTest

@testable import OstMacCore

@MainActor
final class TranscriptsTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func listJSON() -> Data {
        """
        {"ok":true,"transcripts":[
          {"id":"t1","name":"Weekly Sync-20260924.vtt","size":4211,
           "mime":"text/vtt","web_url":"https://x/t1","drive_id":"d1",
           "created":"2026-09-24T09:00:00Z",
           "modified":"2026-09-24T10:00:00Z",
           "source":"OneDrive"},
          {"id":"t2","name":"Q3 Review.vtt","size":12844,
           "source":"Engineering > #general"}
        ]}
        """.data(using: .utf8)!
    }

    nonisolated static func searchJSON() -> Data {
        """
        {"ok":true,"query":"sync","transcripts":[
          {"id":"t1","name":"Weekly Sync-20260924.vtt","size":4211,
           "source":"OneDrive"}
        ]}
        """.data(using: .utf8)!
    }

    nonisolated static func items() -> [TranscriptItem] {
        try! JSONDecoder().decode(TranscriptsResponse.self, from: listJSON()).transcripts
    }

    static func model(
        list: @escaping TranscriptsViewModel.ListFetcher,
        search: @escaping TranscriptsViewModel.SearchFetcher =
            { q in TranscriptsSearchResponse(ok: true, query: q, transcripts: []) },
        download: @escaping TranscriptsViewModel.DownloadFetcher =
            { _, _, dest in dest },
        lookup: @escaping TranscriptsViewModel.RecordingLookup = { _ in nil },
        opened: Box<[String]>? = nil
    ) -> TranscriptsViewModel {
        TranscriptsViewModel(
            listFetcher: list,
            searchFetcher: search,
            downloadFetcher: download,
            recordingLookup: lookup,
            openURL: {
                opened?.value.append($0.absoluteString)
                return true
            })
    }

    /// Download mock that writes VTT bytes to the requested dest (same
    /// code path as the live files download: VM reads + parses).
    static func vttDownload(_ vtt: String) -> TranscriptsViewModel.DownloadFetcher {
        { _, _, dest in
            try vtt.write(toFile: dest, atomically: true, encoding: .utf8)
            return dest
        }
    }

    /// Main-actor test box (fetchers hop threads; NSLock keeps it safe).
    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var inner: T
        init(_ v: T) { inner = v }
        var value: T {
            get { lock.withLock { inner } }
            set { lock.withLock { inner = newValue } }
        }
    }

    func waitFor(
        _ cond: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        await TestWait.until(ceiling: max(timeout, TestWait.hangCeiling), interval: 0.02) { cond() }
    }

    // MARK: - Decode

    func testListResponseDecodesRows() throws {
        let resp = try JSONDecoder().decode(
            TranscriptsResponse.self, from: Self.listJSON())
        XCTAssertEqual(resp.transcripts.count, 2)
        let t = resp.transcripts[0]
        XCTAssertEqual(t.name, "Weekly Sync-20260924.vtt")
        XCTAssertEqual(t.stem, "Weekly Sync-20260924")
        XCTAssertEqual(t.source, "OneDrive")
        XCTAssertEqual(t.sizeLabel, "4 KB")
        XCTAssertEqual(t.iconName, "doc.text")
        XCTAssertEqual(t.detailLine, "Sep 24, 2026 · 4 KB")
        // Sparse rows decode (all optionals missing but source).
        XCTAssertNil(resp.transcripts[1].drive_id)
        XCTAssertEqual(resp.transcripts[1].stem, "Q3 Review")
    }

    func testSearchResponseDecodesRows() throws {
        let resp = try JSONDecoder().decode(
            TranscriptsSearchResponse.self, from: Self.searchJSON())
        XCTAssertEqual(resp.query, "sync")
        XCTAssertEqual(resp.transcripts.count, 1)
        XCTAssertEqual(resp.transcripts[0].stem, "Weekly Sync-20260924")
    }

    func testStemMatrix() {
        XCTAssertEqual(TranscriptItem.stem(of: "a.vtt"), "a")
        XCTAssertEqual(TranscriptItem.stem(of: "Weekly Sync-20260924.mp4"), "Weekly Sync-20260924")
        XCTAssertEqual(TranscriptItem.stem(of: "noext"), "noext")
        XCTAssertEqual(TranscriptItem.stem(of: "a.vtt.txt"), "a.vtt")
    }

    func testDisplayDateFallsBackToRaw() {
        XCTAssertEqual(
            TranscriptItem.displayDate("2026-09-24T10:00:00Z"), "Sep 24, 2026")
        XCTAssertEqual(TranscriptItem.displayDate("not-a-date"), "not-a-date")
        XCTAssertNil(TranscriptItem(id: "x", name: "x.vtt").displayDate)
    }

    // MARK: - Parser matrix

    func testParserSampleTurns() {
        let cues = parseVTT(TranscriptsDemo.sampleVTT)
        XCTAssertEqual(cues.count, TranscriptsDemo.sampleTurns.count)
        for (cue, want) in zip(cues, TranscriptsDemo.sampleTurns) {
            XCTAssertEqual(cue.speaker, want.0)
            XCTAssertEqual(cue.startMs, want.1)
            XCTAssertEqual(cue.text, want.2)
        }
        // Hour+ end timestamps + cue settings ignored.
        XCTAssertEqual(cues[2].endMs, 3_767_250)
        XCTAssertEqual(cues[1].endMs, 72_000)
        XCTAssertEqual(cues[0].startLabel, "0:00")
        XCTAssertEqual(cues[2].startLabel, "1:02:03")
    }

    func testParserSkipsNoteStyleRegionAndHeader() {
        let cues = parseVTT("""
        WEBVTT - demo file

        NOTE this is a comment
        spanning lines

        STYLE
        ::cue { color: lime }

        REGION
        id:fred

        00:01.000 --> 00:02.000
        <v Ava Lindqvist>kept
        """)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].speaker, "Ava Lindqvist")
        XCTAssertEqual(cues[0].text, "kept")
    }

    func testParserMultiLineJoinsWithSpaces() {
        let cues = parseVTT("""
        WEBVTT

        00:00.000 --> 00:05.000
        line one
        line two
        """)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "line one line two")
    }

    func testParserMalformedCuesSkipWithoutThrow() {
        let cues = parseVTT("""
        WEBVTT

        no timing here
        just text

        00:xx --> 00:05.000
        bad start

        00:00.000 --> nope
        bad end

        00:01.000 --> 00:02.000
        <v Tom Becker>good
        """)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].speaker, "Tom Becker")
        XCTAssertEqual(cues[0].text, "good")
    }

    func testParserEmptyInputYieldsNoCues() {
        XCTAssertTrue(parseVTT("").isEmpty)
        XCTAssertTrue(parseVTT("WEBVTT\n").isEmpty)
    }

    func testCueStartLabelMatrix() {
        XCTAssertEqual(TranscriptCue.label(0), "0:00")
        XCTAssertEqual(TranscriptCue.label(43_000), "0:43")
        XCTAssertEqual(TranscriptCue.label(754_000), "12:34")
        XCTAssertEqual(TranscriptCue.label(3_723_000), "1:02:03")
    }

    // MARK: - Load

    func testLoadPopulatesRows() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                TranscriptsResponse.self, from: Self.listJSON())
        })
        await m.load()
        XCTAssertEqual(m.state, .loaded)
        XCTAssertEqual(m.items.count, 2)
    }

    func testLoadEmptyYieldsEmpty() async {
        let m = Self.model(list: { TranscriptsResponse(ok: true, transcripts: []) })
        await m.load()
        XCTAssertEqual(m.state, .empty)
    }

    func testLoadFailureSurfacesError() async {
        let m = Self.model(list: { throw CoreCallError.failed("signed out") })
        await m.load()
        XCTAssertEqual(m.state, .error("signed out"))
    }

    // MARK: - Search

    func testSearchReplacesRows() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            search: { _ in
                try JSONDecoder().decode(
                    TranscriptsSearchResponse.self, from: Self.searchJSON())
            })
        await m.load()
        await m.search(query: "sync")
        XCTAssertTrue(m.isSearchResults)
        XCTAssertEqual(m.lastQuery, "sync")
        XCTAssertEqual(m.items.count, 1)
        XCTAssertEqual(m.state, .loaded)
    }

    func testBlankSearchRestoresListWithoutCore() async throws {
        let calls = Box(0)
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            search: { q in
                calls.value += 1
                return TranscriptsSearchResponse(
                    ok: true, query: q, transcripts: [])
            })
        await m.load()
        await m.search(query: "sync")
        XCTAssertTrue(m.isSearchResults)
        await m.search(query: "   ")
        XCTAssertFalse(m.isSearchResults)
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(calls.value, 1) // blank never touches core
    }

    func testSearchFailureKeepsRowsAndSurfacesError() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            search: { _ in throw CoreCallError.failed("drive 403") })
        await m.load()
        await m.search(query: "sync")
        XCTAssertEqual(m.items.count, 2) // rows kept
        XCTAssertEqual(m.searchError, "drive 403")
        XCTAssertFalse(m.isSearching)
    }

    func testClearSearchRestoresList() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            search: { q in
                TranscriptsSearchResponse(ok: true, query: q, transcripts: [])
            })
        await m.load()
        await m.search(query: "zzz-no-hits")
        XCTAssertEqual(m.state, .empty)
        m.clearSearch()
        XCTAssertFalse(m.isSearchResults)
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(m.state, .loaded)
    }

    // MARK: - Select / turns

    func testSelectDownloadsAndParsesTurns() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            download: Self.vttDownload(TranscriptsDemo.sampleVTT))
        await m.load()
        m.select(m.items[0]) // carries drive_id
        let ok = await waitFor { m.content == .loaded }
        XCTAssertTrue(ok)
        XCTAssertEqual(m.selectedID, "t1")
        XCTAssertEqual(m.contentTitle, "Weekly Sync · Sep 24, 2026")
        XCTAssertEqual(m.cues.count, 4)
        XCTAssertEqual(m.cues[0].speaker, "Ava Lindqvist")
        XCTAssertEqual(m.cues[2].startLabel, "1:02:03")
    }

    func testSelectWithoutDriveFails() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            download: Self.vttDownload(TranscriptsDemo.sampleVTT))
        await m.load()
        m.select(m.items[1]) // no drive_id
        let ok = await waitFor {
            if case .failed = m.content { return true }
            return false
        }
        XCTAssertTrue(ok)
        XCTAssertTrue(m.cues.isEmpty)
    }

    func testSelectEmptyTurnsFails() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            download: Self.vttDownload("WEBVTT\n"))
        await m.load()
        m.select(m.items[0])
        let ok = await waitFor {
            if case .failed(let msg) = m.content {
                return msg.contains("No speaker turns")
            }
            return false
        }
        XCTAssertTrue(ok)
    }

    func testSupersededSelectDropsFirst() async throws {
        let gate = DispatchSemaphore(value: 0)
        let aStalled = Box(false)
        let m = Self.model(
            list: {
                TranscriptsResponse(ok: true, transcripts: [
                    TranscriptItem(id: "a", name: "a.vtt", drive_id: "d"),
                    TranscriptItem(id: "b", name: "b.vtt", drive_id: "d"),
                ])
            },
            download: { _, item, dest in
                if item == "a" { aStalled.value = true; gate.wait() } // first stalls…
                try TranscriptsDemo.sampleVTT.write(
                    toFile: dest, atomically: true, encoding: .utf8)
                return dest
            })
        await m.load()
        m.select(m.items[0])
        let stalled = await waitFor { aStalled.value }
        XCTAssertTrue(stalled) // first download is in flight before the second select
        m.select(m.items[1]) // …second wins before it lands
        gate.signal()
        let ok = await waitFor { m.content == .loaded }
        XCTAssertTrue(ok)
        XCTAssertEqual(m.selectedID, "b")
        XCTAssertEqual(m.cues.count, 4)
    }

    func testSelectAndShowFirst() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            download: Self.vttDownload(TranscriptsDemo.sampleVTT))
        await m.load()
        m.selectAndShowFirst()
        let ok = await waitFor { m.content == .loaded }
        XCTAssertTrue(ok)
        XCTAssertEqual(m.selectedID, "t1")
    }

    func testCloseTranscriptResets() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            download: Self.vttDownload(TranscriptsDemo.sampleVTT))
        await m.load()
        m.select(m.items[0])
        let ok = await waitFor { m.content == .loaded }
        XCTAssertTrue(ok)
        m.closeTranscript()
        XCTAssertNil(m.selectedID)
        XCTAssertEqual(m.content, .idle)
        XCTAssertTrue(m.cues.isEmpty)
    }

    func testDownloadTurnsMatrix() throws {
        // Missing drive throws before touching the fetcher.
        XCTAssertThrowsError(try TranscriptsViewModel.downloadTurns(
            for: TranscriptItem(id: "n", name: "n.vtt"),
            download: { _, _, _ in XCTFail("must not download"); return "" }))
        // Unreadable path (fetcher returns a missing file) throws.
        XCTAssertThrowsError(try TranscriptsViewModel.downloadTurns(
            for: TranscriptItem(id: "n", name: "n.vtt", drive_id: "d"),
            download: { _, _, _ in "/nonexistent-dir/n.vtt" }))
        // Happy path parses.
        let turns = try TranscriptsViewModel.downloadTurns(
            for: TranscriptItem(id: "n", name: "n.vtt", drive_id: "d"),
            download: { _, _, dest in
                try TranscriptsDemo.sampleVTT.write(
                    toFile: dest, atomically: true, encoding: .utf8)
                return dest
            })
        XCTAssertEqual(turns.count, 4)
    }

    func testDestPaths() {
        let item = TranscriptItem(id: "t/1", name: "a.vtt")
        let turns = TranscriptsViewModel.turnsDest(for: item)
        XCTAssertTrue(turns.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(turns.hasSuffix("t_1-a.vtt")) // id sanitized
        let save = TranscriptsViewModel.downloadsDest(for: item)
        XCTAssertTrue(save.hasSuffix("/Downloads/a.vtt"))
    }

    // MARK: - Sibling linkage

    func testSiblingRecordingResolvesByStem() async throws {
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            lookup: { stem in
                stem == "Weekly Sync-20260924"
                    ? RecordingItem(id: "r1", name: "Weekly Sync-20260924.mp4")
                    : nil
            })
        await m.load()
        XCTAssertNil(m.siblingRecording) // nothing selected
        m.select(m.items[0])
        XCTAssertEqual(m.siblingRecording?.id, "r1")
        m.select(m.items[1]) // no sibling for this stem
        XCTAssertNil(m.siblingRecording)
    }

    // MARK: - Open / save

    func testOpenUsesWebURL() async throws {
        let opened = Box<[String]>([])
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    TranscriptsResponse.self, from: Self.listJSON())
            },
            opened: opened)
        await m.load()
        m.open(m.items[0])
        XCTAssertEqual(opened.value, ["https://x/t1"])
        m.open(m.items[1]) // no web_url: no call
        XCTAssertEqual(opened.value, ["https://x/t1"])
    }

    func testSavePublishesPath() async throws {
        let m = Self.model(
            list: {
                TranscriptsResponse(ok: true, transcripts: [
                    TranscriptItem(
                        id: "t1", name: "a.vtt", drive_id: "d1")
                ])
            },
            download: { _, _, dest in dest })
        await m.load()
        m.save(m.items[0])
        let saved = await waitFor({ m.savedPath != nil })
        XCTAssertTrue(saved)
        XCTAssertTrue(m.savedPath?.hasSuffix("/Downloads/a.vtt") ?? false)
    }

    func testSaveWithoutDriveErrors() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                TranscriptsResponse.self, from: Self.listJSON())
        })
        await m.load()
        m.save(m.items[1])
        XCTAssertEqual(m.actionError, "No drive id for this transcript.")
        XCTAssertNil(m.savedPath)
    }

    // MARK: - Demo

    func testDemoResponseHasFiveRows() {
        let resp = TranscriptsDemo.response()
        XCTAssertEqual(resp.transcripts.count, 5)
        XCTAssertTrue(resp.transcripts.allSatisfy {
            $0.mime == "text/vtt" && $0.source != nil
        })
        // Turns load via the files-download fallback, so every row
        // needs a drive id (else "No drive id").
        XCTAssertTrue(resp.transcripts.allSatisfy {
            ($0.drive_id?.isEmpty ?? true) == false
        })
    }

    func testDemoRowsLoadThroughSampleVTT() async throws {
        let m = Self.model(
            list: { TranscriptsDemo.response() },
            download: Self.vttDownload(TranscriptsDemo.sampleVTT))
        await m.load()
        m.selectAndShowFirst()
        let ok = await waitFor { m.content == .loaded }
        XCTAssertTrue(ok)
        XCTAssertEqual(m.cues.count, 4)
    }

    func testDemoSearchFilters() {
        let hits = TranscriptsDemo.searchResponse(for: "megan")
        XCTAssertEqual(hits.transcripts.count, 1)
        XCTAssertTrue(hits.transcripts[0].name.contains("Megan Harper"))
        let channel = TranscriptsDemo.searchResponse(for: "engineering")
        XCTAssertEqual(channel.transcripts.count, 1)
        XCTAssertTrue(TranscriptsDemo.searchResponse(for: "zzz").transcripts.isEmpty)
    }

    func testDemoSampleParsesToPinnedTurns() {
        // The live-verify upload body, pinned end to end.
        let cues = parseVTT(TranscriptsDemo.sampleVTT)
        XCTAssertEqual(cues.count, 4)
        XCTAssertEqual(cues[1].text, "Thanks Ava. The Q3 numbers are up across the board.")
        XCTAssertEqual(cues[3].speaker, nil)
    }
}
