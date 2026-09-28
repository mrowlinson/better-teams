// MessageHistoryCache.swift — histload: per-chat message snapshot so a
// reopened chat paints instantly (0 network wait) and only the newest
// page is fetched behind it.
//
// One entry per chat: the loaded messages (oldest first) plus the
// opaque older-page cursor that continues right before the oldest
// kept message, so lazy scroll-back resumes where the last visit
// stopped. Memory first, then one JSON file per chat under
// `<appSupport>/<AppIdentity.name>/history[/<accountId>]`. Writes run
// on a serial background queue; reads are synchronous (small files).
import Foundation

public final class MessageHistoryCache: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var messages: [ChatMessage]
        /// Cursor for the page right before `messages.first`; nil with
        /// `endOfHistory` = nothing older, nil without = unknown (the
        /// disk copy was trimmed; the next fresh page supplies one).
        public var pageToken: String?
        public var endOfHistory: Bool

        public init(messages: [ChatMessage], pageToken: String?, endOfHistory: Bool) {
            self.messages = messages
            self.pageToken = pageToken
            self.endOfHistory = endOfHistory
        }
    }

    /// Disk copies keep at most this many newest messages (memory keeps
    /// the whole loaded list for the session).
    public static let maxDiskMessages = 2000

    private let lock = NSLock()
    private var memory: [String: Entry] = [:]
    private let directory: URL?
    private let queue = DispatchQueue(label: "bt.history-cache", qos: .utility)

    /// `directory` nil = memory only (tests, pop-outs).
    public init(directory: URL?) {
        self.directory = directory
    }

    public static func memoryOnly() -> MessageHistoryCache {
        MessageHistoryCache(directory: nil)
    }

    /// Per-account disk cache (default account keeps the base dir).
    public static func disk(for accountID: String) -> MessageHistoryCache {
        MessageHistoryCache(directory: directory(for: accountID))
    }

    public static func directory(for accountID: String) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let base = appSupport.appendingPathComponent("\(AppIdentity.name)/history", isDirectory: true)
        return AccountProfile.dir(base, for: accountID)
    }

    /// Chat id → stable, collision-safe file name (readable prefix +
    /// FNV-1a 64 of the full id; Swift's `Hasher` is per-process seeded).
    public static func fileName(for chatID: String) -> String {
        let safe = chatID.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in chatID.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(safe.prefix(80)) + "-" + String(h, radix: 16) + ".json"
    }

    /// Cached entry for a chat: memory, else disk (synchronous).
    public func load(chatID: String) -> Entry? {
        lock.lock()
        if let e = memory[chatID] {
            lock.unlock()
            return e
        }
        lock.unlock()
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent(Self.fileName(for: chatID))),
              let e = try? JSONDecoder().decode(Entry.self, from: data),
              !e.messages.isEmpty
        else { return nil }
        lock.lock()
        if memory[chatID] == nil { memory[chatID] = e }
        lock.unlock()
        return e
    }

    /// Remember a chat's loaded list + older-page cursor. Memory updates
    /// now; the disk copy (trimmed to `maxDiskMessages`) writes behind.
    public func store(chatID: String, messages: [ChatMessage], pageToken: String?) {
        guard !messages.isEmpty else { return }
        let entry = Entry(messages: messages, pageToken: pageToken, endOfHistory: pageToken == nil)
        lock.lock()
        memory[chatID] = entry
        lock.unlock()
        guard let dir = directory else { return }
        let disk = Self.diskEntry(entry)
        let url = dir.appendingPathComponent(Self.fileName(for: chatID))
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(disk) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Disk form: over the cap keeps the newest messages and drops the
    /// cursor (it points before the trimmed-away oldest rows).
    public static func diskEntry(_ e: Entry, cap: Int = maxDiskMessages) -> Entry {
        guard e.messages.count > cap else { return e }
        return Entry(messages: Array(e.messages.suffix(cap)), pageToken: nil, endOfHistory: false)
    }

    /// Drop every entry (memory + this cache's top-level files; sibling
    /// account subdirs nested under the default dir survive).
    public func removeAll() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        guard let dir = directory else { return }
        queue.async {
            Self.removeFiles(in: dir)
        }
    }

    public static func removeFiles(in dir: URL, fileManager: FileManager = .default) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return }
        for url in urls where url.pathExtension == "json" {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Wait for queued disk writes (tests).
    func flush() {
        queue.sync {}
    }
}
