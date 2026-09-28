// TranscriptsViewModel.swift — searchable transcripts list + turns.
import Combine
import Foundation

/// Transcripts list state (mirrors RecordingsState).
public enum TranscriptsState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty rows in `items`.
    case loaded
    /// Fetch succeeded with zero rows.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Transcript content state for the selected row.
public enum TranscriptContent: Equatable, Sendable {
    /// Nothing selected / card closed.
    case idle
    /// Downloading VTT bytes.
    case loading
    /// Parsed turns in `cues`.
    case loaded
    /// Download or parse failed; associated user-facing message.
    case failed(String)
}

/// Loads meeting transcripts off the main thread, owns search,
/// selection, and download-then-parse turns. Default fetchers call
/// `TranscriptsCore.*` / `RustCore.sharedDownload` (blocking FFI +
/// network) on detached tasks. Tests inject mock fetchers.
@MainActor
public final class TranscriptsViewModel: ObservableObject {
    /// Sync list fetch (runs off-main). Throws `CoreCallError` on failure.
    public typealias ListFetcher = @Sendable () throws -> TranscriptsResponse
    /// Sync search (runs off-main). Throws `CoreCallError` on failure.
    public typealias SearchFetcher = @Sendable (String) throws -> TranscriptsSearchResponse
    /// Sync download to `dest`, returning the written path (runs
    /// off-main). The default maps `RustCore.sharedDownload`; the demo
    /// writes the synthetic VTT (offline, same code path).
    public typealias DownloadFetcher = @Sendable (String, String, String) throws -> String
    /// Sibling-recording lookup by filename stem (nil = no linkage).
    /// Wired from the recordings list; see `TranscriptItem.stem`.
    /// Main-actor (reads the live recordings rows); never hops threads.
    public typealias RecordingLookup = (String) -> RecordingItem?
    public typealias OpenURLFn = SharedFilesStore.OpenURLFn

    /// Current rows (list or, when searching, search hits).
    @Published public private(set) var items: [TranscriptItem] = []
    /// Current list state. Starts `.loading`.
    @Published public private(set) var state: TranscriptsState = .loading
    /// Search in flight.
    @Published public private(set) var isSearching = false
    /// True when `items` are search hits (clear restores the list).
    @Published public private(set) var isSearchResults = false
    /// Last search failure (nil when clear; rows keep showing).
    @Published public private(set) var searchError: String?
    /// Last submitted query (trimmed).
    public private(set) var lastQuery = ""
    /// Selected transcript id (nil = no turns card).
    @Published public private(set) var selectedID: String?
    /// Content state for the selection.
    @Published public private(set) var content: TranscriptContent = .idle
    /// Parsed turns for the selection.
    @Published public private(set) var cues: [TranscriptCue] = []
    /// Title of the loading/loaded transcript.
    public private(set) var contentTitle: String?
    /// Last save destination (Save button confirmation).
    @Published public private(set) var savedPath: String?
    /// Last save failure (nil when clear).
    @Published public private(set) var actionError: String?
    /// On-device action-items extraction over the loaded cues
    /// (f1-actions). Owned here so the turns card and the extraction
    /// share one lifecycle; the browser observes it directly.
    public let actionItems: ActionItemsStore
    /// Shot hook only (--show-transcripts-actions): extract once the
    /// selected turns land. Real taps always come from the button.
    public var autoExtractActionItems = false

    /// Selected row, if any.
    public var selected: TranscriptItem? {
        items.first { $0.id == selectedID }
    }

    /// Sibling `.mp4` recording row for the selection, when the lookup
    /// resolves its stem (nil without a wired lookup or match).
    public var siblingRecording: RecordingItem? {
        guard let item = selected else { return nil }
        return recordingLookup(item.stem)
    }

    private let listFetcher: ListFetcher
    private let searchFetcher: SearchFetcher
    private let downloadFetcher: DownloadFetcher
    private let recordingLookup: RecordingLookup
    private let openURLFn: OpenURLFn
    /// Last full list (search restores it without refetching).
    private var listed: [TranscriptItem] = []
    private var generation = 0

    public init(
        listFetcher: @escaping ListFetcher = { try TranscriptsCore.list() },
        searchFetcher: @escaping SearchFetcher = { q in try TranscriptsCore.search(query: q) },
        downloadFetcher: @escaping DownloadFetcher = { drive, item, dest in
            try RustCore.sharedDownload(driveID: drive, itemID: item, dest: dest).path
        },
        recordingLookup: @escaping RecordingLookup = { _ in nil },
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL,
        actionItemsTransport: (any CatchUpTransport)? = nil
    ) {
        self.listFetcher = listFetcher
        self.searchFetcher = searchFetcher
        self.downloadFetcher = downloadFetcher
        self.recordingLookup = recordingLookup
        self.openURLFn = openURL
        self.actionItems = ActionItemsStore(transport: actionItemsTransport)
    }

    /// Fetch the list. Search hits showing stay until cleared.
    public func load() async {
        state = .loading
        let fetcher = listFetcher
        do {
            let response = try await Task.detached { try fetcher() }.value
            listed = response.transcripts
            if !isSearchResults {
                items = listed
            }
            state = listed.isEmpty && !isSearchResults ? .empty : .loaded
        } catch {
            state = .error(Self.message(for: error))
        }
    }

    /// Fire-and-forget reload (error-state Retry, sign-in).
    public func refresh() {
        Task { await load() }
    }

    /// Fresh search; replaces rows. Blank queries restore the list
    /// without touching core. Stale completions are dropped. A search
    /// failure keeps the current rows with the error beside the field.
    public func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        guard !q.isEmpty else {
            items = listed
            isSearchResults = false
            isSearching = false
            searchError = nil
            lastQuery = ""
            state = listed.isEmpty ? .empty : .loaded
            return
        }
        lastQuery = q
        isSearching = true
        searchError = nil
        let fetcher = searchFetcher
        let result = await Task.detached { () -> Result<[TranscriptItem], Error> in
            do {
                return .success(try fetcher(q).transcripts)
            } catch {
                return .failure(error)
            }
        }.value
        guard gen == generation else { return } // superseded
        isSearching = false
        switch result {
        case .success(let rows):
            items = rows
            isSearchResults = true
            searchError = nil
            state = rows.isEmpty ? .empty : .loaded
        case .failure(let error):
            searchError = Self.message(for: error)
        }
    }

    /// Drop the search, restore the list (no refetch).
    public func clearSearch() {
        generation += 1
        items = listed
        isSearchResults = false
        isSearching = false
        searchError = nil
        lastQuery = ""
        state = listed.isEmpty ? .empty : .loaded
    }

    /// Select a row and load its turns (download VTT to temp, parse).
    /// Late completions after a re-select are dropped (no cross-talk
    /// between rows).
    public func select(_ item: TranscriptItem) {
        selectedID = item.id
        cues = []
        content = .loading
        contentTitle = item.displayName
        actionItems.reset() // source switch resets the extraction
        generation += 1
        let gen = generation
        Task {
            let fetcher = downloadFetcher
            do {
                let turns = try await Task.detached {
                    try Self.downloadTurns(for: item, download: fetcher)
                }.value
                guard gen == generation else { return } // superseded
                cues = turns
                content = .loaded
                if autoExtractActionItems {
                    await extractActionItems()
                }
            } catch {
                guard gen == generation else { return }
                content = .failed(Self.message(for: error))
            }
        }
    }

    /// Extract action items over the loaded cues (tap-to-run). No
    /// selection / no cues short-circuits in the store without a
    /// model call; an unchanged source replays the cached bullets.
    public func extractActionItems() async {
        await actionItems.extractFromCues(cues, transcriptID: selectedID)
    }

    /// Select the first row and load it (shot hook).
    public func selectAndShowFirst() {
        guard let first = items.first else { return }
        select(first)
    }

    /// Close the turns card.
    public func closeTranscript() {
        selectedID = nil
        cues = []
        content = .idle
        contentTitle = nil
        actionItems.reset()
        generation += 1
    }

    /// Open the transcript in the browser (no-op without a web URL).
    public func open(_ item: TranscriptItem) {
        guard let raw = item.web_url, let url = URL(string: raw) else { return }
        _ = openURLFn(url)
    }

    /// Save the transcript `.vtt` via the files download (Save panel
    /// default mirrors the Shared tab: `~/Downloads/<name>`).
    public func save(_ item: TranscriptItem) {
        guard item.drive_id != nil else {
            actionError = "No drive id for this transcript."
            return
        }
        actionError = nil
        savedPath = nil
        let fetcher = downloadFetcher
        Task {
            do {
                let path = try await Task.detached {
                    try fetcher(
                        item.drive_id ?? "", item.id,
                        Self.downloadsDest(for: item))
                }.value
                savedPath = path
            } catch {
                actionError = Self.message(for: error)
            }
        }
    }

    /// Download VTT bytes to temp and parse turns. Pure except the
    /// injected download. Throws when the drive id is missing, the
    /// bytes are unreadable, or no cues parse.
    public nonisolated static func downloadTurns(
        for item: TranscriptItem,
        download: @escaping DownloadFetcher
    ) throws -> [TranscriptCue] {
        guard let drive = item.drive_id, !drive.isEmpty else {
            throw CoreCallError.failed("No drive id for this transcript.")
        }
        let path = try download(drive, item.id, turnsDest(for: item))
        let bytes: String
        do {
            bytes = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CoreCallError.failed("Couldn't read the downloaded transcript.")
        }
        let turns = parseVTT(bytes)
        guard !turns.isEmpty else {
            throw CoreCallError.failed("No speaker turns found in this transcript.")
        }
        return turns
    }

    /// Temp destination for turns downloads.
    public nonisolated static func turnsDest(for item: TranscriptItem) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-transcripts-turns", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let safe = item.id.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe)-\(item.name)").path
    }

    /// Save destination mirroring the Shared tab default.
    public nonisolated static func downloadsDest(for item: TranscriptItem) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent(item.name).path
    }

    public nonisolated static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
