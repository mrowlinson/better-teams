// LinkPreview.swift — om-linkpreview lane: first-URL unfurl title row in bubbles.
//
// The first URL in a message unfurls to one title row under the bubble
// text: page title + host, fetched async, cached, https-only. Tap opens
// the cleaned URL through an injected opener (default: guarded browser
// open). Any failure — timeout, non-https, missing title, fetch error —
// collapses silently: the plain inline link stays, no row appears.
//
// Privacy: tracking params (utm_*, fbclid, gclid, …) are stripped before
// the fetch AND before the tap-open, so they are never sent anywhere.
// Only the remaining query survives; fragments are untouched (never sent
// to servers).
import AppKit
import Foundation
import Combine

/// One unfurled link: sanitized https URL + page title + host caption.
public struct LinkPreview: Sendable, Equatable {
    /// Fetch/open URL: https, tracking params stripped. Canonical cache key.
    public let url: String
    /// Page `<title>` (or og:title fallback), decoded, collapsed, capped.
    public let title: String
    /// Lowercased host for the caption row.
    public let host: String

    public init(url: String, title: String, host: String) {
        self.url = url
        self.title = title
        self.host = host
    }
}

public enum LinkPreviewError: Error, Sendable, Equatable {
    case noURL
    case notHTTPS
    case timeout
    case badResponse(String)
    case network(String)
    case noTitle
}

// MARK: - Parsing (pure)

public enum LinkPreviewParse {
    /// Title cap (bot-row parity: long titles truncate, never wrap forever).
    public static let maxTitleLength = 140

    /// Known click-ID params, stripped alongside every `utm_*` param.
    /// Matched case-insensitively; all other params survive.
    public static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gbraid", "wbraid", "dclid", "msclkid",
        "mc_cid", "mc_eid", "igshid", "srsltid", "ttclid", "twclid",
        "_hsenc", "_hsmi", "irclickid", "vero_id", "mkt_tok",
    ]

    public static func isTrackingParam(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasPrefix("utm_") || trackingParams.contains(n)
    }

    /// Sanitized fetch/open URL, or nil for anything non-https (http,
    /// custom schemes, missing host, unparseable). Tracking params are
    /// dropped; every other param and the fragment survive.
    public static func sanitizedURL(from raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: t),
              comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty
        else { return nil }
        var c = comps
        if let items = c.queryItems {
            let kept = items.filter { !isTrackingParam($0.name) }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        return c.url
    }

    /// First URL candidate for a message: the first raw `<a href>` in raw
    /// order (authored links win — anchor text may hide the URL), else the
    /// first `https?://` span in the visible text. Returns the RAW string
    /// (still unsanitized — http candidates collapse later without ever
    /// fetching); nil when the message carries no link.
    public static func firstCandidate(for message: ChatMessage) -> String? {
        firstCandidate(content: message.content, raw: message.raw)
    }

    /// String-level candidate: `content` is the bubble-visible text.
    public static func firstCandidate(content: String, raw: String?) -> String? {
        if let raw, let href = MessageRender.links(in: raw).first?.href,
           !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return href
        }
        return firstURLSpan(in: content)
    }

    /// First `https?://…` span: cut at whitespace or an HTML/JSON/markdown
    /// delimiter, then trailing sentence punctuation (`. , ; : ! ?`) and
    /// unbalanced `)` are trimmed (balanced parens — Wikipedia-style —
    /// survive). Nil when no scheme is present.
    public static func firstURLSpan(in text: String) -> String? {
        var best: String.Index?
        for scheme in ["https://", "http://"] {
            if let r = text.range(of: scheme, options: .caseInsensitive),
               best == nil || r.lowerBound < best!
            {
                best = r.lowerBound
            }
        }
        guard let start = best else { return nil }
        var end = start
        while end < text.endIndex {
            let c = text[end]
            if c.isWhitespace || c == "\"" || c == "'" || c == "<" || c == ">"
                || c == "[" || c == "]" || c == "{" || c == "}" || c == "\\" || c == "`"
            {
                break
            }
            end = text.index(after: end)
        }
        var url = String(text[start ..< end])
        while let last = url.last, ".,;:!?".contains(last) {
            url.removeLast()
        }
        // Unbalanced trailing parens are sentence wrapping, not the URL.
        while url.hasSuffix(")"), !isParenBalanced(url) {
            url.removeLast()
        }
        guard !url.isEmpty, URL(string: url) != nil else { return nil }
        return url
    }

    /// True when every `)` in `s` is matched by an earlier `(`.
    static func isParenBalanced(_ s: String) -> Bool {
        var depth = 0
        for c in s {
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return true
    }

    /// Page title from HTML bytes: `<title>` first, `og:title` meta
    /// fallback. Tags stripped, entities decoded, whitespace collapsed to
    /// single spaces, capped at 140 chars. Nil when blank/absent.
    public static func title(fromHTML html: String) -> String? {
        if let raw = MessageRender.innerTexts(of: "title", in: html).first,
           let t = cleanTitle(raw)
        {
            return t
        }
        return ogTitle(in: html).flatMap(cleanTitle)
    }

    static func cleanTitle(_ raw: String) -> String? {
        let collapsed = MessageRender.decodeEntities(MessageRender.stripTags(raw))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxTitleLength))
    }

    /// `content` of the first `<meta property/name="og:title" …>` tag.
    /// Tag/attr names are case-insensitive (same parser as img mining).
    static func ogTitle(in html: String) -> String? {
        var rest = html[...]
        while let s = rest.range(of: "<meta", options: .caseInsensitive),
              let gt = rest[s.upperBound...].firstIndex(of: ">")
        {
            let attrs = MessageRender.attributes(of: String(rest[s.lowerBound ... gt]))
            rest = rest[rest.index(after: gt)...]
            let key = (attrs["property"] ?? attrs["name"] ?? "").lowercased()
            if key == "og:title",
               let content = attrs["content"]?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty
            {
                return content
            }
        }
        return nil
    }
}

// MARK: - Fetch + cache

public actor LinkPreviewCache {
    public static let shared = LinkPreviewCache()

    /// HTML byte source for a sanitized https URL. Injectable so tests
    /// never touch the network.
    public typealias Fetcher = @Sendable (URL) async throws -> Data

    /// Default per-fetch ceiling (the task-group race AND the session
    /// config enforce it; see `preview(for:)`).
    public static let defaultTimeoutSeconds = 8.0
    /// Title mining reads at most this prefix (the `<title>` lives early).
    public static let maxBytes = 262_144

    private var store: [String: LinkPreview] = [:]
    private var inFlight: [String: Task<LinkPreview, Error>] = [:]

    public init() {}

    /// Live fetch: plain URLSession data task with the lane timeout and
    /// a bot-honest user agent. Non-2xx is a bad response (collapses).
    public static func liveFetcher(url: URL) async throws -> Data {
        var req = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: defaultTimeoutSeconds)
        req.setValue("OstMac/1.0 (link preview)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw LinkPreviewError.badResponse("HTTP \(http.statusCode)")
        }
        return data
    }

    /// Cached preview for a sanitized-URL key, or nil (no fetch).
    public func cached(urlString: String) -> LinkPreview? {
        store[urlString]
    }

    /// Account switch (d1-accounts): drop cached previews + in-flight
    /// fetches (fetched under the old account's network context).
    public func resetForAccount() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
        store = [:]
    }

    /// Cached preview, fetching once on miss. Concurrent callers for the
    /// same sanitized URL share the in-flight fetch; failures are never
    /// cached (a retry refetches). Non-https input throws `.notHTTPS`
    /// WITHOUT fetching; a slow fetcher throws `.timeout`.
    public func preview(
        for rawURL: String,
        fetcher: @escaping Fetcher = { try await LinkPreviewCache.liveFetcher(url: $0) },
        timeoutSeconds: Double = defaultTimeoutSeconds
    ) async throws -> LinkPreview {
        guard let url = LinkPreviewParse.sanitizedURL(from: rawURL) else {
            throw LinkPreviewError.notHTTPS
        }
        let key = url.absoluteString
        if let hit = store[key] { return hit }
        if let t = inFlight[key] { return try await t.value }
        let task: Task<LinkPreview, Error> = Task {
            try await Self.fetch(url: url, fetcher: fetcher, timeoutSeconds: timeoutSeconds)
        }
        inFlight[key] = task
        do {
            let p = try await task.value
            store[key] = p
            inFlight[key] = nil
            return p
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    static func fetch(
        url: URL, fetcher: @escaping Fetcher, timeoutSeconds: Double
    ) async throws -> LinkPreview {
        let data: Data
        do {
            data = try await withTimeout(seconds: timeoutSeconds) { try await fetcher(url) }
        } catch let e as LinkPreviewError {
            throw e
        } catch {
            throw LinkPreviewError.network(String(describing: error))
        }
        let html = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        guard let title = LinkPreviewParse.title(fromHTML: html) else {
            throw LinkPreviewError.noTitle
        }
        return LinkPreview(
            url: url.absoluteString,
            title: title,
            host: (url.host ?? "").lowercased())
    }

    /// First-settled race: the operation, or `.timeout` after `seconds`.
    /// The loser's work is cancelled.
    static func withTimeout<T: Sendable>(
        seconds: Double,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw LinkPreviewError.timeout
            }
            guard let first = try await group.next() else {
                throw LinkPreviewError.timeout
            }
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Load state (collapses silently)

/// Load state for one unfurl slot. `.collapsed` renders nothing — the
/// bubble's plain inline link is the fallback, so failures are silent.
public enum LinkPreviewPhase: Sendable, Equatable {
    case loading
    case loaded(LinkPreview)
    case collapsed
}

@MainActor
public final class LinkPreviewModel: ObservableObject {
    @Published public private(set) var phase: LinkPreviewPhase = .loading
    public private(set) var urlString: String
    private let cache: LinkPreviewCache
    private let fetcher: LinkPreviewCache.Fetcher
    private let timeoutSeconds: Double

    public init(
        urlString: String,
        cache: LinkPreviewCache = .shared,
        fetcher: LinkPreviewCache.Fetcher? = nil,
        timeoutSeconds: Double = LinkPreviewCache.defaultTimeoutSeconds
    ) {
        self.urlString = urlString
        self.cache = cache
        self.fetcher = fetcher ?? { try await LinkPreviewCache.liveFetcher(url: $0) }
        self.timeoutSeconds = timeoutSeconds
    }

    /// Load once; no-op unless still waiting on the first load.
    public func load() {
        guard phase == .loading else { return }
        Task { await reload() }
    }

    /// Resolve (or re-resolve): any error collapses to the plain link.
    public func reload() async {
        phase = .loading
        do {
            let p = try await cache.preview(
                for: urlString, fetcher: fetcher, timeoutSeconds: timeoutSeconds)
            phase = .loaded(p)
        } catch {
            phase = .collapsed
        }
    }
}

// MARK: - Tap-open (injected, guarded default)

public enum LinkPreviewOpen {
    /// Guarded open target: the sanitized https URL, or nil for anything
    /// else (http/custom schemes never open from a preview row).
    public static func target(for preview: LinkPreview) -> URL? {
        guard let url = URL(string: preview.url),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }

    /// Default tap: guarded browser open. Tests inject their own opener
    /// and never call this (no browser under test).
    public static func `default`(_ url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        TeamsLinkRouter.open(url)
    }
}

// MARK: - Views (native macOS)

