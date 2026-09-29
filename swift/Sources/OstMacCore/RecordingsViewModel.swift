// RecordingsViewModel.swift — searchable recordings list + playback.
import AVKit
import Combine
import Foundation

/// Recordings list state (mirrors PlannerState).
public enum RecordingsState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Non-empty rows in `items`.
    case loaded
    /// Fetch succeeded with zero rows.
    case empty
    /// Fetch failed; associated user-facing message.
    case error(String)
}

/// Player state for the selected recording.
public enum RecordingPlayback: Equatable, Sendable {
    /// Nothing selected / player closed.
    case idle
    /// Resolving the play URL (stream or download).
    case loading
    /// Player handed a URL and told to play.
    case playing
    /// Paused via the transport toggle.
    case paused
    /// Resolve failed; associated user-facing message.
    case failed(String)
}

/// Loads meeting recordings off the main thread, owns search,
/// selection, and in-app playback. Default fetchers call
/// `RecordingsCore.*` / `RustCore.sharedDownload` (blocking FFI +
/// network) on detached tasks. Tests inject mock fetchers.
@MainActor
public final class RecordingsViewModel: ObservableObject {
    /// Sync list fetch (runs off-main). Throws `CoreCallError` on failure.
    public typealias ListFetcher = @Sendable () throws -> RecordingsResponse
    /// Sync search (runs off-main). Throws `CoreCallError` on failure.
    public typealias SearchFetcher = @Sendable (String) throws -> RecordingsSearchResponse
    /// Sync download to `dest`, returning the written path (runs
    /// off-main). The default maps `RustCore.sharedDownload`; the demo
    /// returns the programmatic clip (offline, same code path).
    public typealias DownloadFetcher = @Sendable (String, String, String) throws -> String
    /// Player constructor (tests inject a silent factory).
    public typealias PlayerFactory = @Sendable (URL) -> AVPlayer
    public typealias OpenURLFn = SharedFilesStore.OpenURLFn

    /// Current rows (list or, when searching, search hits).
    @Published public private(set) var items: [RecordingItem] = []
    /// Current list state. Starts `.loading`.
    @Published public private(set) var state: RecordingsState = .loading
    /// Search in flight.
    @Published public private(set) var isSearching = false
    /// True when `items` are search hits (clear restores the list).
    @Published public private(set) var isSearchResults = false
    /// Last search failure (nil when clear; rows keep showing).
    @Published public private(set) var searchError: String?
    /// Last submitted query (trimmed).
    public private(set) var lastQuery = ""
    /// Selected recording id (nil = no player card).
    @Published public private(set) var selectedID: String?
    /// Player state for the selection.
    @Published public private(set) var playback: RecordingPlayback = .idle
    /// Live player (nil until a play URL resolves).
    @Published public private(set) var player: AVPlayer?
    /// Playback position (ms) while a player is live, updated twice a
    /// second and on seeks (Recaps highlights the transcript turn under
    /// it). Nil without a player.
    @Published public private(set) var playheadMs: Int?
    /// Periodic time observer on `player` (removed with the player).
    private var timeObserver: Any?
    /// Resolved play URL (stream or local file).
    public private(set) var playURL: URL?
    /// Title of the loading/playing recording.
    public private(set) var playTitle: String?
    /// Last save destination (Save button confirmation).
    @Published public private(set) var savedPath: String?
    /// Last save failure (nil when clear).
    @Published public private(set) var actionError: String?

    /// Selected row, if any.
    public var selected: RecordingItem? {
        items.first { $0.id == selectedID }
    }

    private let listFetcher: ListFetcher
    private let searchFetcher: SearchFetcher
    private let downloadFetcher: DownloadFetcher
    private let playerFactory: PlayerFactory
    private let openURLFn: OpenURLFn
    /// Last full list (search restores it without refetching).
    private var listed: [RecordingItem] = []
    private var generation = 0

    public init(
        listFetcher: @escaping ListFetcher = { try RecordingsCore.list() },
        searchFetcher: @escaping SearchFetcher = { q in try RecordingsCore.search(query: q) },
        downloadFetcher: @escaping DownloadFetcher = { drive, item, dest in
            try RustCore.sharedDownload(driveID: drive, itemID: item, dest: dest).path
        },
        playerFactory: @escaping PlayerFactory = { HWVideo.makePlayer(url: $0, path: "recordings") },
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL
    ) {
        self.listFetcher = listFetcher
        self.searchFetcher = searchFetcher
        self.downloadFetcher = downloadFetcher
        self.playerFactory = playerFactory
        self.openURLFn = openURL
    }

    /// NOLOAD: last-good snapshot store (nil = memory only / demo).
    public var snapshots: SectionCache?
    static let snapshotKey = "recordings"

    /// Paint the last good list before any fetch. Pre-authenticated
    /// download URLs are never persisted (playback falls back to the
    /// drive download until the list revalidates).
    @discardableResult
    public func restoreSnapshot() -> Bool {
        guard let cached = snapshots?.load([RecordingItem].self, key: Self.snapshotKey),
              !cached.isEmpty else { return false }
        listed = cached
        if !isSearchResults { items = cached }
        state = .loaded
        return true
    }

    /// Fetch the list. Search hits showing stay until cleared.
    public func load() async {
        state = .loading
        let fetcher = listFetcher
        do {
            let response = try await Task.blocking { try fetcher() }.value
            listed = response.recordings
            snapshots?.save(response.recordings.map(\.withoutDownloadURL), key: Self.snapshotKey)
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
        let result = await Task.blocking { () -> Result<[RecordingItem], Error> in
            do {
                return .success(try fetcher(q).recordings)
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

    /// Select a row (shows the player card; no autoplay).
    public func select(_ item: RecordingItem) {
        if selectedID != item.id {
            stopPlayer()
        }
        selectedID = item.id
    }

    /// Select the first row and play it (shot hook).
    public func selectAndPlayFirst() {
        guard let first = items.first else { return }
        play(first)
    }

    /// Close the player card.
    public func closePlayer() {
        stopPlayer()
        selectedID = nil
    }

    /// Play a row: select it, resolve the play URL (stream the
    /// pre-authenticated `download_url`, else download to temp via the
    /// files stack), hand it to a fresh player. Late completions after
    /// a re-select are dropped (no cross-talk between rows).
    public func play(_ item: RecordingItem) {
        play(item, autoplay: true)
    }

    /// `autoplay: false` resolves the URL and hands the player over
    /// paused (Recaps: the player shows, the user starts it).
    public func play(_ item: RecordingItem, autoplay: Bool) {
        selectedID = item.id
        stopPlayer()
        playback = .loading
        playTitle = item.displayName
        generation += 1
        let gen = generation
        Task {
            let fetcher = downloadFetcher
            do {
                let url = try await Task.blocking {
                    try Self.resolveURL(for: item, download: fetcher)
                }.value
                guard gen == generation else { return } // superseded
                let p = playerFactory(url)
                player = p
                playURL = url
                observePlayhead(p)
                if autoplay {
                    p.play()
                    playback = .playing
                } else {
                    playback = .paused
                }
            } catch {
                guard gen == generation else { return }
                playback = .failed(Self.message(for: error))
            }
        }
    }

    /// Pause/resume the live player. No-op without one.
    public func toggle() {
        guard player != nil else { return }
        switch playback {
        case .playing:
            player?.pause()
            playback = .paused
        case .paused:
            player?.play()
            playback = .playing
        default:
            break
        }
    }

    /// Open the recording in the browser (no-op without a web URL).
    public func open(_ item: RecordingItem) {
        guard let raw = item.web_url, let url = URL(string: raw) else { return }
        _ = openURLFn(url)
    }

    /// Save the recording via the files download (Save panel default
    /// mirrors the Shared tab: `~/Downloads/<name>`).
    public func save(_ item: RecordingItem) {
        guard item.drive_id != nil else {
            actionError = "No drive id for this recording."
            return
        }
        actionError = nil
        savedPath = nil
        let fetcher = downloadFetcher
        Task {
            do {
                let path = try await Task.blocking {
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

    private func observePlayhead(_ p: AVPlayer) {
        playheadMs = 0
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2), queue: .main
        ) { [weak self] time in
            let ms = time.isNumeric ? Int(time.seconds * 1000) : nil
            Task { @MainActor [weak self] in self?.playheadMs = ms }
        }
    }

    private func stopPlayer() {
        player?.pause()
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        playheadMs = nil
        player = nil
        playURL = nil
        playTitle = nil
        playback = .idle
    }

    /// Resolve a playable URL: stream `download_url` when present,
    /// else download to temp. Pure except the injected download.
    public nonisolated static func resolveURL(
        for item: RecordingItem,
        download: @escaping DownloadFetcher
    ) throws -> URL {
        if let raw = item.download_url,
           let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https"
        {
            return url
        }
        guard let drive = item.drive_id, !drive.isEmpty else {
            throw CoreCallError.failed("No playable URL for this recording.")
        }
        let path = try download(drive, item.id, playDest(for: item))
        return URL(fileURLWithPath: path)
    }

    /// Temp destination for play-to-cache downloads.
    public nonisolated static func playDest(for item: RecordingItem) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-recordings-play", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let safe = item.id.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe)-\(item.name)").path
    }

    /// Save destination mirroring the Shared tab default.
    public nonisolated static func downloadsDest(for item: RecordingItem) -> String {
        UserFolders.downloads()
            .appendingPathComponent(item.name).path
    }

    public nonisolated static func message(for error: Error) -> String {
        FriendlyError.message(for: error)
    }
}
