// RichMediaCache.swift — om-richmedia: memory + disk image cache.
//
// Keyed by URL+message-id (sha256 hex), so paging (prepend) and streaming
// (upsert) re-render the same bubbles without refetching. In-flight
// requests dedupe: N bubbles awaiting the same key share one fetch.
// Memory is a MediaMemoryStore (NSCache in the app, 64 MB); disk persists
// across launches.
import CryptoKit
import Foundation

public enum MediaFetchError: Error, Sendable {
    case failed(String)
}

public actor RichMediaCache {
    public static let shared = RichMediaCache(
        diskDir: memoryOnly ? nil : defaultDiskDir())

    /// Demo (core-b leak sweep): process-wide memory-only switch. AppState
    /// sets it synchronously in `--demo` before any view loads media, so
    /// no instance (not even an already-built `.shared`) reads, writes,
    /// evicts or creates the real on-disk cache.
    public static var memoryOnly: Bool {
        get { memoryOnlyLock.lock(); defer { memoryOnlyLock.unlock() }; return _memoryOnly }
        set { memoryOnlyLock.lock(); _memoryOnly = newValue; memoryOnlyLock.unlock() }
    }
    private static let memoryOnlyLock = NSLock()
    nonisolated(unsafe) private static var _memoryOnly = false

    /// Disk dir in effect (nil while `memoryOnly`).
    private var activeDiskDir: URL? { Self.memoryOnly ? nil : diskDir }

    /// Byte source for a URL. Default handles `demo://` fixtures + core.
    public typealias Fetcher = @Sendable (String) async throws -> Data

    /// Disk-cache ceilings (om-s3-mediahot): the dir never grows past
    /// these — writes past the cap evict least-recently-read entries.
    public static let defaultDiskCapBytes = 256 * 1024 * 1024
    public static let defaultDiskCapFiles = 2000

    private let memory: MediaMemoryStore<NSData>
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var diskDir: URL?
    private let diskCapBytes: Int
    private let diskCapFiles: Int
    /// Amortized trim (om-perf-swift-media): the full dir scan runs only
    /// when these estimates say the caps may be over, or every
    /// `trimScanEveryWrites` (bounds drift from foreign writers). Nil =
    /// unknown (seeded by a scan on the next write, so the first write
    /// into an over-cap dir still trims promptly).
    private var estFiles: Int?
    private var estBytes: Int?
    private var writesSinceTrim = 0
    private static let trimScanEveryWrites = 64

    public init(memoryLimitMB: Int = 64) {
        self.init(diskDir: Self.defaultDiskDir(), memoryLimitMB: memoryLimitMB)
    }

    public init(
        diskDir: URL?, memoryLimitMB: Int = 64,
        diskCapBytes: Int = RichMediaCache.defaultDiskCapBytes,
        diskCapFiles: Int = RichMediaCache.defaultDiskCapFiles,
        memory memoryPolicy: MediaMemoryPolicy = .system
    ) {
        self.diskDir = diskDir
        self.diskCapBytes = diskCapBytes
        self.diskCapFiles = diskCapFiles
        memory = MediaMemoryStore(
            policy: memoryPolicy, costLimit: memoryLimitMB * 1024 * 1024)
    }

    public static func defaultDiskDir() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        migrateLegacyDirectory(under: base)
        let dir = diskDirBaseURL(under: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pre-rename Application Support leaf (never written, only moved).
    nonisolated public static let legacyDiskLeaf = "OstMac"

    /// `<appSupport>/<AppIdentity.name>/MediaCache` (current dir).
    nonisolated public static func diskDirBaseURL(under appSupport: URL) -> URL {
        appSupport.appendingPathComponent("\(AppIdentity.name)/MediaCache", isDirectory: true)
    }

    /// `<appSupport>/OstMac/MediaCache` (pre-rename dir).
    nonisolated public static func legacyDiskDirBaseURL(under appSupport: URL) -> URL {
        appSupport.appendingPathComponent("\(legacyDiskLeaf)/MediaCache", isDirectory: true)
    }

    /// Move the legacy dir onto the new dir when the new one is absent.
    /// No-op when legacy is missing or the new dir already exists —
    /// nothing is ever deleted.
    @discardableResult
    nonisolated public static func migrateLegacyDirectory(
        under appSupport: URL, fileManager: FileManager = .default
    ) -> Bool {
        let legacy = legacyDiskDirBaseURL(under: appSupport)
        let fresh = diskDirBaseURL(under: appSupport)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: fresh.path)
        else { return false }
        do {
            try fileManager.createDirectory(
                at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: fresh)
            return true
        } catch {
            return false
        }
    }

    /// Per-account disk dir (d1-accounts): default account keeps the
    /// base dir; every other account nests `<accountId>/` under it.
    public static func diskDir(for accountID: String) -> URL? {
        guard let base = defaultDiskDir() else { return nil }
        let dir = AccountProfile.dir(base, for: accountID)
        if dir != base {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Account switch (d1-accounts): drop memory + in-flight (keys are
    /// URL+message-id, meaningless across accounts) and re-point disk
    /// at the new account's subdir.
    public func resetForAccount(_ accountID: String) {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        memory.removeAllObjects()
        diskDir = Self.diskDir(for: accountID)
        estFiles = nil
        estBytes = nil
        writesSinceTrim = 0
    }

    /// Default fetcher: offline `demo://` fixtures, else blocking core FFI
    /// (detached so the actor never blocks on network).
    public static func defaultFetch(url: String) async throws -> Data {
        if url.hasPrefix("demo://") {
            return try DemoMedia.data(for: url)
        }
        return try await Task.blocking {
            try RustCore.mediaFetch(url: url).data
        }.value
    }

    /// Stable key: sha256 hex of `messageID + "\n" + url`.
    /// Nibble-table hex (was: `String(format:)` per byte, ~35µs/key).
    public static func key(url: String, messageID: String) -> String {
        ImageDecode.bytesHex(Data((messageID + "\n" + url).utf8))
    }

    /// Memory, then disk. Nil when nothing is stored (no fetch).
    public func cached(url: String, messageID: String) -> Data? {
        cached(key: Self.key(url: url, messageID: messageID))
    }

    /// Keyed lookup (skips re-hashing when the caller already has the key).
    private func cached(key k: String) -> Data? {
        if let m = memory.object(forKey: k as NSString) { return m as Data }
        if let d = readDisk(key: k) {
            memory.setObject(d as NSData, forKey: k as NSString, cost: d.count)
            return d
        }
        return nil
    }

    /// Cached bytes, fetching once on miss. Concurrent callers for the same
    /// key share the in-flight fetch; failures are not cached.
    public func data(
        url: String, messageID: String,
        fetcher: @escaping Fetcher = { try await RichMediaCache.defaultFetch(url: $0) }
    ) async throws -> Data {
        let k = Self.key(url: url, messageID: messageID)
        if let hit = cached(key: k) { return hit }
        if let t = inFlight[k] { return try await t.value }
        let task: Task<Data, Error> = Task { try await fetcher(url) }
        inFlight[k] = task
        do {
            let d = try await task.value
            memory.setObject(d as NSData, forKey: k as NSString, cost: d.count)
            writeDisk(key: k, data: d)
            inFlight[k] = nil
            return d
        } catch {
            inFlight[k] = nil
            throw error
        }
    }

    /// Cancel an in-flight fetch by URL+message (image-prefetch
    /// bail-out for far-off-screen rows). Cached bytes are untouched;
    /// the next `data()` call refetches. No-op without an in-flight
    /// fetch. Callers awaiting the cancelled key get CancellationError.
    public func cancel(url: String, messageID: String) {
        cancel(key: Self.key(url: url, messageID: messageID))
    }

    /// Cancel an in-flight fetch by cache key (see above).
    public func cancel(key: String) {
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    public func clearMemory() {
        memory.removeAllObjects()
    }

    /// Settings ▸ Advanced ▸ Reset Caches: drop memory and this account's
    /// cached files. Top-level files only (the default account's dir
    /// holds the other accounts' subdirs); memory-only (demo) never
    /// touches disk. In-flight fetches keep running: rows on screen are
    /// waiting for them, and a cancelled fetch would land them failed
    /// for good (models load once). Decoded images already on screen
    /// stay with their rows; everything else refetches lazily.
    public func removeAll() {
        memory.removeAllObjects()
        if let dir = activeDiskDir,
           let items = try? FileManager.default.contentsOfDirectory(
               at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for u in items where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                try? FileManager.default.removeItem(at: u)
            }
        }
        estFiles = nil
        estBytes = nil
        writesSinceTrim = 0
    }

    private func diskURL(key: String) -> URL? {
        activeDiskDir?.appendingPathComponent(key, isDirectory: false)
    }

    private func readDisk(key: String) -> Data? {
        guard let u = diskURL(key: key) else { return nil }
        guard let d = try? Data(contentsOf: u) else { return nil }
        // LRU touch: reads refresh recency for the trim below.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: u.path)
        return d
    }

    private func writeDisk(key: String, data: Data) {
        guard let u = diskURL(key: key) else { return }
        let isNew = !FileManager.default.fileExists(atPath: u.path)
        try? data.write(to: u, options: .atomic)
        maybeTrimDisk(isNewFile: isNew, wroteBytes: data.count)
    }

    /// Scan + evict only when the estimates say a cap may be over (or
    /// the estimates are unseeded / stale). Under-cap writes skip the
    /// readdir+stat entirely (~19ms saved per write at 2k files).
    /// Same-key overwrites keep the file count (the 64-write reseed
    /// absorbs any byte drift from changed sizes).
    private func maybeTrimDisk(isNewFile: Bool, wroteBytes: Int) {
        writesSinceTrim += 1
        if estFiles == nil || estBytes == nil
            || writesSinceTrim >= Self.trimScanEveryWrites
        {
            let (files, bytes) = trimDisk()
            estFiles = files
            estBytes = bytes
            writesSinceTrim = 0
            return
        }
        if isNewFile {
            estFiles! += 1
            estBytes! += wroteBytes
        }
        if estFiles! > diskCapFiles || estBytes! > diskCapBytes {
            let (files, bytes) = trimDisk()
            estFiles = files
            estBytes = bytes
            writesSinceTrim = 0
        }
    }

    /// Evict least-recently-modified files until the dir fits both caps.
    /// Best-effort (a racing reader just refetches); failures are silent.
    /// Returns the post-trim (files, bytes) for the trim estimates.
    @discardableResult
    private func trimDisk() -> (files: Int, bytes: Int) {
        guard let dir = activeDiskDir else { return (estFiles ?? 0, estBytes ?? 0) }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return (estFiles ?? 0, estBytes ?? 0) }
        var entries: [(url: URL, size: Int, mtime: Date)] = []
        entries.reserveCapacity(urls.count)
        var total = 0
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true,
                  let size = v.fileSize
            else { continue }
            total += size
            entries.append((u, size, v.contentModificationDate ?? .distantPast))
        }
        guard total > diskCapBytes || entries.count > diskCapFiles else {
            return (entries.count, total)
        }
        entries.sort { $0.mtime < $1.mtime } // oldest (least-recent) first
        var i = 0
        while (total > diskCapBytes || entries.count - i > diskCapFiles)
            && i < entries.count
        {
            try? FileManager.default.removeItem(at: entries[i].url)
            total -= entries[i].size
            i += 1
        }
        return (entries.count - i, total)
    }

    /// Disk footprint (file count + bytes) for tests/diagnostics.
    func diskUsage() -> (files: Int, bytes: Int) {
        guard let dir = activeDiskDir else { return (0, 0) }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return (0, 0) }
        var files = 0
        var bytes = 0
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, let size = v.fileSize
            else { continue }
            files += 1
            bytes += size
        }
        return (files, bytes)
    }
}
