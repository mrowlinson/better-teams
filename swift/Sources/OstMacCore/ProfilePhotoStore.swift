// ProfilePhotoStore.swift — real profile photos for avatars (Graph
// GET /users/{id}/photo/$value). Disk cache with ETag revalidation and
// max-age, a 404 "no photo" marker, utility-QoS fetches, in-flight
// dedupe and a LIFO queue (the rows that just scrolled on screen go
// first). One observable slot per person so a photo landing redraws
// only that avatar, and a cached photo is there on first render.
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One person's photo (nil = show initials).
@MainActor
public final class PhotoSlot: ObservableObject {
    @Published public private(set) var image: NSImage?
    nonisolated init() {}
    func set(_ image: NSImage?) { if self.image !== image { self.image = image } }
}

/// What a photo GET returned.
public struct PhotoFetchResult: Sendable {
    public let status: Int
    public let data: Data
    public let etag: String?
    public let maxAge: TimeInterval?

    public init(status: Int, data: Data = Data(), etag: String? = nil, maxAge: TimeInterval? = nil) {
        self.status = status; self.data = data; self.etag = etag; self.maxAge = maxAge
    }
}

@MainActor
public final class ProfilePhotoStore {
    /// GET the photo for a Graph user key, revalidating with `etag`.
    public typealias Fetcher = @Sendable (_ userKey: String, _ etag: String?) throws -> PhotoFetchResult

    struct Meta: Codable, Equatable {
        var etag: String?
        var fetchedAt: Date
        var maxAge: TimeInterval
        /// True when the user has no photo (404) — initials, no refetch until stale.
        var none: Bool
    }

    /// Max concurrent fetches (600-row lists stay gentle on Graph).
    public var maxConcurrent = 4
    /// Freshness when the server sends no max-age.
    public var defaultMaxAge: TimeInterval = 24 * 3600
    public var noneMaxAge: TimeInterval = 6 * 3600
    public var now: () -> Date = { Date() }
    /// Pixel edge photos are stored at (largest avatar is 96 pt @2x).
    nonisolated static let pixelSize = 256

    public let directory: ContactDirectory
    private let fetcher: Fetcher
    private let cacheDir: URL?
    private var slots: [String: PhotoSlot] = [:]
    private var metas: [String: Meta] = [:]
    /// LIFO: last requested = first fetched.
    private var pending: [String] = []
    private var running: Set<String> = []
    /// Name-only requests waiting on a directory resolve.
    private var resolving: Set<String> = []
    /// Fetch count (tests pin dedupe/rate).
    public private(set) var fetchCount = 0

    /// `cacheDir` nil = memory only (demo, tests that don't need disk).
    public nonisolated init(directory: ContactDirectory, cacheDir: URL?, fetcher: @escaping Fetcher) {
        self.directory = directory
        self.cacheDir = cacheDir
        self.fetcher = fetcher
        if let cacheDir {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }

    /// Live store: ~/Library/Caches/<bundle>/ProfilePhotos, Graph fetcher.
    public nonisolated static func live(directory: ContactDirectory) -> ProfilePhotoStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "BetterTeams"
        let dir = caches.appendingPathComponent(bundle).appendingPathComponent("ProfilePhotos")
        return ProfilePhotoStore(directory: directory, cacheDir: dir, fetcher: GraphPhotoFetcher.fetch)
    }

    /// Demo store: generated abstract images for the canned people.
    public nonisolated static func demo(directory: ContactDirectory) -> ProfilePhotoStore {
        ProfilePhotoStore(directory: directory, cacheDir: nil) { key, _ in
            guard let png = DemoPhotos.png(for: key) else { return PhotoFetchResult(status: 404) }
            return PhotoFetchResult(status: 200, data: png, etag: "demo", maxAge: 365 * 24 * 3600)
        }
    }

    // MARK: slots

    /// The slot for a person, pre-filled from memory/disk so a cached
    /// photo shows on first render (no initials flash).
    public func slot(for ref: ContactRef) -> PhotoSlot {
        let key = cacheKey(for: ref)
        if let s = slots[key] { return s }
        let s = PhotoSlot()
        slots[key] = s
        if key.hasPrefix("id:") {
            loadMeta(key)
            if metas[key]?.none != true, let img = readImage(key) { s.set(img) }
        }
        return s
    }

    /// Ask for a photo (row appeared). Fresh cache = no network.
    public func request(_ ref: ContactRef) {
        let r = directory.enrich(ref)
        guard let userKey = r.graphKey else {
            resolveThenRequest(r)
            return
        }
        let key = "id:" + userKey.lowercased()
        _ = slot(for: r)
        if running.contains(key) { return }
        if let m = metas[key], now().timeIntervalSince(m.fetchedAt) < m.maxAge { return }
        pending.removeAll { $0 == key }
        pending.append(key)
        pump()
    }

    /// Row left the screen before its turn: drop it from the queue.
    public func cancel(_ ref: ContactRef) {
        let key = cacheKey(for: ref)
        pending.removeAll { $0 == key }
    }

    private func cacheKey(for ref: ContactRef) -> String {
        let r = directory.enrich(ref)
        return r.graphKey.map { "id:" + $0.lowercased() } ?? "name:" + ContactDirectory.norm(r.name)
    }

    private func resolveThenRequest(_ ref: ContactRef) {
        let nameKey = "name:" + ContactDirectory.norm(ref.name)
        guard !ref.name.isEmpty, !resolving.contains(nameKey) else { return }
        resolving.insert(nameKey)
        Task { [weak self] in
            guard let self else { return }
            let found = await self.directory.resolve(name: ref.name)
            self.resolving.remove(nameKey)
            guard let found, found.graphKey != nil else { return }
            // Point the name slot at the id slot's photo once it lands.
            let idSlot = self.slot(for: found)
            if let nameSlot = self.slots[nameKey], nameSlot !== idSlot {
                nameSlot.set(idSlot.image)
                self.aliases[found.key, default: []].append(nameSlot)
            }
            self.request(found)
        }
    }

    /// Name slots created before the id was known, fed alongside the id slot.
    private var aliases: [String: [PhotoSlot]] = [:]

    // MARK: queue

    private func pump() {
        while running.count < maxConcurrent, let key = pending.popLast() {
            running.insert(key)
            fetchCount += 1
            let userKey = String(key.dropFirst(3))
            let etag = metas[key].flatMap { $0.none ? nil : $0.etag }
            let fetcher = self.fetcher
            Task { [weak self] in
                let outcome = await Task.blocking(priority: .utility) { () -> (PhotoFetchResult?, Data?) in
                    guard let r = try? fetcher(userKey, etag) else { return (nil, nil) }
                    let small = r.status == 200 ? Self.downscale(r.data) : nil
                    return (r, small)
                }.value
                self?.complete(key: key, result: outcome.0, image: outcome.1)
            }
        }
    }

    private func complete(key: String, result: PhotoFetchResult?, image data: Data?) {
        running.remove(key)
        defer { pump() }
        guard let result else { return }  // transport error: keep what we have, retry next appear
        let t = now()
        switch result.status {
        case 200:
            guard let data, let img = NSImage(data: data) else { return }
            let meta = Meta(etag: result.etag, fetchedAt: t, maxAge: result.maxAge ?? defaultMaxAge, none: false)
            store(key, meta: meta, image: data)
            publish(key, img)
        case 304:
            if var m = metas[key] {
                m.fetchedAt = t
                m.maxAge = result.maxAge ?? m.maxAge
                store(key, meta: m, image: nil)
            }
        case 404:
            store(key, meta: Meta(etag: nil, fetchedAt: t, maxAge: noneMaxAge, none: true), image: nil)
            removeImage(key)
            publish(key, nil)
        default:
            // 403/429/5xx: back off like a miss so the list doesn't hammer.
            let m = Meta(etag: metas[key]?.etag, fetchedAt: t, maxAge: noneMaxAge, none: metas[key]?.none ?? true)
            metas[key] = m
        }
    }

    private func publish(_ key: String, _ image: NSImage?) {
        slots[key]?.set(image)
        for s in aliases[key] ?? [] { s.set(image) }
    }

    // MARK: disk

    private func fileBase(_ key: String) -> URL? {
        guard let cacheDir else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(String(digest.prefix(32)))
    }

    private func loadMeta(_ key: String) {
        guard metas[key] == nil, let base = fileBase(key),
              let data = try? Data(contentsOf: base.appendingPathExtension("json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return }
        metas[key] = meta
    }

    private func readImage(_ key: String) -> NSImage? {
        if let img = memory[key] { return img }
        guard let base = fileBase(key),
              let img = NSImage(contentsOf: base.appendingPathExtension("img")) else { return nil }
        memory[key] = img
        return img
    }

    private var memory: [String: NSImage] = [:]

    private func store(_ key: String, meta: Meta, image: Data?) {
        metas[key] = meta
        if let image, let img = NSImage(data: image) { memory[key] = img }
        guard let base = fileBase(key) else { return }
        if let image { try? image.write(to: base.appendingPathExtension("img"), options: .atomic) }
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: base.appendingPathExtension("json"), options: .atomic)
        }
    }

    private func removeImage(_ key: String) {
        memory[key] = nil
        guard let base = fileBase(key) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathExtension("img"))
    }

    /// Photo bytes → ≤256 px JPEG (Graph can return 648 px originals).
    nonisolated static func downscale(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - Graph fetcher

/// GET /users/{key}/photo/$value with If-None-Match. The Graph token is
/// cached for a few minutes so a list of avatars doesn't hit the
/// keychain per row. Never logs the token or URL.
enum GraphPhotoFetcher {
    private static let lock = NSLock()
    private static var cached: (token: String, at: Date)?

    static func token() throws -> String {
        lock.lock()
        if let c = cached, Date().timeIntervalSince(c.at) < 300 { lock.unlock(); return c.token }
        lock.unlock()
        let ctx = try CoreReads.production()
        let t = try CoreReads.graphToken(profile: CoreLocal.activeProfileID(), code: "photo", ctx: ctx)
        lock.lock(); cached = (t, Date()); lock.unlock()
        return t
    }

    @Sendable static func fetch(userKey: String, etag: String?) throws -> PhotoFetchResult {
        guard let url = URL(string: CoreReads.graphBase + ContactReads.userPath(userKey) + "/photo/$value") else {
            return PhotoFetchResult(status: 404)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let request = req
        let result = try SyncBridge.run {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let http = resp as? HTTPURLResponse
            return PhotoFetchResult(
                status: http?.statusCode ?? 0, data: data,
                etag: http?.value(forHTTPHeaderField: "ETag"),
                maxAge: http?.value(forHTTPHeaderField: "Cache-Control").flatMap(parseMaxAge))
        }
        if result.status == 401 { lock.lock(); cached = nil; lock.unlock() }
        return result
    }

    static func parseMaxAge(_ header: String) -> TimeInterval? {
        for part in header.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("max-age="), let v = TimeInterval(t.dropFirst(8)), v > 0 { return v }
        }
        return nil
    }
}

// MARK: - Demo photos

/// Abstract generated portraits for demo people: layered gradient
/// circles per person (no faces, no real images).
enum DemoPhotos {
    static func png(for userKey: String) -> Data? {
        guard ContactDemo.entries.contains(where: { $0.profile.id == userKey.lowercased() }) else { return nil }
        let seed = userKey.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        let size = 256
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func hue(_ shift: UInt32) -> CGColor {
            let h = CGFloat((seed >> shift) % 360) / 360
            return NSColor(calibratedHue: h, saturation: 0.55, brightness: 0.85, alpha: 1).cgColor
        }
        let a = hue(0), b = hue(9), c = hue(17)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let g = CGGradient(colorsSpace: space, colors: [a, b] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size, y: size), options: [])
        }
        ctx.setFillColor(c.copy(alpha: 0.75) ?? c)
        let r = CGFloat(60 + seed % 40)
        ctx.fillEllipse(in: CGRect(x: CGFloat(seed % 120), y: CGFloat((seed >> 4) % 120), width: r * 2, height: r * 2))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
        ctx.fillEllipse(in: CGRect(x: CGFloat((seed >> 7) % 160), y: CGFloat((seed >> 11) % 160), width: r, height: r))
        guard let img = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
