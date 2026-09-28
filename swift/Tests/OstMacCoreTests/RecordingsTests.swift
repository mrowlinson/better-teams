// RecordingsTests.swift — om-recordings lane: wire decode, ViewModel, demo.
import AVKit
import XCTest

@testable import OstMacCore

@MainActor
final class RecordingsTests: XCTestCase {
    // MARK: - Fixtures

    nonisolated static func listJSON() -> Data {
        """
        {"ok":true,"recordings":[
          {"id":"r1","name":"Weekly Sync-20260924.mp4","size":48211300,
           "mime":"video/mp4","web_url":"https://x/r1",
           "download_url":"https://x/dl1","drive_id":"d1",
           "created":"2026-09-24T09:00:00Z",
           "modified":"2026-09-24T10:00:00Z",
           "duration_ms":3723000,"source":"OneDrive"},
          {"id":"r2","name":"Q3 Review.mp4","size":128440100,
           "source":"Engineering > #general"}
        ]}
        """.data(using: .utf8)!
    }

    nonisolated static func searchJSON() -> Data {
        """
        {"ok":true,"query":"sync","recordings":[
          {"id":"r1","name":"Weekly Sync-20260924.mp4","size":48211300,
           "duration_ms":3723000,"source":"OneDrive"}
        ]}
        """.data(using: .utf8)!
    }

    nonisolated static func items() -> [RecordingItem] {
        try! JSONDecoder().decode(RecordingsResponse.self, from: listJSON()).recordings
    }

    static func model(
        list: @escaping RecordingsViewModel.ListFetcher,
        search: @escaping RecordingsViewModel.SearchFetcher =
            { q in RecordingsSearchResponse(ok: true, query: q, recordings: []) },
        download: @escaping RecordingsViewModel.DownloadFetcher =
            { _, _, dest in dest },
        opened: Box<[String]>? = nil
    ) -> RecordingsViewModel {
        RecordingsViewModel(
            listFetcher: list,
            searchFetcher: search,
            downloadFetcher: download,
            playerFactory: { _ in AVPlayer() },
            openURL: {
                opened?.value.append($0.absoluteString)
                return true
            })
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
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - Decode

    func testListResponseDecodesRows() throws {
        let resp = try JSONDecoder().decode(
            RecordingsResponse.self, from: Self.listJSON())
        XCTAssertEqual(resp.recordings.count, 2)
        let r = resp.recordings[0]
        XCTAssertEqual(r.name, "Weekly Sync-20260924.mp4")
        XCTAssertEqual(r.duration_ms, 3_723_000)
        XCTAssertEqual(r.source, "OneDrive")
        XCTAssertEqual(r.sizeLabel, "48.2 MB")
        XCTAssertEqual(r.durationLabel, "1:02:03")
        XCTAssertEqual(r.iconName, "film")
        // Sparse rows decode (all optionals missing but source).
        XCTAssertNil(resp.recordings[1].duration_ms)
        XCTAssertEqual(resp.recordings[1].detailLine, "")
    }

    func testSearchResponseDecodesRows() throws {
        let resp = try JSONDecoder().decode(
            RecordingsSearchResponse.self, from: Self.searchJSON())
        XCTAssertEqual(resp.query, "sync")
        XCTAssertEqual(resp.recordings.count, 1)
        XCTAssertEqual(resp.recordings[0].durationLabel, "1:02:03")
    }

    func testDurationLabelMatrix() {
        XCTAssertEqual(RecordingItem.durationLabel(0), "0:00")
        XCTAssertEqual(RecordingItem.durationLabel(43_000), "0:43")
        XCTAssertEqual(RecordingItem.durationLabel(754_000), "12:34")
        XCTAssertEqual(RecordingItem.durationLabel(3_723_000), "1:02:03")
    }

    func testDisplayDateFallsBackToRaw() {
        XCTAssertEqual(
            RecordingItem.displayDate("2026-09-24T10:00:00Z"), "Sep 24, 2026")
        XCTAssertEqual(RecordingItem.displayDate("not-a-date"), "not-a-date")
    }

    // MARK: - Load

    func testLoadPopulatesRows() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                RecordingsResponse.self, from: Self.listJSON())
        })
        await m.load()
        XCTAssertEqual(m.state, .loaded)
        XCTAssertEqual(m.items.count, 2)
    }

    func testLoadEmptyYieldsEmpty() async {
        let m = Self.model(list: { RecordingsResponse(ok: true, recordings: []) })
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
                    RecordingsResponse.self, from: Self.listJSON())
            },
            search: { q in
                try JSONDecoder().decode(
                    RecordingsSearchResponse.self, from: Self.searchJSON())
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
                    RecordingsResponse.self, from: Self.listJSON())
            },
            search: { q in
                calls.value += 1
                return RecordingsSearchResponse(
                    ok: true, query: q, recordings: [])
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
                    RecordingsResponse.self, from: Self.listJSON())
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
                    RecordingsResponse.self, from: Self.listJSON())
            },
            search: { q in
                RecordingsSearchResponse(ok: true, query: q, recordings: [])
            })
        await m.load()
        await m.search(query: "zzz-no-hits")
        XCTAssertEqual(m.state, .empty)
        m.clearSearch()
        XCTAssertFalse(m.isSearchResults)
        XCTAssertEqual(m.items.count, 2)
        XCTAssertEqual(m.state, .loaded)
    }

    // MARK: - Playback

    func testPlayStreamsDownloadURL() async throws {
        let downloads = Box(0)
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    RecordingsResponse.self, from: Self.listJSON())
            },
            download: { _, _, dest in
                downloads.value += 1
                return dest
            })
        await m.load()
        m.play(m.items[0]) // carries download_url
        let ok = await waitFor { m.playback == .playing }
        XCTAssertTrue(ok)
        XCTAssertEqual(m.playURL?.absoluteString, "https://x/dl1")
        XCTAssertEqual(downloads.value, 0) // streamed, not downloaded
        XCTAssertNotNil(m.player)
    }

    func testPlayDownloadsWhenURLExpired() async throws {
        let m = Self.model(
            list: {
                var items = Self.items()
                // Expired URL + known drive: files-stack fallback.
                items[1] = RecordingItem(
                    id: "r2", name: "Q3 Review.mp4", drive_id: "d9")
                return RecordingsResponse(ok: true, recordings: items)
            },
            download: { drive, item, dest in
                XCTAssertEqual(drive, "d9")
                XCTAssertEqual(item, "r2")
                return "/tmp/om-test-\(item).mp4"
            })
        await m.load()
        m.play(m.items[1])
        let ok = await waitFor { m.playback == .playing }
        XCTAssertTrue(ok)
        XCTAssertEqual(m.playURL?.path, "/tmp/om-test-r2.mp4")
    }

    func testPlayWithoutURLOrDriveFails() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                RecordingsResponse.self, from: Self.listJSON())
        })
        await m.load()
        m.play(m.items[1]) // no download_url, no drive_id
        let ok = await waitFor {
            if case .failed = m.playback { return true }
            return false
        }
        XCTAssertTrue(ok)
        XCTAssertNil(m.player)
    }

    func testSupersededPlayDropsFirst() async throws {
        let gate = DispatchSemaphore(value: 0)
        let m = Self.model(
            list: {
                RecordingsResponse(ok: true, recordings: [
                    RecordingItem(id: "a", name: "a.mp4", drive_id: "d"),
                    RecordingItem(id: "b", name: "b.mp4", drive_id: "d"),
                ])
            },
            download: { _, item, _ in
                if item == "a" { gate.wait() } // first stalls…
                return "/tmp/om-test-\(item).mp4"
            })
        await m.load()
        m.play(m.items[0])
        try? await Task.sleep(nanoseconds: 100_000_000)
        m.play(m.items[1]) // …second wins before it lands
        gate.signal()
        let ok = await waitFor { m.playback == .playing }
        XCTAssertTrue(ok)
        XCTAssertEqual(m.playURL?.path, "/tmp/om-test-b.mp4")
    }

    func testTogglePausesAndResumes() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                RecordingsResponse.self, from: Self.listJSON())
        })
        await m.load()
        m.toggle() // no player: no-op
        XCTAssertEqual(m.playback, .idle)
        m.play(m.items[0])
        let reachedPlaying = await waitFor({ m.playback == .playing })
        XCTAssertTrue(reachedPlaying)
        m.toggle()
        XCTAssertEqual(m.playback, .paused)
        m.toggle()
        XCTAssertEqual(m.playback, .playing)
    }

    func testSelectAndPlayFirst() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                RecordingsResponse.self, from: Self.listJSON())
        })
        await m.load()
        m.selectAndPlayFirst()
        let reachedPlaying = await waitFor({ m.playback == .playing })
        XCTAssertTrue(reachedPlaying)
        XCTAssertEqual(m.selectedID, "r1")
    }

    func testSelectThenCloseResetsPlayer() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                RecordingsResponse.self, from: Self.listJSON())
        })
        await m.load()
        m.select(m.items[0])
        XCTAssertEqual(m.selectedID, "r1")
        XCTAssertEqual(m.playback, .idle) // select never autoplays
        m.closePlayer()
        XCTAssertNil(m.selectedID)
    }

    func testResolveURLMatrix() throws {
        // https streams.
        let stream = try RecordingsViewModel.resolveURL(
            for: RecordingItem(
                id: "s", name: "s.mp4",
                download_url: "https://x/dl"),
            download: { _, _, _ in XCTFail("must stream"); return "" })
        XCTAssertEqual(stream.absoluteString, "https://x/dl")
        // Non-http schemes fall through to download, not a crash.
        let file = try RecordingsViewModel.resolveURL(
            for: RecordingItem(
                id: "f", name: "f.mp4", download_url: "ftp://x/f",
                drive_id: "d"),
            download: { _, _, dest in dest })
        XCTAssertTrue(file.isFileURL)
        // Nothing playable throws.
        XCTAssertThrowsError(try RecordingsViewModel.resolveURL(
            for: RecordingItem(id: "n", name: "n.mp4"),
            download: { _, _, dest in dest }))
    }

    func testDestPaths() {
        let item = RecordingItem(id: "r/1", name: "a.mp4")
        let play = RecordingsViewModel.playDest(for: item)
        XCTAssertTrue(play.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(play.hasSuffix("r_1-a.mp4")) // id sanitized
        let save = RecordingsViewModel.downloadsDest(for: item)
        XCTAssertTrue(save.hasSuffix("/Downloads/a.mp4"))
    }

    // MARK: - Open / save

    func testOpenUsesWebURL() async throws {
        let opened = Box<[String]>([])
        let m = Self.model(
            list: {
                try JSONDecoder().decode(
                    RecordingsResponse.self, from: Self.listJSON())
            },
            opened: opened)
        await m.load()
        m.open(m.items[0])
        XCTAssertEqual(opened.value, ["https://x/r1"])
        m.open(m.items[1]) // no web_url: no call
        XCTAssertEqual(opened.value, ["https://x/r1"])
    }

    func testSavePublishesPath() async throws {
        let m = Self.model(
            list: {
                RecordingsResponse(ok: true, recordings: [
                    RecordingItem(
                        id: "r1", name: "a.mp4", drive_id: "d1")
                ])
            },
            download: { _, _, dest in dest })
        await m.load()
        m.save(m.items[0])
        let saved = await waitFor({ m.savedPath != nil })
        XCTAssertTrue(saved)
        XCTAssertTrue(m.savedPath?.hasSuffix("/Downloads/a.mp4") ?? false)
    }

    func testSaveWithoutDriveErrors() async throws {
        let m = Self.model(list: {
            try JSONDecoder().decode(
                RecordingsResponse.self, from: Self.listJSON())
        })
        await m.load()
        m.save(m.items[1])
        XCTAssertEqual(m.actionError, "No drive id for this recording.")
        XCTAssertNil(m.savedPath)
    }

    // MARK: - Demo

    func testDemoResponseHasFourRows() {
        let resp = RecordingsDemo.response()
        XCTAssertEqual(resp.recordings.count, 4)
        XCTAssertTrue(resp.recordings.allSatisfy {
            $0.duration_ms != nil && $0.source != nil
        })
        // Demo rows play via the files-download fallback (clip writer),
        // so every row needs a drive id (else "No playable URL").
        XCTAssertTrue(resp.recordings.allSatisfy {
            ($0.drive_id?.isEmpty ?? true) == false
        })
    }

    func testDemoRowsPlayThroughClip() async throws {
        let m = Self.model(
            list: { RecordingsDemo.response() },
            download: { _, _, _ in try DemoClip.url().path })
        await m.load()
        m.selectAndPlayFirst()
        let reachedPlaying = await waitFor({ m.playback == .playing })
        XCTAssertTrue(reachedPlaying)
        XCTAssertEqual(m.playURL?.pathExtension, "mp4")
    }

    func testDemoSearchFilters() {
        let hits = RecordingsDemo.searchResponse(for: "megan")
        XCTAssertEqual(hits.recordings.count, 1)
        XCTAssertTrue(hits.recordings[0].name.contains("Megan Harper"))
        let channel = RecordingsDemo.searchResponse(for: "engineering")
        XCTAssertEqual(channel.recordings.count, 1)
        XCTAssertTrue(RecordingsDemo.searchResponse(for: "zzz").recordings.isEmpty)
    }

    func testDemoClipRendersPlayableFile() throws {
        let url = try DemoClip.url()
        XCTAssertEqual(url.pathExtension, "mp4")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attrs[.size] as? UInt64) ?? 0, 0)
        // Second call hits the cache (same path, no re-encode).
        XCTAssertEqual(try DemoClip.url(), url)
    }
}
