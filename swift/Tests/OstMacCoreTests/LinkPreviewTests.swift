// LinkPreviewTests.swift — om-linkpreview: candidate mining, https-only
// sanitize + tracking-strip, title parse, cache/dedupe, timeout, collapse.
import XCTest

@testable import OstMacCore

private final class PreviewURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    func record(_ u: String) { lock.lock(); urls.append(u); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
}

@MainActor
final class LinkPreviewTests: XCTestCase {
    // MARK: - Candidate mining (parse)

    func testFirstCandidateFromContent() {
        let m = ChatMessage(
            id: "m", sender: "A", timestamp: "t",
            content: "see https://example.com/a and https://example.com/b")
        XCTAssertEqual(
            LinkPreviewParse.firstCandidate(for: m), "https://example.com/a")
    }

    func testFirstCandidatePrefersRawAnchor() {
        // Anchor text hides the URL: the authored href still unfurls.
        let m = ChatMessage(
            id: "m", sender: "A", timestamp: "t",
            content: "click here",
            raw: #"<p><a href="https://long.example/x?y=1">click here</a></p>"#)
        XCTAssertEqual(
            LinkPreviewParse.firstCandidate(for: m), "https://long.example/x?y=1")
    }

    func testFirstCandidateNone() {
        XCTAssertNil(LinkPreviewParse.firstCandidate(
            content: "no links here", raw: nil))
        XCTAssertNil(LinkPreviewParse.firstCandidate(
            content: "bare www.example.com has no scheme", raw: nil))
        XCTAssertNil(LinkPreviewParse.firstCandidate(content: "", raw: nil))
        let m = ChatMessage(id: "m", sender: "A", timestamp: "t", content: "hi")
        XCTAssertNil(LinkPreviewParse.firstCandidate(for: m))
    }

    func testFirstURLSpanTrimsSentencePunctuation() {
        XCTAssertEqual(
            LinkPreviewParse.firstURLSpan(in: "see https://example.com/page."),
            "https://example.com/page")
        XCTAssertEqual(
            LinkPreviewParse.firstURLSpan(in: "wow, https://example.com/a, ok?"),
            "https://example.com/a")
        XCTAssertEqual(
            LinkPreviewParse.firstURLSpan(in: "(https://example.com/wrapped)"),
            "https://example.com/wrapped")
        // Balanced parens (Wikipedia-style) survive.
        XCTAssertEqual(
            LinkPreviewParse.firstURLSpan(in: "https://example.com/wiki/X_(disambig) here"),
            "https://example.com/wiki/X_(disambig)")
    }

    func testFirstURLSpanHttpIsStillACandidate() {
        // http surfaces as a candidate; the sanitizer collapses it later
        // without ever fetching (collapse test pins the no-fetch part).
        XCTAssertEqual(
            LinkPreviewParse.firstURLSpan(in: "old http://example.com/x link"),
            "http://example.com/x")
    }

    // MARK: - Sanitize (https-only, no tracking params)

    func testSanitizedKeepsHTTPS() {
        let url = LinkPreviewParse.sanitizedURL(from: "https://example.com/a?x=1#frag")
        XCTAssertEqual(url?.absoluteString, "https://example.com/a?x=1#frag")
    }

    func testSanitizedStripsTrackingParams() {
        let url = LinkPreviewParse.sanitizedURL(from:
            "https://example.com/p?utm_source=x&x=1&fbclid=abc&GCLID=def&utm_medium=y")
        XCTAssertEqual(url?.absoluteString, "https://example.com/p?x=1")
    }

    func testSanitizedDropsEmptyQuery() {
        let url = LinkPreviewParse.sanitizedURL(from: "https://example.com/p?utm_source=x")
        XCTAssertEqual(url?.absoluteString, "https://example.com/p")
    }

    func testSanitizedRejectsNonHTTPS() {
        XCTAssertNil(LinkPreviewParse.sanitizedURL(from: "http://example.com/x"))
        XCTAssertNil(LinkPreviewParse.sanitizedURL(from: "ftp://example.com/x"))
        XCTAssertNil(LinkPreviewParse.sanitizedURL(from: "file:///etc/passwd"))
        XCTAssertNil(LinkPreviewParse.sanitizedURL(from: "not a url"))
        XCTAssertNil(LinkPreviewParse.sanitizedURL(from: ""))
        XCTAssertNil(LinkPreviewParse.sanitizedURL(from: "https://"))
    }

    func testSanitizedAcceptsUppercaseScheme() {
        let url = LinkPreviewParse.sanitizedURL(from: "HTTPS://Example.COM/X")
        XCTAssertEqual(url?.scheme?.lowercased(), "https")
        XCTAssertNotNil(url?.host)
    }

    // MARK: - Title parse

    func testTitleFromTitleTag() {
        let html = "<html><head><title>  Hello  World </title></head></html>"
        XCTAssertEqual(LinkPreviewParse.title(fromHTML: html), "Hello World")
    }

    func testTitleDecodesEntitiesAndCollapses() {
        let html = "<TITLE>Fish &amp; Chips\n\tSpecial</TITLE>"
        XCTAssertEqual(LinkPreviewParse.title(fromHTML: html), "Fish & Chips Special")
    }

    func testTitleCapsLength() {
        let long = String(repeating: "a", count: 500)
        let html = "<title>\(long)</title>"
        let got = LinkPreviewParse.title(fromHTML: html)
        XCTAssertEqual(got?.count, LinkPreviewParse.maxTitleLength)
    }

    func testTitleFallsBackToOgTitle() {
        let html = """
        <html><head><meta property="og:title" content="OG &quot;Title&quot;"></head></html>
        """
        XCTAssertEqual(LinkPreviewParse.title(fromHTML: html), "OG \"Title\"")
    }

    func testTitlePrefersTitleTagOverOg() {
        let html = """
        <title>Real</title><meta name="og:title" content="OG">
        """
        XCTAssertEqual(LinkPreviewParse.title(fromHTML: html), "Real")
    }

    func testTitleNilWhenAbsent() {
        XCTAssertNil(LinkPreviewParse.title(fromHTML: "<html><body>no title</body></html>"))
        XCTAssertNil(LinkPreviewParse.title(fromHTML: "<title>   </title>"))
        XCTAssertNil(LinkPreviewParse.title(fromHTML: ""))
    }

    // MARK: - Cache

    func testCacheFetchesOnce() async throws {
        let cache = LinkPreviewCache()
        let calls = Counter()
        let html = Data("<title>Cached</title>".utf8)
        let fetcher: LinkPreviewCache.Fetcher = { _ in calls.inc(); return html }
        let a = try await cache.preview(for: "https://example.com/p", fetcher: fetcher)
        let b = try await cache.preview(for: "https://example.com/p", fetcher: fetcher)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.title, "Cached")
        XCTAssertEqual(a.host, "example.com")
        XCTAssertEqual(calls.count, 1)
    }

    func testCacheKeysOnSanitizedURL() async throws {
        // Tracking variants share one entry; the fetcher only ever sees
        // the cleaned URL (no tracking params sent).
        let cache = LinkPreviewCache()
        let seen = PreviewURLBox()
        let fetcher: LinkPreviewCache.Fetcher = {
            seen.record($0.absoluteString)
            return Data("<title>T</title>".utf8)
        }
        _ = try await cache.preview(
            for: "https://example.com/p?utm_source=x&fbclid=y", fetcher: fetcher)
        _ = try await cache.preview(for: "https://example.com/p", fetcher: fetcher)
        XCTAssertEqual(seen.all, ["https://example.com/p"])
    }

    func testCacheDedupesConcurrentFetch() async throws {
        let cache = LinkPreviewCache()
        let calls = Counter()
        let fetcher: LinkPreviewCache.Fetcher = { _ in
            calls.inc()
            try await Task.sleep(nanoseconds: 50_000_000)
            return Data("<title>D</title>".utf8)
        }
        async let a = cache.preview(for: "https://example.com/c", fetcher: fetcher)
        async let b = cache.preview(for: "https://example.com/c", fetcher: fetcher)
        async let c = cache.preview(for: "https://example.com/c", fetcher: fetcher)
        let got = try await [a, b, c]
        XCTAssertEqual(got.map(\.title), ["D", "D", "D"])
        XCTAssertEqual(calls.count, 1)
    }

    func testCacheFailureNotCached() async {
        let cache = LinkPreviewCache()
        let calls = Counter()
        let fetcher: LinkPreviewCache.Fetcher = { _ in
            calls.inc()
            throw LinkPreviewError.network("boom")
        }
        for _ in 0 ..< 2 {
            do {
                _ = try await cache.preview(for: "https://example.com/f", fetcher: fetcher)
                XCTFail("expected throw")
            } catch { /* expected */ }
        }
        XCTAssertEqual(calls.count, 2)
    }

    // MARK: - Timeout

    func testTimeoutThrows() async {
        let cache = LinkPreviewCache()
        let fetcher: LinkPreviewCache.Fetcher = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return Data("<title>slow</title>".utf8)
        }
        do {
            _ = try await cache.preview(
                for: "https://example.com/slow", fetcher: fetcher, timeoutSeconds: 0.05)
            XCTFail("expected timeout")
        } catch let e as LinkPreviewError {
            XCTAssertEqual(e, .timeout)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFastFetcherBeatsTimeout() async throws {
        let cache = LinkPreviewCache()
        let p = try await cache.preview(
            for: "https://example.com/fast",
            fetcher: { _ in Data("<title>Fast</title>".utf8) },
            timeoutSeconds: 5)
        XCTAssertEqual(p.title, "Fast")
    }

    // MARK: - Collapse (silent: plain link stays, no row)

    func testModelLoads() async {
        let model = LinkPreviewModel(
            urlString: "https://example.com/ok",
            cache: LinkPreviewCache(),
            fetcher: { _ in Data("<title>OK</title>".utf8) })
        XCTAssertEqual(model.phase, .loading)
        await model.reload()
        XCTAssertEqual(
            model.phase,
            .loaded(LinkPreview(
                url: "https://example.com/ok", title: "OK", host: "example.com")))
    }

    func testModelCollapsesOnFetchError() async {
        let model = LinkPreviewModel(
            urlString: "https://example.com/err",
            cache: LinkPreviewCache(),
            fetcher: { _ in throw LinkPreviewError.network("down") })
        await model.reload()
        XCTAssertEqual(model.phase, .collapsed)
    }

    func testModelCollapsesOnTimeout() async {
        let model = LinkPreviewModel(
            urlString: "https://example.com/slow",
            cache: LinkPreviewCache(),
            fetcher: { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Data("<title>x</title>".utf8)
            },
            timeoutSeconds: 0.05)
        await model.reload()
        XCTAssertEqual(model.phase, .collapsed)
    }

    func testModelCollapsesOnNonHTTPSWithoutFetching() async {
        let calls = Counter()
        let model = LinkPreviewModel(
            urlString: "http://example.com/plain",
            cache: LinkPreviewCache(),
            fetcher: { _ in calls.inc(); return Data() })
        await model.reload()
        XCTAssertEqual(model.phase, .collapsed)
        XCTAssertEqual(calls.count, 0) // never fetched
    }

    func testModelCollapsesOnMissingTitle() async {
        let model = LinkPreviewModel(
            urlString: "https://example.com/notitle",
            cache: LinkPreviewCache(),
            fetcher: { _ in Data("<html><body>no title</body></html>".utf8) })
        await model.reload()
        XCTAssertEqual(model.phase, .collapsed)
    }

    // MARK: - Open guard (injected opener; default never runs under test)

    func testOpenTargetHTTPSOnly() {
        let ok = LinkPreview(url: "https://example.com/x", title: "T", host: "example.com")
        XCTAssertEqual(
            LinkPreviewOpen.target(for: ok)?.absoluteString, "https://example.com/x")
        let http = LinkPreview(url: "http://example.com/x", title: "T", host: "example.com")
        XCTAssertNil(LinkPreviewOpen.target(for: http))
        let weird = LinkPreview(url: "javascript:alert(1)", title: "T", host: "")
        XCTAssertNil(LinkPreviewOpen.target(for: weird))
    }
}
