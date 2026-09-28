// SearchRecentsStore.swift — gap-g6g7 lane: sticky palette search memory.
//
// Persists the jump palette's Messages-scope memory in UserDefaults:
// the last 5 submitted queries (newest first), the scope chip, and the
// last query text. The palette restores scope + query on reopen and
// offers recents as one-tap rows under a blank query (with a Clear
// control). CallHistoryStore precedent (injectable defaults + keys).
import Foundation

/// Palette search memory: recents + sticky scope + last query.
@MainActor
public final class SearchRecentsStore: ObservableObject {
    /// Newest first. Published so the palette's recents section updates.
    @Published public private(set) var recents: [String] = []
    /// Last scope chip ("chats" or "messages"; see `JumpPaletteScope`).
    @Published public private(set) var lastScope = "chats"
    /// Last non-blank query text (restored into the field on reopen).
    @Published public private(set) var lastQuery = ""

    public nonisolated static let recentsKey = "omSearchRecentsV1"
    public nonisolated static let scopeKey = "omSearchScopeV1"
    public nonisolated static let queryKey = "omSearchLastQueryV1"
    /// G7 accept: 5 persisted recent searches.
    public static let maxRecents = 5

    /// Backing defaults; nil = memory-only (demo: never the real recents).
    private let defaults: UserDefaults?
    private let recentsKey: String
    private let scopeKey: String
    private let queryKey: String

    public init(
        defaults: UserDefaults? = .standard,
        recentsKey: String = SearchRecentsStore.recentsKey,
        scopeKey: String = SearchRecentsStore.scopeKey,
        queryKey: String = SearchRecentsStore.queryKey
    ) {
        self.defaults = defaults
        self.recentsKey = recentsKey
        self.scopeKey = scopeKey
        self.queryKey = queryKey
        if let loaded = defaults?.stringArray(forKey: recentsKey) {
            recents = Array(loaded.prefix(Self.maxRecents))
        }
        if let scope = defaults?.string(forKey: scopeKey), !scope.isEmpty {
            lastScope = scope
        }
        lastQuery = defaults?.string(forKey: queryKey) ?? ""
    }

    /// Record a submitted query: trimmed, blank dropped, newest first,
    /// case-insensitive dedupe (newest casing wins), capped at 5.
    /// Also sticks it as the last query.
    public func record(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        noteQuery(q)
        var next = [q]
        for r in recents where r.caseInsensitiveCompare(q) != .orderedSame {
            next.append(r)
        }
        recents = Array(next.prefix(Self.maxRecents))
        defaults?.set(recents, forKey: recentsKey)
    }

    /// Demo seed (in-memory stores only): canned recents, newest first.
    public func seedDemo(_ queries: [String]) {
        recents = Array(queries.prefix(Self.maxRecents))
    }

    /// Drop all recents (the palette's Clear control). Scope + last
    /// query are untouched.
    public func clearRecents() {
        recents = []
        defaults?.set([], forKey: recentsKey)
    }

    /// Stick the scope chip ("chats"/"messages"; anything else ignored).
    public func noteScope(_ scope: String) {
        guard scope == "chats" || scope == "messages" else { return }
        lastScope = scope
        defaults?.set(scope, forKey: scopeKey)
    }

    /// Stick the last query text (blank clears the restore).
    public func noteQuery(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = q
        defaults?.set(q, forKey: queryKey)
    }
}
