// LocalSearchStore.swift — d2-archive lane: offline full-text message search.
//
// Mirrors MessageSearchStore's query/paging shape (hits/total/more,
// search/loadMore/retry/clear, pageSize 25) but indexes ChatMessages on-device
// and never touches the network: there is no searcher property and no
// RustCore reference anywhere in this file (offline by construction).
//
// Index persistence rides ArchiveCodec (same codec as archives, no second
// codec): magic "OMIX" | version UInt16 | codecID UInt32 | compLen UInt32 |
// uncompLen UInt32 | compBytes. Payload is sorted-keys JSON of the snapshot.
import Foundation

/// One indexed document (archived or live — both index identically).
struct IndexedDoc: Codable, Sendable, Equatable {
    let chatID: String
    let teamID: String?
    let channelID: String?
    let messageID: String
    let sender: String
    let timestamp: String
    let content: String
}

struct SearchSnapshot: Codable {
    var docs: [String: IndexedDoc] = [:]
    var postings: [String: [String]] = [:]
}

public enum LocalSearchError: Error, Equatable, Sendable {
    case io(String)
    case badMagic
    case badVersion(UInt16)
    case corrupt(String)
    case codec(ArchiveCodecError)
}

/// Offline message search over locally indexed threads.
@MainActor
public final class LocalSearchStore: ObservableObject {
    /// Ranked hits for the last submitted query (current page window).
    @Published public private(set) var hits: [SearchHit] = []
    /// Local search is synchronous; kept for MessageSearchStore parity.
    @Published public private(set) var isSearching = false
    /// Last failure (nil when clear). Local failures are rare (bad persist).
    @Published public private(set) var error: String?
    /// Total matches across all pages, when a query is active.
    @Published public private(set) var total: Int?
    /// True while another page exists.
    @Published public private(set) var more = false
    /// Cursor for the next page; nil = exhausted.
    public private(set) var nextFrom: Int?
    /// Last submitted query (trimmed; retry re-runs it).
    public private(set) var lastQuery = ""
    /// Wall ms of the last synchronous query run (gap-g6g7: the
    /// airplane-mode <200ms accept reads this; nil before any query).
    @Published public private(set) var lastQueryMs: Double?

    /// Page size matches server search so callers can swap stores.
    public nonisolated static let pageSize: Int32 = 25
    /// Preview length for locally built hits.
    public nonisolated static let previewLength = 120

    static let magic = Data([0x4F, 0x4D, 0x49, 0x58]) // "OMIX"
    static let persistVersion: UInt16 = 1

    private var snapshot = SearchSnapshot()
    /// Ranked doc keys for the active query (paging slices this).
    private var rankedKeys: [String] = []

    public init() {}

    /// Documents currently indexed.
    public var docCount: Int { snapshot.docs.count }

    /// Posting-list length for one token (tests: re-index must not duplicate).
    func snapshotPostingCount(for token: String) -> Int {
        snapshot.postings[token]?.count ?? 0
    }

    // MARK: - Tokenize

    /// Lowercase alphanumeric tokens. Non-ASCII letters split (western
    /// corpora; CJK n-grams explicitly out of scope for this lane).
    public nonisolated static func tokenize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    // MARK: - Index

    static func docKey(chatID: String, messageID: String) -> String {
        "\(chatID)\n\(messageID)"
    }

    /// Merge messages into the index (re-indexing a doc replaces it).
    /// Archived (decoded) and live messages index identically.
    public func index(
        chatID: String, teamID: String? = nil, channelID: String? = nil,
        messages: [ChatMessage]
    ) {
        for m in messages {
            let key = Self.docKey(chatID: chatID, messageID: m.id)
            // Re-index: unlink the old doc's postings first so an edited
            // message neither duplicates keys nor stays findable by stale words.
            if let old = snapshot.docs[key] {
                for tok in Set(Self.tokenize("\(old.sender) \(old.content)")) {
                    snapshot.postings[tok]?.removeAll(where: { $0 == key })
                    if snapshot.postings[tok]?.isEmpty == true {
                        snapshot.postings.removeValue(forKey: tok)
                    }
                }
            }
            snapshot.docs[key] = IndexedDoc(
                chatID: chatID, teamID: teamID, channelID: channelID,
                messageID: m.id, sender: m.sender,
                timestamp: m.timestamp, content: m.content)
            var seen = Set<String>()
            for tok in Self.tokenize("\(m.sender) \(m.content)") {
                guard seen.insert(tok).inserted else { continue }
                snapshot.postings[tok, default: []].append(key)
            }
        }
        // Re-indexing invalidates the active window; re-run if one exists.
        if !lastQuery.isEmpty {
            runQuery(lastQuery)
        }
    }

    /// Drop one doc (local delete); unknown keys are a no-op.
    public func remove(chatID: String, messageID: String) {
        let key = Self.docKey(chatID: chatID, messageID: messageID)
        guard snapshot.docs.removeValue(forKey: key) != nil else { return }
        for tok in snapshot.postings.keys {
            snapshot.postings[tok]?.removeAll(where: { $0 == key })
            if snapshot.postings[tok]?.isEmpty == true {
                snapshot.postings.removeValue(forKey: tok)
            }
        }
        if !lastQuery.isEmpty {
            runQuery(lastQuery)
        }
    }

    /// DEMOLEAK: drop docs an old demo run indexed into the account's
    /// real index (demo fixture chat/message ids). Returns the count;
    /// the next regular save persists the clean index.
    @discardableResult
    public func removeFixtureDocs() -> Int {
        let bad = Set(snapshot.docs.compactMap { key, doc in
            DemoFixture.isFixtureID(doc.chatID) || DemoFixture.isFixtureID(doc.messageID) ? key : nil
        })
        guard !bad.isEmpty else { return 0 }
        for key in bad { snapshot.docs.removeValue(forKey: key) }
        for (tok, keys) in snapshot.postings {
            let kept = keys.filter { !bad.contains($0) }
            if kept.isEmpty {
                snapshot.postings.removeValue(forKey: tok)
            } else if kept.count != keys.count {
                snapshot.postings[tok] = kept
            }
        }
        if !lastQuery.isEmpty { runQuery(lastQuery) }
        return bad.count
    }

    // MARK: - Query (MessageSearchStore shape)

    /// Fresh search; replaces hits. Blank queries clear without indexing work.
    /// Multi-term queries AND; each term prefix-matches indexed tokens.
    public func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        error = nil
        defer { isSearching = false }
        guard !q.isEmpty else {
            clear()
            return
        }
        lastQuery = q
        runQuery(q)
    }

    /// Ranked full match list for `query` (no paging). Pure over the index.
    func allMatches(for query: String) -> [String] {
        let terms = Self.tokenize(query)
        guard !terms.isEmpty else { return [] }
        // Candidate keys per term (prefix expansion), then AND.
        var perTerm: [Set<String>] = []
        perTerm.reserveCapacity(terms.count)
        for term in terms {
            var keys = Set<String>()
            for (tok, list) in snapshot.postings where tok.hasPrefix(term) {
                keys.formUnion(list)
            }
            if keys.isEmpty { return [] } // one term unmatched => AND is empty
            perTerm.append(keys)
        }
        var joint = perTerm[0]
        for s in perTerm.dropFirst() { joint.formIntersection(s) }
        if joint.isEmpty { return [] }
        // Rank: exact-token hits beat prefix hits; then newest first.
        func score(_ key: String) -> Int {
            guard let doc = snapshot.docs[key] else { return 0 }
            let toks = Set(Self.tokenize("\(doc.sender) \(doc.content)"))
            var s = 0
            for term in terms {
                if toks.contains(term) { s += 2 } else { s += 1 }
            }
            return s
        }
        return joint.sorted { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa > sb }
            let ta = snapshot.docs[a]?.timestamp ?? ""
            let tb = snapshot.docs[b]?.timestamp ?? ""
            if ta != tb { return ta > tb }
            return a < b
        }
    }

    /// Every indexed message of one conversation matching `query`,
    /// newest first, not paged (⌘F find in a conversation, UI-SPEC §5.5).
    /// Case- and diacritic-insensitive ("the" finds "The", "cafe" finds
    /// "Café"); each term prefix-matches a word, terms AND. Scoped here,
    /// not by filtering a global window afterwards: a common word fills
    /// the first 25 global hits with other chats and drops this one's.
    public func hits(matching query: String, inChat chatID: String) -> [SearchHit] {
        let terms = Self.tokenize(query).map(Self.fold)
        guard !terms.isEmpty, !chatID.isEmpty else { return [] }
        let prefix = Self.docKey(chatID: chatID, messageID: "")
        return snapshot.docs
            .filter { key, doc in
                guard key.hasPrefix(prefix) else { return false }
                let words = Self.tokenize("\(doc.sender) \(doc.content)").map(Self.fold)
                return terms.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
            }
            .sorted { a, b in
                a.value.timestamp != b.value.timestamp ? a.value.timestamp > b.value.timestamp : a.key < b.key
            }
            .compactMap { hit(for: $0.key) }
    }

    nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private func runQuery(_ query: String) {
        let t0 = CFAbsoluteTimeGetCurrent()
        rankedKeys = allMatches(for: query)
        total = rankedKeys.count
        applyWindow(from: 0)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lastQueryMs = ms
        print(String(
            format: "[local-search] %d hits in %.1fms (docs %d)",
            rankedKeys.count, ms, snapshot.docs.count))
    }

    private func applyWindow(from: Int) {
        let size = Int(Self.pageSize)
        let page = Array(rankedKeys.dropFirst(from).prefix(size))
        hits = page.compactMap(hit(for:))
        let consumed = from + page.count
        if consumed < rankedKeys.count {
            more = true
            nextFrom = consumed
        } else {
            more = false
            nextFrom = nil
        }
    }

    private func hit(for key: String) -> SearchHit? {
        guard let doc = snapshot.docs[key] else { return nil }
        return SearchHit(
            messageID: doc.messageID, chatID: doc.chatID,
            teamID: doc.teamID, channelID: doc.channelID,
            sender: doc.sender, timestamp: doc.timestamp,
            preview: String(doc.content.prefix(Self.previewLength)))
    }

    /// True while the next page exists and no search is running.
    public var canLoadMore: Bool {
        more && nextFrom != nil && !isSearching
    }

    /// Append the next page. No-op without a cursor.
    public func loadMore() async {
        guard canLoadMore, let cursor = nextFrom else { return }
        let size = Int(Self.pageSize)
        let page = Array(rankedKeys.dropFirst(cursor).prefix(size))
            .compactMap { hit(for: $0) }
        hits = MessageSearchStore.merged(hits, page)
        let consumed = cursor + page.count
        if consumed < rankedKeys.count {
            more = true
            nextFrom = consumed
        } else {
            more = false
            nextFrom = nil
        }
    }

    /// Re-run the last query. No-op without one.
    public func retry() {
        guard !lastQuery.isEmpty else { return }
        Task { await search(query: lastQuery) }
    }

    /// Drop the query + hits (index itself is untouched).
    public func clear() {
        hits = []
        isSearching = false
        error = nil
        total = nil
        more = false
        nextFrom = nil
        lastQuery = ""
        rankedKeys = []
    }

    // MARK: - Persistence (ArchiveCodec, single frame)

    /// `<appSupport>/<AppIdentity.name>/search-index[.acct].omix`
    /// (gap-g6g7: the relaunch-persist path; nil only when appSupport
    /// is missing). Per-account files (default keeps the legacy name)
    /// so one account's threads never surface in another's search.
    public nonisolated static func defaultIndexURL(
        for accountID: String = AccountProfile.defaultID
    ) -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let leaf = accountID == AccountProfile.defaultID
            ? "search-index.omix"
            : "search-index.\(AccountProfile.sanitized(accountID)).omix"
        return base.appendingPathComponent(
            "\(AppIdentity.name)/\(leaf)", isDirectory: false)
    }

    /// Load the default index when present; missing file = empty index
    /// (fresh install), corrupt file = thrown for Diagnostics surfacing.
    public func loadDefault(for accountID: String = AccountProfile.defaultID) throws {
        guard let url = Self.defaultIndexURL(for: accountID) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try load(from: url)
    }

    /// Save to the default index path (creating the dir as needed).
    public func saveDefault(for accountID: String = AccountProfile.defaultID) throws {
        guard let url = Self.defaultIndexURL(for: accountID) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try save(to: url)
    }

    /// Drop the whole index + query state (account switch re-points at
    /// another account's file; the store identity is stable).
    public func removeAll() {
        snapshot = SearchSnapshot()
        clear()
    }

    // MARK: - Rebuild (Settings ▸ Advanced ▸ Rebuild Index)

    /// One chat's or channel's locally stored messages (a rebuild source).
    public struct CachedThread: Sendable, Equatable {
        public let chatID: String
        public let teamID: String?
        public let channelID: String?
        public var messages: [ChatMessage]

        public init(chatID: String, teamID: String? = nil, channelID: String? = nil, messages: [ChatMessage]) {
            self.chatID = chatID
            self.teamID = teamID
            self.channelID = channelID
            self.messages = messages
        }
    }

    /// Every indexed doc, grouped per chat (sorted by chat id; messages
    /// by timestamp) — the on-device message store a rebuild walks.
    public func cachedThreads() -> [CachedThread] {
        var byChat: [String: [IndexedDoc]] = [:]
        for d in snapshot.docs.values { byChat[d.chatID, default: []].append(d) }
        return byChat.keys.sorted().map { chatID in
            let docs = byChat[chatID, default: []].sorted {
                ($0.timestamp, $0.messageID) < ($1.timestamp, $1.messageID)
            }
            return CachedThread(
                chatID: chatID, teamID: docs.first?.teamID, channelID: docs.first?.channelID,
                messages: docs.map {
                    ChatMessage(id: $0.messageID, sender: $0.sender, timestamp: $0.timestamp, content: $0.content)
                })
        }
    }

    /// Take `other`'s index wholesale (a finished rebuild swaps in); an
    /// active query re-runs against it.
    public func adopt(_ other: LocalSearchStore) {
        snapshot = other.snapshot
        rankedKeys = []
        if !lastQuery.isEmpty {
            runQuery(lastQuery)
        }
    }

    /// Write the index snapshot to `url` (overwritten).
    public func save(to url: URL) throws {
        let codec = ArchiveCodec.resolve(ArchiveCodec.defaultCodec)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain: Data
        do {
            plain = try encoder.encode(snapshot)
        } catch {
            throw LocalSearchError.io("encode snapshot: \(error)")
        }
        let comp: Data
        do {
            comp = try ArchiveCodec.encode(plain, codec: codec)
        } catch let e as ArchiveCodecError {
            throw LocalSearchError.codec(e)
        }
        var out = Data()
        out.append(Self.magic)
        ArchiveIO.putU16(Self.persistVersion, into: &out)
        ArchiveIO.putU32(codec.rawValue, into: &out)
        ArchiveIO.putU32(UInt32(comp.count), into: &out)
        ArchiveIO.putU32(UInt32(plain.count), into: &out)
        out.append(comp)
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            throw LocalSearchError.io("write \(url.path): \(error)")
        }
    }

    /// Replace the index with the snapshot at `url`.
    public func load(from url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LocalSearchError.io("read \(url.path): \(error)")
        }
        guard data.count >= 18, data.prefix(4) == Self.magic else {
            throw LocalSearchError.badMagic
        }
        let ver = ArchiveIO.getU16(data, at: 4)
        guard ver == Self.persistVersion else { throw LocalSearchError.badVersion(ver) }
        let codecRaw = ArchiveIO.getU32(data, at: 6)
        let compLen = Int(ArchiveIO.getU32(data, at: 10))
        let uncompLen = Int(ArchiveIO.getU32(data, at: 14))
        guard let codec = ArchiveCodecID(rawValue: codecRaw) else {
            throw LocalSearchError.corrupt("unknown codec 0x\(String(codecRaw, radix: 16))")
        }
        guard data.count == 18 + compLen else {
            throw LocalSearchError.corrupt("size \(data.count), expected \(18 + compLen)")
        }
        let plain: Data
        do {
            plain = try ArchiveCodec.decode(data[18...], codec: codec, expectedSize: uncompLen)
        } catch let e as ArchiveCodecError {
            throw LocalSearchError.codec(e)
        }
        do {
            snapshot = try JSONDecoder().decode(SearchSnapshot.self, from: plain)
        } catch {
            throw LocalSearchError.corrupt("bad snapshot JSON: \(error)")
        }
        clear()
    }
}
