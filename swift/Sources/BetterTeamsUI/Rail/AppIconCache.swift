// AppIconCache.swift — catalog app icons (the manifest's `colorIcon`) for
// the rail, its More menu and the store tiles (UI-SPEC §5.2).
//
// Stable UI: an icon fetched once shows on the first draw from then on,
// including the next launch. Lookups are synchronous (memory, then a
// small disk cache); the network is used only on a miss, from a view's
// `.task`, and the symbol stays until the image arrives. The fetch is
// anonymous: an ephemeral session with no cookies, no cache and no
// headers of ours (the icons sit on a public CDN; account tokens never
// travel with them, so it never goes through the core's media fetch).
// Demo registers no icons, so it never touches the network. Under XCTest
// the disk cache lives in a temporary folder.
import AppKit
import CryptoKit
import Observation
import OstMacCore
import SwiftUI

@Observable
@MainActor
final class AppIconCache {
    static let shared = AppIconCache(directory: defaultDirectory(), fetch: anonymousFetch)

    /// Catalog app (`ta.<id>`) → its https color icon.
    private(set) var urls: [FrameAppID: URL] = [:]
    /// Bumped when a fetched icon lands, so views that drew the symbol
    /// redraw with it.
    private(set) var landed: Set<URL> = []

    @ObservationIgnored private var memory: [URL: NSImage] = [:]
    @ObservationIgnored private var misses: Set<URL> = []
    @ObservationIgnored private var running: Set<URL> = []
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let fetch: @Sendable (URL) async -> Data?

    init(directory: URL?, fetch: @escaping @Sendable (URL) async -> Data?) {
        self.directory = directory
        self.fetch = fetch
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// ~/Library/Caches/<bundle>/AppIcons; a temporary folder under XCTest.
    nonisolated static func defaultDirectory(test: Bool = UserFolders.isTestProcess) -> URL {
        let base = test
            ? FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeamsTest", isDirectory: true)
            : (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "BetterTeams", isDirectory: true)
        return base.appendingPathComponent("AppIcons", isDirectory: true)
    }

    /// Records the icons of catalog manifests (live accounts only).
    func register(_ manifests: [TeamsAppManifest], appID: (String) -> FrameAppID) {
        var next = urls
        for m in manifests {
            if let url = Self.iconURL(m) { next[appID(m.id)] = url }
        }
        if next != urls { urls = next }
    }

    static func iconURL(_ m: TeamsAppManifest) -> URL? {
        guard let s = m.colorIcon, s.hasPrefix("https://") else { return nil }
        return URL(string: s)
    }

    func url(for id: FrameAppID) -> URL? { urls[id] }

    func url(for section: SectionID) -> URL? {
        if case .web(let id) = section { return urls[id] }
        return nil
    }

    /// The icon if it is in memory or on disk; never the network. Reading
    /// it inside a view body tracks `landed`, so a later fetch redraws.
    func image(_ url: URL) -> NSImage? {
        _ = landed.contains(url)
        if let i = memory[url] { return i }
        guard !misses.contains(url) else { return nil }
        if let file = file(url), let data = try? Data(contentsOf: file), let i = NSImage(data: data), i.isValid {
            memory[url] = i
            return i
        }
        misses.insert(url)
        return nil
    }

    /// Fetches a missing icon once (a view's `.task`); a cached one is
    /// never fetched again.
    func load(_ url: URL) async {
        guard image(url) == nil, !running.contains(url) else { return }
        running.insert(url)
        defer { running.remove(url) }
        guard let data = await fetch(url), data.count <= Self.maxBytes,
              let i = NSImage(data: data), i.isValid else { return }
        if let file = file(url) { try? data.write(to: file, options: .atomic) }
        memory[url] = i
        misses.remove(url)
        landed.insert(url)
    }

    static let maxBytes = 1 << 20

    /// A menu-sized copy (menus draw an image at its own size).
    func menuImage(_ url: URL?) -> NSImage? {
        guard let url, let i = image(url), let c = i.copy() as? NSImage else { return nil }
        c.size = NSSize(width: 16, height: 16)
        return c
    }

    private func file(_ url: URL) -> URL? {
        guard let directory else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    /// Anonymous GET: no cookies, no URL cache, no credentials, no
    /// headers added.
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    @Sendable nonisolated static func anonymousFetch(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }
}

/// A catalog app icon at `size`, rounded like an app tile; `fallback`
/// (the symbol) until the icon is cached, or when there is none.
struct AppIconImage<Fallback: View>: View {
    let url: URL?
    let size: CGFloat
    /// Clip to the app-tile corner radius (rail, menu); off when the
    /// image sits inside a tile of its own (store).
    var rounded = true
    var cache: AppIconCache = .shared
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        if let url, let image = cache.image(url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: rounded ? size * 0.22 : 0, style: .continuous))
        } else {
            fallback()
                .task(id: url) { if let url { await cache.load(url) } }
        }
    }
}
