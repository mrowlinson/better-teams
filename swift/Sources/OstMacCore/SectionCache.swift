// SectionCache.swift — NOLOAD: per-account last-good section snapshots.
//
// Every list section (chat list, teams, To Do, Planner, recordings, transcripts,
// Files, calendar weeks, Shifts weeks) writes its last successful load
// here and paints it on the next launch / account switch before any
// network call, so a pane only shows a loading state on the first-ever
// run with an empty cache. Chat timelines live in MessageHistoryCache
// (HISTLOAD); activity + the apps catalog persist in UserDefaults.
//
// Layout: Application Support/Better Teams/sections[/<accountId>]/
// <key>.json (default account keeps the base dir, like every other
// per-account store). Files are written atomically with
// complete-until-first-auth protection, owner-only permissions. Local
// only — never synced or uploaded. A snapshot that fails to decode
// (model change) is ignored; the section just loads from the network.
import Foundation

public final class SectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: [String: Data] = [:]
    private let directory: URL?
    private let queue = DispatchQueue(label: "bt.section-cache", qos: .utility)

    /// `directory` nil = memory only (tests, demo).
    public init(directory: URL?) {
        self.directory = directory
    }

    public static func memoryOnly() -> SectionCache {
        SectionCache(directory: nil)
    }

    public static func disk(for accountID: String) -> SectionCache {
        SectionCache(directory: directory(for: accountID))
    }

    public static func directory(for accountID: String) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let base = appSupport.appendingPathComponent("\(AppIdentity.name)/sections", isDirectory: true)
        return AccountProfile.dir(base, for: accountID)
    }

    /// Snapshot key → file name (keys may carry ids: `shifts.<team>.<week>`).
    public static func fileName(for key: String) -> String {
        MessageHistoryCache.fileName(for: key)
    }

    /// Last saved value for `key` (memory, else disk; synchronous —
    /// snapshots are small JSON lists). Logs the load duration.
    public func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let start = DispatchTime.now().uptimeNanoseconds
        queue.sync {} // a save still queued lands first
        lock.lock()
        var data = memory[key]
        lock.unlock()
        var source = "memory"
        if data == nil, let dir = directory {
            data = try? Data(contentsOf: dir.appendingPathComponent(Self.fileName(for: key)))
            source = "disk"
            if let data {
                lock.lock()
                memory[key] = data
                lock.unlock()
            }
        }
        guard let data else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            Log.store.error("snapshot decode failed \(Self.kind(key), privacy: .public)")
            return nil
        }
        Log.store.info("snapshot load \(Self.kind(key), privacy: .public) \(data.count, privacy: .public)B \(source, privacy: .public) \(Log.ms(since: start), privacy: .public)ms")
        return value
    }

    /// Remember `value` as the last good snapshot for `key`. Encoding
    /// and the disk write run behind on a utility queue (never on the
    /// main thread); an unchanged snapshot is not rewritten.
    public func save<T: Encodable & Sendable>(_ value: T, key: String) {
        let dir = directory
        let kind = Self.kind(key)
        queue.async { [self] in
            let start = DispatchTime.now().uptimeNanoseconds
            guard let data = try? JSONEncoder().encode(value) else { return }
            lock.lock()
            let unchanged = memory[key] == data
            memory[key] = data
            lock.unlock()
            guard !unchanged, let dir else { return }
            let url = dir.appendingPathComponent(Self.fileName(for: key))
            let fm = FileManager.default
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            }
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // Volumes without data protection reject the class.
                try? data.write(to: url, options: .atomic)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            Log.store.info("snapshot save \(kind, privacy: .public) \(data.count, privacy: .public)B \(Log.ms(since: start), privacy: .public)ms")
        }
    }

    /// Drop every snapshot (memory + this cache's top-level files).
    public func removeAll() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        guard let dir = directory else { return }
        queue.async { Self.removeFiles(in: dir) }
    }

    /// Wait for queued disk writes (tests).
    public func flush() {
        queue.sync {}
    }

    static func removeFiles(in dir: URL, fileManager: FileManager = .default) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for url in urls where url.pathExtension == "json" {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Log-safe key kind: the part before the first `.` (ids dropped).
    static func kind(_ key: String) -> String {
        String(key.split(separator: ".", maxSplits: 1).first ?? "")
    }
}
