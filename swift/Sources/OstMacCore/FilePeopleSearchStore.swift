// FilePeopleSearchStore.swift — om-jb-filesearch lane: file + people search.
//
// INPUT API (what the jump palette drives):
//   store.search(query:) — fresh search for both sections (replaces rows)
//   store.retry()        — re-run the last query (error-state Try Again)
//   store.clear()        — drop query + rows (blank query, sheet dismiss)
import Foundation

/// Searches OneDrive files + the directory via ostmac-core.
///
/// Follows the om-ja-search store pattern: default searchers call the
/// blocking FFI on a detached task, a generation guard drops stale
/// completions, and blank queries clear without touching core. Graph
/// drive/`$search` calls are single-window (no cursors), so there is no
/// loadMore — each section either loads fully or surfaces its own error
/// while the other section keeps its rows. Tests inject mock searchers.
@MainActor
public final class FilePeopleSearchStore: ObservableObject {
    /// Sync file search (runs off-main). Throws `CoreCallError` on failure.
    public typealias FileSearcher = @Sendable (String, Int32) throws -> FileSearchResponse
    /// Sync people search (runs off-main). Throws `CoreCallError` on failure.
    public typealias PeopleSearcher = @Sendable (String, Int32) throws -> PeopleSearchResponse

    /// File hits for the last submitted query (server-ranked, unfiltered).
    @Published public private(set) var files: [SharedFile] = []
    /// People hits for the last submitted query (server-ranked, unfiltered).
    @Published public private(set) var people: [TeamMember] = []
    /// Search in flight (either section).
    @Published public private(set) var isSearching = false
    /// Last file-section failure (nil when clear).
    @Published public private(set) var fileError: String?
    /// Last people-section failure (nil when clear).
    @Published public private(set) var peopleError: String?
    /// Last submitted query (trimmed; retry re-runs it).
    public private(set) var lastQuery = ""

    /// Graph's per-request result cap (core clamps larger limits to this).
    public nonisolated static let pageSize: Int32 = 25

    private let fileSearcher: FileSearcher
    private let peopleSearcher: PeopleSearcher
    private var generation = 0

    /// Names the conversation a file hit was shared in (core-b): Graph
    /// drive search reports no chat/channel, so AppState resolves hits
    /// against the Files index (`UnifiedFilesStore.resolveSource`).
    /// Nil = hits pass through unchanged.
    public var sourceResolver: (@MainActor (SharedFile) -> SharedFile)?

    public init(
        fileSearcher: @escaping FileSearcher = { query, limit in
            try RustCore.fileSearch(query: query, limit: limit)
        },
        peopleSearcher: @escaping PeopleSearcher = { query, limit in
            try RustCore.peopleSearch(query: query, limit: limit)
        }
    ) {
        self.fileSearcher = fileSearcher
        self.peopleSearcher = peopleSearcher
    }

    /// Fresh search for both sections; replaces rows. Blank queries clear
    /// without touching core. Stale completions are dropped, so fast
    /// typing always lands on the newest query. A section failure keeps
    /// the other section's rows with the error surfaced beside them.
    public func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        guard !q.isEmpty else {
            files = []
            people = []
            isSearching = false
            fileError = nil
            peopleError = nil
            lastQuery = ""
            return
        }
        lastQuery = q
        isSearching = true
        fileError = nil
        peopleError = nil
        let fileSearcher = fileSearcher
        let peopleSearcher = peopleSearcher
        // One detached hop for both blocking FFI calls (sequential:
        // two Graph windows, still off-main).
        let result = await Task.detached { () -> (
            Result<[SharedFile], Error>, Result<[TeamMember], Error>
        ) in
            let f: Result<[SharedFile], Error>
            do {
                f = .success(try fileSearcher(q, Self.pageSize).files)
            } catch {
                f = .failure(error)
            }
            let p: Result<[TeamMember], Error>
            do {
                p = .success(try peopleSearcher(q, Self.pageSize).people)
            } catch {
                p = .failure(error)
            }
            return (f, p)
        }.value
        guard gen == generation else { return } // superseded
        switch result.0 {
        case .success(let rows):
            files = sourceResolver.map { resolve in rows.map(resolve) } ?? rows
            fileError = nil
        case .failure(let error):
            files = []
            fileError = Self.message(for: error)
        }
        switch result.1 {
        case .success(let rows):
            people = rows
            peopleError = nil
        case .failure(let error):
            people = []
            peopleError = Self.message(for: error)
        }
        isSearching = false
    }

    /// Re-run the last query (error-state Try Again). No-op without one.
    public func retry() {
        guard !lastQuery.isEmpty else { return }
        Task { await search(query: lastQuery) }
    }

    /// Drop the query + rows (sheet dismiss, blank query).
    public func clear() {
        generation += 1
        files = []
        people = []
        isSearching = false
        fileError = nil
        peopleError = nil
        lastQuery = ""
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
