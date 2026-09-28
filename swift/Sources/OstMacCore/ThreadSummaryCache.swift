// ThreadSummaryCache.swift — d1-summaries lane: memory-only per-thread
// summary cache for the on-device provider.
//
// Key = chatID + newest-message id + count + content fingerprint.
// Any new message or edit changes the key (miss); a chat switch
// changes chatID (miss = effective reset, no explicit clear needed).
// Cloud/CLI providers never consult this cache (out of scope).
public struct ThreadSummaryCache: Sendable {
    /// Max threads remembered; oldest evicted first (LRU).
    public static let capacity = 20

    public struct Key: Equatable, Sendable {
        public let chatID: String?
        public let count: Int
        public let newestID: String?
        public let fingerprint: Int
    }

    /// MRU last.
    private var entries: [(key: Key, text: String)] = []

    public init() {}

    public static func key(chatID: String?, messages: [ChatMessage]) -> Key {
        var hasher = Hasher()
        for m in messages {
            hasher.combine(m.id)
            hasher.combine(m.content)
        }
        return Key(
            chatID: chatID, count: messages.count,
            newestID: messages.last?.id, fingerprint: hasher.finalize())
    }

    /// Cached text for an unchanged thread, else nil. Hits refresh LRU.
    public mutating func lookup(chatID: String?, messages: [ChatMessage]) -> String? {
        let k = Self.key(chatID: chatID, messages: messages)
        guard let i = entries.firstIndex(where: { $0.key == k }) else { return nil }
        let hit = entries.remove(at: i)
        entries.append(hit)
        return hit.text
    }

    public mutating func store(chatID: String?, messages: [ChatMessage], text: String) {
        let k = Self.key(chatID: chatID, messages: messages)
        entries.removeAll(where: { $0.key == k })
        entries.append((key: k, text: text))
        while entries.count > Self.capacity {
            entries.removeFirst()
        }
    }

    public mutating func reset() {
        entries.removeAll()
    }
}
