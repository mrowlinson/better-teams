// ImagePreload.swift — om-imgpreload: look-ahead image prefetch so chats
// never show loading indicators.
//
// The timeline reports its visible bubble ids; the policy mines a window
// around the viewport (lookBehind above + lookAhead below), orders window
// images nearest-first (photos before emoticons at the same distance),
// and the preloader fills RichMediaCache (memory + disk — the same layer
// RemoteImage reads) ahead of the scroll. Fetches that drift past the
// window edge by more than farMargin cancel outright (their cache
// in-flight drops too, so bandwidth follows the reader).
//
// Counters live in Diagnostics only (DiagnosticsFormat.preloadLine);
// chats never show counts, and the chat list is untouched.
import Foundation

/// Pure prefetch-window decisions (testable without actors or views).
public enum ImagePreloadPolicy {
    /// Messages below the viewport to prefetch (scroll direction).
    public static let lookAhead = 8
    /// Messages above the viewport to prefetch (scroll-back).
    public static let lookBehind = 4
    /// In-flight prefetches surviving past the window edge. Beyond
    /// window ± farMargin, fetches cancel.
    public static let farMargin = 16
    /// Simultaneous prefetch fills (bandwidth cap).
    public static let maxConcurrent = 4

    /// One image to prefetch, in priority order.
    public struct Target: Sendable, Hashable {
        public let messageIndex: Int
        public let messageID: String
        public let url: String
        /// Viewport steps away (0 = on screen).
        public let distance: Int
        public let isEmoticon: Bool
        public var key: String { RichMediaCache.key(url: url, messageID: messageID) }
    }

    /// Viewport span over the thread (min..max visible index); nil when
    /// nothing has appeared yet (initial land).
    public static func viewportRange(
        messages: [ChatMessage], visibleIDs: Set<String>
    ) -> Range<Int>? {
        var lo: Int?
        var hi: Int?
        for (i, m) in messages.enumerated() where visibleIDs.contains(m.id) {
            lo = min(lo ?? i, i)
            hi = max(hi ?? i, i)
        }
        guard let lo, let hi else { return nil }
        return lo ..< (hi + 1)
    }

    /// Prefetch window: lookBehind above the viewport through lookAhead
    /// below it, clamped to the thread. With no viewport yet, the tail
    /// (the reader lands at the bottom).
    public static func window(
        messageCount: Int, viewport: Range<Int>?,
        lookAhead: Int = lookAhead, lookBehind: Int = lookBehind
    ) -> Range<Int> {
        guard messageCount > 0 else { return 0 ..< 0 }
        guard let vp = viewport else {
            return max(0, messageCount - lookAhead) ..< messageCount
        }
        return max(0, vp.lowerBound - lookBehind)
            ..< min(messageCount, vp.upperBound + lookAhead)
    }

    /// Steps from an index to the viewport (0 inside it, or without one).
    public static func distance(index: Int, viewport: Range<Int>?) -> Int {
        guard let vp = viewport else { return 0 }
        if index < vp.lowerBound { return vp.lowerBound - index }
        if index >= vp.upperBound { return index - (vp.upperBound - 1) }
        return 0
    }

    /// Window images nearest-first (viewport distance, photos before
    /// emoticons, thread order), deduped by cache key.
    public static func targets(
        messages: [ChatMessage], visibleIDs: Set<String>,
        lookAhead: Int = lookAhead, lookBehind: Int = lookBehind
    ) -> [Target] {
        let vp = viewportRange(messages: messages, visibleIDs: visibleIDs)
        let w = window(
            messageCount: messages.count, viewport: vp,
            lookAhead: lookAhead, lookBehind: lookBehind)
        var out: [Target] = []
        for i in w {
            let d = distance(index: i, viewport: vp)
            for img in MessageRender.images(fromRaw: messages[i].raw) {
                out.append(Target(
                    messageIndex: i, messageID: messages[i].id,
                    url: img.url, distance: d, isEmoticon: img.isEmoticon))
            }
        }
        out.sort {
            ($0.distance, $0.isEmoticon ? 1 : 0, $0.messageIndex)
                < ($1.distance, $1.isEmoticon ? 1 : 0, $1.messageIndex)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.key).inserted }
    }

    /// Keep-zone for scheduled prefetches: the window ± farMargin.
    /// Anything outside cancels (running) or drops (queued).
    public static func keepRange(
        window: Range<Int>, messageCount: Int, farMargin: Int = farMargin
    ) -> Range<Int> {
        max(0, window.lowerBound - farMargin)
            ..< min(messageCount, window.upperBound + farMargin)
    }
}

/// Look-ahead prefetcher: fills RichMediaCache for the viewport window
/// nearest-first under a concurrency cap, cancelling far-off-screen
/// fetches. One instance serves the open thread
/// (ImagePreloadStore.shared); tests build their own.
public actor ImagePreloader {
    /// Counters (Diagnostics only — chats never show numbers).
    public struct Stats: Sendable, Equatable {
        /// Completed prefetch fills.
        public var prefetched = 0
        /// Window targets already cached at schedule time.
        public var hits = 0
        /// Far-off-screen fetches cancelled.
        public var cancelled = 0
        /// Fills running now.
        public var inFlight = 0
        /// Fills queued behind the concurrency cap.
        public var pending = 0
        public var isIdle: Bool { inFlight == 0 && pending == 0 }
    }

    private struct Entry {
        let task: Task<Data, Error>
        let target: ImagePreloadPolicy.Target
        let epoch: Int
    }

    private let cache: RichMediaCache
    private let maxConcurrent: Int
    private var running: [String: Entry] = [:]
    private var pending: [ImagePreloadPolicy.Target] = []
    private var hitKeys = Set<String>()
    private var epoch = 0
    private var prefetched = 0
    private var hits = 0
    private var cancelled = 0
    private var lastFetcher: RichMediaCache.Fetcher

    public init(
        cache: RichMediaCache = .shared,
        maxConcurrent: Int = ImagePreloadPolicy.maxConcurrent,
        fetcher: @escaping RichMediaCache.Fetcher = { try await RichMediaCache.defaultFetch(url: $0) }
    ) {
        self.cache = cache
        self.maxConcurrent = max(1, maxConcurrent)
        self.lastFetcher = fetcher
    }

    public func snapshot() -> Stats {
        Stats(
            prefetched: prefetched, hits: hits, cancelled: cancelled,
            inFlight: running.count, pending: pending.count)
    }

    /// Reschedule around the current viewport: cancel fetches past the
    /// keep-zone, queue window misses nearest-first, pump the cap.
    public func update(
        messages: [ChatMessage], visibleIDs: Set<String>,
        fetcher: RichMediaCache.Fetcher? = nil,
        lookAhead: Int = ImagePreloadPolicy.lookAhead,
        lookBehind: Int = ImagePreloadPolicy.lookBehind,
        farMargin: Int = ImagePreloadPolicy.farMargin
    ) async {
        if let fetcher { lastFetcher = fetcher }
        let vp = ImagePreloadPolicy.viewportRange(messages: messages, visibleIDs: visibleIDs)
        let w = ImagePreloadPolicy.window(
            messageCount: messages.count, viewport: vp,
            lookAhead: lookAhead, lookBehind: lookBehind)
        let keep = ImagePreloadPolicy.keepRange(
            window: w, messageCount: messages.count, farMargin: farMargin)
        // Cancel far-off-screen in-flight (their cache fetch drops too,
        // so bandwidth follows the reader).
        for (key, entry) in running where !keep.contains(entry.target.messageIndex) {
            entry.task.cancel()
            await cache.cancel(key: key)
            running[key] = nil
            cancelled += 1
        }
        pending.removeAll { !keep.contains($0.messageIndex) }
        // Queue window misses nearest-first (fresh distances under the
        // current viewport, so a shifted window re-prioritizes).
        var queued = Set(pending.map(\.key)).union(running.keys)
        for t in ImagePreloadPolicy.targets(
            messages: messages, visibleIDs: visibleIDs,
            lookAhead: lookAhead, lookBehind: lookBehind)
        {
            guard queued.insert(t.key).inserted else { continue }
            if await cache.cached(url: t.url, messageID: t.messageID) != nil {
                if hitKeys.insert(t.key).inserted { hits += 1 }
                continue
            }
            pending.append(t)
        }
        pending.sort {
            Self.rank($0, viewport: vp) < Self.rank($1, viewport: vp)
        }
        await pump()
    }

    private static func rank(
        _ t: ImagePreloadPolicy.Target, viewport: Range<Int>?
    ) -> (Int, Int, Int) {
        (ImagePreloadPolicy.distance(index: t.messageIndex, viewport: viewport),
         t.isEmoticon ? 1 : 0, t.messageIndex)
    }

    /// Start queued fills nearest-first up to the concurrency cap,
    /// re-checking the cache at launch (a bubble may have filled it).
    private func pump() async {
        while running.count < maxConcurrent, !pending.isEmpty {
            let t = pending.removeFirst()
            if await cache.cached(url: t.url, messageID: t.messageID) != nil {
                if hitKeys.insert(t.key).inserted { hits += 1 }
                continue
            }
            launch(t)
        }
    }

    private func launch(_ t: ImagePreloadPolicy.Target) {
        epoch += 1
        let gen = epoch
        let key = t.key
        let cache = cache
        let fetcher = lastFetcher
        let task = Task<Data, Error> {
            try await cache.data(url: t.url, messageID: t.messageID, fetcher: fetcher)
        }
        running[key] = Entry(task: task, target: t, epoch: gen)
        Task {
            let result = await task.result
            await self.reap(key: key, epoch: gen, result: result)
        }
    }

    /// Completion of one fill: stale generations (cancelled, then
    /// relaunched by a scroll-back) never evict the new entry.
    private func reap(key: String, epoch gen: Int, result: Result<Data, Error>) async {
        guard let entry = running[key], entry.epoch == gen else { return }
        running[key] = nil
        if case .success = result { prefetched += 1 }
        await pump()
    }
}

/// View-layer prefetch driver: the timeline reschedules on every
/// visibility change; Diagnostics reads the counters. The shared
/// instance serves the open thread (cache keys are URL+message, so
/// cross-chat fills dedupe naturally).
@MainActor
public final class ImagePreloadStore: ObservableObject {
    public static let shared = ImagePreloadStore()

    @Published public private(set) var stats = ImagePreloader.Stats()
    private let preloader: ImagePreloader

    public init(
        cache: RichMediaCache = .shared,
        maxConcurrent: Int = ImagePreloadPolicy.maxConcurrent
    ) {
        preloader = ImagePreloader(cache: cache, maxConcurrent: maxConcurrent)
    }

    /// Reschedule around the current viewport (see ImagePreloader).
    public func update(messages: [ChatMessage], visibleIDs: Set<String>) {
        Task {
            await preloader.update(messages: messages, visibleIDs: visibleIDs)
            stats = await preloader.snapshot()
        }
    }
}
