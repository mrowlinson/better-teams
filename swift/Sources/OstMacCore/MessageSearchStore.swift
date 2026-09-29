// MessageSearchStore.swift — om-ja-search lane: Graph MESSAGE search state.
//
// INPUT API (what the jump palette drives):
//   store.search(query:) — fresh search from window 0 (replaces hits)
//   store.loadMore()     — append the next window via next_from (deduped)
//   store.retry()        — re-run the last query (error-state Try Again)
//   store.clear()        — drop query + hits (blank query, scope switch)
import Foundation

/// Where the current hits came from (gap-g6g7: palette source badge).
public enum SearchSource: String, Sendable, Equatable {
    case none
    case online
    case offline
    case mixed
}

/// Searches Teams messages via ostmac-core and pages the windows.
///
/// Default searcher calls `RustCore.search` (blocking FFI + network) on a
/// detached task. Tests inject a mock searcher.
///
/// Offline-first (gap-g6g7): when `local` is attached, every search runs
/// the on-device index synchronously first (instant local hits while the
/// server window is on its way, timed in `offlineMs`). Online, the server
/// window then REPLACES them: the offline index merges only when offline
/// (UI-SPEC §5.5). A network failure with local hits keeps the local hits
/// (`source == .offline`, no error); without local hits the error
/// surfaces as before. No `local` attached = legacy online-only behavior.
@MainActor
public final class MessageSearchStore: ObservableObject {
    /// Sync search (runs off-main). Throws `CoreCallError` on core failure.
    public typealias Searcher = @Sendable (String, Int32, Int32) throws -> SearchResponse

    /// Server-ranked hits for the last submitted query (no client filter).
    @Published public private(set) var hits: [SearchHit] = []
    /// Fresh search in flight.
    @Published public private(set) var isSearching = false
    /// Next-window fetch in flight.
    @Published public private(set) var loadingMore = false
    /// Last failure (nil when clear).
    @Published public private(set) var error: String?
    /// Server total, when reported.
    @Published public private(set) var total: Int?
    /// True while another window exists.
    @Published public private(set) var more = false
    /// Cursor for the next window; nil = exhausted.
    public private(set) var nextFrom: Int?
    /// Last submitted query (trimmed; retry re-runs it).
    public private(set) var lastQuery = ""
    /// Hit provenance for the palette source badge.
    @Published public private(set) var source: SearchSource = .none
    /// Ids of hits the server returned (additive, P2b fixes): the rest
    /// came from the on-device index only ("On This Mac" row badge; only
    /// the interim local pass and the network-failure fallback have any).
    @Published public private(set) var onlineIDs: Set<String> = []
    /// Wall ms of the synchronous local-index pass (nil = no local
    /// attached, or blank query). Mirrors `LocalSearchStore.lastQueryMs`.
    @Published public private(set) var offlineMs: Double?

    /// Graph's per-request hit cap (core clamps larger sizes to this).
    public nonisolated static let pageSize: Int32 = 25

    /// Attached on-device index (AppState owns both halves). Nil =
    /// online-only (legacy behavior, all legacy tests).
    public var local: LocalSearchStore?

    private let searcher: Searcher
    private var generation = 0

    public init(
        searcher: @escaping Searcher = { query, from, size in
            try RustCore.search(query: query, from: from, size: size)
        }
    ) {
        self.searcher = searcher
    }

    /// Fresh search from window 0; replaces hits. Blank queries clear
    /// without touching core. Stale completions are dropped, so fast
    /// typing always lands on the newest query. With `local` attached,
    /// the local pass runs first (hits visible instantly), then online
    /// merges above the offline-only extras.
    public func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        guard !q.isEmpty else {
            hits = []
            isSearching = false
            loadingMore = false
            error = nil
            total = nil
            more = false
            nextFrom = nil
            lastQuery = ""
            source = .none
            onlineIDs = []
            offlineMs = nil
            local?.clear()
            return
        }
        lastQuery = q
        isSearching = true
        loadingMore = false
        error = nil
        // Offline-first pass (synchronous, instant): local hits show
        // immediately, then the online window merges above them.
        var localHits: [SearchHit] = []
        if let local {
            await local.search(query: q)
            guard gen == generation else { return } // superseded
            localHits = local.hits
            offlineMs = local.lastQueryMs
            // An empty local pass never clears the rows on screen: the
            // previous results stay (under "Searching online…") until
            // the server window replaces them — no spinner flash per
            // keystroke.
            if !(localHits.isEmpty && !hits.isEmpty) {
                hits = localHits
                total = local.total
                more = false
                nextFrom = nil
                source = localHits.isEmpty ? .none : .offline
                onlineIDs = []
            }
        } else {
            offlineMs = nil
        }
        let searcher = searcher
        do {
            let response = try await Task.blocking {
                try searcher(q, 0, Self.pageSize)
            }.value
            guard gen == generation else { return } // superseded
            // Online: server results only; the local pass was the
            // interim list (§5.5 merges the offline index only offline).
            onlineIDs = Set(response.hits.map(\.id))
            hits = response.hits
            total = response.total
            source = local != nil && response.hits.isEmpty ? .none : .online
            more = response.more
            nextFrom = response.next_from
            isSearching = false
        } catch {
            guard gen == generation else { return } // superseded
            isSearching = false
            onlineIDs = []
            if !localHits.isEmpty {
                // Airplane mode: local hits stand, no error banner.
                hits = localHits
                total = local?.total
                more = false
                nextFrom = nil
                source = .offline
            } else {
                hits = []
                total = nil
                more = false
                nextFrom = nil
                source = .none
                self.error = Self.message(for: error)
            }
        }
    }

    /// True while the next window exists and no fetch is in flight.
    public var canLoadMore: Bool {
        more && nextFrom != nil && !isSearching && !loadingMore
    }

    /// Append the next window (overlap deduped by row id). No-op without
    /// a cursor or while a fetch is in flight. A mid-chain failure keeps
    /// the loaded hits with the error surfaced and the cursor intact —
    /// tapping again retries the same window.
    public func loadMore() async {
        guard canLoadMore, let cursor = nextFrom else { return }
        loadingMore = true
        error = nil
        let gen = generation
        let query = lastQuery
        let searcher = searcher
        do {
            let response = try await Task.blocking {
                try searcher(query, Int32(cursor), Self.pageSize)
            }.value
            guard gen == generation else { return } // superseded
            hits = Self.merged(hits, response.hits)
            onlineIDs.formUnion(response.hits.map(\.id))
            total = response.total
            more = response.more
            nextFrom = response.next_from
            loadingMore = false
        } catch {
            guard gen == generation else { return } // superseded
            loadingMore = false
            self.error = Self.message(for: error)
        }
    }

    /// Re-run the last query (empty-state Try Again). No-op without one.
    public func retry() {
        guard !lastQuery.isEmpty else { return }
        Task { await search(query: lastQuery) }
    }

    /// Drop the query + hits (scope switch back to chats).
    public func clear() {
        generation += 1
        hits = []
        isSearching = false
        loadingMore = false
        error = nil
        total = nil
        more = false
        nextFrom = nil
        lastQuery = ""
        source = .none
        onlineIDs = []
        offlineMs = nil
        local?.clear()
    }

    /// Pure append: new windows first, existing ids win on overlap.
    public nonisolated static func merged(_ old: [SearchHit], _ new: [SearchHit]) -> [SearchHit] {
        let known = Set(old.map(\.id))
        return old + new.filter { !known.contains($0.id) }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
