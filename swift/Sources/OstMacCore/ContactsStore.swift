// ContactsStore.swift — om-f2-contacts lane: directory search + speed dial.
//
// INPUT API (what the contacts browser drives):
//   store.search(query:)   — fresh directory search (replaces rows)
//   store.retry()           — re-run the last query (error-state Try Again)
//   store.clear()           — drop query + rows (blank query, pins kept)
//   store.pin(_:)           — pin a contact to speed dial (persisted)
//   store.unpin(_:)         — unpin (the directory row is untouched)
//   store.refreshPresence() — refill dots for visible rows via PresenceStore
import Foundation

/// Directory search + speed-dial pins. Zero new FFI: search rides the
/// `FilePeopleSearchStore.PeopleSearcher` seam (`people_search`), dots
/// ride the host's `PresenceStore` (`user_presence`), and row taps ride
/// `openSearchPerson` (`chat_create_one_to_one`) — this store never
/// creates chats itself.
///
/// Follows the om-ja-search store pattern: the default searcher calls
/// the blocking FFI on a detached task, a generation guard drops stale
/// completions, and blank queries clear without touching core. Tests
/// inject mock searchers + a mock-fetcher PresenceStore.
///
/// Pins persist as ref strings (AAD id else email — the
/// `PersonChat.userRef` rule) in UserDefaults (suite-injectable for
/// tests — UserPinStore precedent). Contact *details* are never
/// persisted: an in-memory `known` map (filled from search hits)
/// resolves pins to rows, and pins without known details degrade to
/// the raw ref + unknown dot (never a blank row).
@MainActor
public final class ContactsStore: ObservableObject {
    /// Sync people search (runs off-main). Throws `CoreCallError` on failure.
    /// Same seam as `FilePeopleSearchStore.PeopleSearcher`.
    public typealias PeopleSearcher = FilePeopleSearchStore.PeopleSearcher

    /// True when a ref can be pinned: a non-blank id (same rule as
    /// `PinnedChats.isPinnable`, restated here — that enum lives in
    /// OstMacChatList, which depends on this module).
    public nonisolated static func isPinnable(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// UserDefaults key for the ordered pin array.
    public nonisolated static let pinDefaultsKey = "omContactPinsV1"
    /// Per-account key (d1-accounts): default keeps the legacy key.
    nonisolated public static func pinKey(for accountID: String) -> String {
        AccountProfile.key(pinDefaultsKey, for: accountID)
    }

    /// Directory hits for the last submitted query (server-ranked,
    /// unfiltered — stable identities, never reordered by dots).
    @Published public private(set) var results: [TeamMember] = []
    /// Search in flight.
    @Published public private(set) var isSearching = false
    /// Last search failure (nil when clear).
    @Published public private(set) var error: String?
    /// Last submitted query (trimmed; retry re-runs it).
    public private(set) var lastQuery = ""
    /// Pinned refs, oldest pin first. Sanitized on load (blanks and
    /// dupes dropped, first occurrence kept). Never pruned — a pin
    /// whose details are unknown still renders (degraded).
    @Published public private(set) var pinnedIDs: [String] = []

    /// Presence source for row dots (host-wired; nil in bare tests).
    /// Weak — the app owns the store.
    public weak var presence: PresenceStore?

    /// Seen hits by pin ref (session-only; fills from every search).
    private var known: [String: TeamMember] = [:]

    private let peopleSearcher: PeopleSearcher
    private let defaults: UserDefaults
    private let pinKey: String
    private var generation = 0

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        peopleSearcher: @escaping PeopleSearcher = { query, limit in
            try RustCore.peopleSearch(query: query, limit: limit)
        },
        defaults: UserDefaults = .standard,
        pinKey: String = ContactsStore.pinDefaultsKey
    ) {
        self.peopleSearcher = peopleSearcher
        self.defaults = defaults
        self.pinKey = pinKey
        var seen = Set<String>()
        var clean: [String] = []
        for id in defaults.stringArray(forKey: pinKey) ?? [] {
            guard Self.isPinnable(id) else { continue }
            guard seen.insert(id).inserted else { continue }
            clean.append(id)
        }
        _results = Published(initialValue: [])
        _isSearching = Published(initialValue: false)
        _error = Published(initialValue: nil)
        _pinnedIDs = Published(initialValue: clean)
    }

    // MARK: - Search

    /// Fresh directory search; replaces rows. Blank queries clear
    /// without touching core (pins are kept). Stale completions are
    /// dropped, so fast typing always lands on the newest query.
    /// Success refills presence dots for the visible rows.
    public func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let gen = generation
        guard !q.isEmpty else {
            results = []
            isSearching = false
            error = nil
            lastQuery = ""
            return
        }
        lastQuery = q
        isSearching = true
        error = nil
        let searcher = peopleSearcher
        let result: Result<[TeamMember], Error> = await Task.detached {
            do {
                return try .success(searcher(q, FilePeopleSearchStore.pageSize).people)
            } catch {
                return .failure(error)
            }
        }.value
        guard gen == generation else { return } // superseded
        switch result {
        case .success(let rows):
            results = rows
            error = nil
            learn(rows)
            await refreshPresence()
        case .failure(let err):
            results = []
            error = Self.message(for: err)
        }
        isSearching = false
    }

    /// Re-run the last query (error-state Try Again). No-op without one.
    public func retry() {
        guard !lastQuery.isEmpty else { return }
        Task { await search(query: lastQuery) }
    }

    /// Drop the query + rows (blank query). Pins and known details stay.
    public func clear() {
        generation += 1
        results = []
        isSearching = false
        error = nil
        lastQuery = ""
    }

    /// Adopt rows without core (tests, previews, demo shots).
    public func adopt(_ people: [TeamMember]) {
        results = people
        error = nil
        learn(people)
    }

    // MARK: - Speed dial

    /// Pin ref for one hit: the shared person11 rule (AAD id else
    /// email; nil when both are blank — such hits can't pin).
    public nonisolated static func pinID(for person: TeamMember) -> String? {
        PersonChat.userRef(for: person)
    }

    /// True when the contact is currently pinned.
    public func isPinned(_ person: TeamMember) -> Bool {
        guard let ref = Self.pinID(for: person) else { return false }
        return pinnedIDs.contains(ref)
    }

    /// Pin a contact (appends — the newest pin renders last in speed
    /// dial). Ref-less hits and re-pins are no-ops (no reorder, no
    /// write). Pinning never touches the directory or the dots.
    public func pin(_ person: TeamMember) {
        guard let ref = Self.pinID(for: person) else { return }
        guard Self.isPinnable(ref) else { return }
        guard !pinnedIDs.contains(ref) else { return }
        pinnedIDs.append(ref)
        learn([person])
        savePins()
    }

    /// Unpin by hit (the row returns to the results; the directory is
    /// untouched). Unknown refs are a no-op (no write).
    public func unpin(_ person: TeamMember) {
        guard let ref = Self.pinID(for: person) else { return }
        unpin(ref: ref)
    }

    /// Unpin by raw ref (degraded pinned rows carry no hit).
    public func unpin(ref: String) {
        guard let i = pinnedIDs.firstIndex(of: ref) else { return }
        pinnedIDs.remove(at: i)
        savePins()
    }

    /// Reorder speed dial (List `onMove` offsets). Persists the new
    /// order; an empty or no-op move writes nothing.
    public func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }
        let moving = source.filter { $0 < pinnedIDs.count }.map { pinnedIDs[$0] }
        var next = pinnedIDs.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let at = destination - source.filter { $0 < destination }.count
        next.insert(contentsOf: moving, at: max(0, min(at, next.count)))
        guard next != pinnedIDs else { return }
        pinnedIDs = next
        savePins()
    }

    /// Speed-dial rows in pin-time order: pins resolved through known
    /// details, unknown pins degraded to the raw ref (never blank).
    public func pinnedContacts() -> [TeamMember] {
        pinnedIDs.map { known[$0] ?? Self.fallbackPerson(for: $0) }
    }

    /// Degraded row for a pin without known details: the ref as the
    /// name, re-attached as user id or email (`@` heuristic — pin refs
    /// come from `userRef`, which emits exactly those two forms) so
    /// taps still reach the person11 path. Pure helper.
    public nonisolated static func fallbackPerson(for pinID: String) -> TeamMember {
        if pinID.contains("@") {
            return TeamMember(id: pinID, displayName: pinID, email: pinID)
        }
        return TeamMember(id: pinID, displayName: pinID, userId: pinID)
    }

    // MARK: - Presence

    /// Refs needing dots: pinned + visible results, deduped, capped to
    /// the 25-row Graph window (never fetch off-screen hits).
    public func presenceIDs() -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        ids.reserveCapacity(Int(FilePeopleSearchStore.pageSize))
        for person in pinnedContacts() + results {
            guard ids.count < Int(FilePeopleSearchStore.pageSize) else { break }
            guard let ref = Self.pinID(for: person) else { continue }
            guard seen.insert(ref).inserted else { continue }
            ids.append(ref)
        }
        return ids
    }

    /// Refill dots for the visible rows. Nil presence is a no-op;
    /// per-id failure is non-critical inside `refreshPeers` (stale
    /// dots kept, unknown ids stay hollow).
    public func refreshPresence() async {
        guard let presence else { return }
        await presence.refreshPeers(ids: presenceIDs())
    }

    // MARK: - Private

    private func learn(_ people: [TeamMember]) {
        for person in people {
            guard let ref = Self.pinID(for: person) else { continue }
            known[ref] = person
        }
    }

    private func savePins() {
        defaults.set(pinnedIDs, forKey: pinKey)
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
