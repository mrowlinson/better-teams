// RichMediaTests.swift — om-richmedia: img mining, emoji shortcodes,
// cache keys/dedupe/persistence, demo fixtures, image load states.
import AppKit
import XCTest

@testable import OstMacCore

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func inc() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@MainActor
final class RichMediaTests: XCTestCase {
    // MARK: - <img> mining

    func testImagesTeamsAmsURL() {
        let raw = #"<p>see this</p><p><img src="https://amer.ng.msg.teams.microsoft.com/v1/objects/0-abc/views/imgo" alt="pic"></p>"#
        let imgs = MessageRender.images(fromRaw: raw)
        XCTAssertEqual(imgs.count, 1)
        XCTAssertEqual(imgs[0].url, "https://amer.ng.msg.teams.microsoft.com/v1/objects/0-abc/views/imgo")
        XCTAssertEqual(imgs[0].alt, "pic")
        XCTAssertFalse(imgs[0].isEmoticon)
    }

    func testImagesQuotingAndCase() {
        let raw = "<P><IMG SRC='https://h/a.png' ALT='A &amp; B'><img src=https://h/b.png></P>"
        let imgs = MessageRender.images(fromRaw: raw)
        XCTAssertEqual(imgs.map(\.url), ["https://h/a.png", "https://h/b.png"])
        XCTAssertEqual(imgs[0].alt, "A & B")
        XCTAssertEqual(imgs[1].alt, "")
    }

    func testImagesMissingSrcDropped() {
        XCTAssertEqual(MessageRender.images(fromRaw: #"<p><img alt="no src"></p>"#), [])
        XCTAssertEqual(MessageRender.images(fromRaw: "<p>no tags</p>"), [])
        XCTAssertEqual(MessageRender.images(fromRaw: nil), [])
        XCTAssertEqual(MessageRender.images(fromRaw: ""), [])
    }

    // MARK: - Emoticon detection

    func testEmoticonSmallDimensions() {
        let raw = #"<img src="demo://photo-1" width="20" height="20" alt="(smile)">"#
        let imgs = MessageRender.images(fromRaw: raw)
        XCTAssertEqual(imgs.count, 1)
        XCTAssertTrue(imgs[0].isEmoticon)
    }

    func testEmoticonMarkerAndAlt() {
        XCTAssertTrue(MessageRender.images(
            fromRaw: #"<img src="https://h/e.png" class="emoticon">"#)[0].isEmoticon)
        XCTAssertTrue(MessageRender.images(
            fromRaw: #"<img src="https://h/e.png" alt="(thumbsup)">"#)[0].isEmoticon)
    }

    func testPhotoNotEmoticon() {
        XCTAssertFalse(MessageRender.images(
            fromRaw: #"<img src="https://h/p.png" width="640" height="480">"#)[0].isEmoticon)
        // Percent sizes never count as small.
        XCTAssertFalse(MessageRender.images(
            fromRaw: #"<img src="https://h/p.png" width="100%" height="100%">"#)[0].isEmoticon)
        XCTAssertFalse(MessageRender.images(
            fromRaw: #"<img src="https://h/p.png">"#)[0].isEmoticon)
    }

    // MARK: - Emoji shortcodes

    func testShortcodeExpansion() {
        XCTAssertEqual(MessageRender.expandShortcodes("(smile)"), "🙂")
        XCTAssertEqual(MessageRender.expandShortcodes("a (SMILE) b"), "a 🙂 b")
        XCTAssertEqual(
            MessageRender.expandShortcodes("(thumbsup) ok (clap)"),
            "👍 ok 👏")
        // Unicode passes through.
        XCTAssertEqual(MessageRender.expandShortcodes("🚀 up"), "🚀 up")
    }

    func testShortcodeUnknownUntouched() {
        XCTAssertEqual(MessageRender.expandShortcodes("(see note)"), "(see note)")
        XCTAssertEqual(MessageRender.expandShortcodes("(boguscode)"), "(boguscode)")
        XCTAssertEqual(MessageRender.expandShortcodes("()"), "()")
        XCTAssertEqual(MessageRender.expandShortcodes("(smile"), "(smile")
    }

    func testShortcodeSkipsBackticks() {
        XCTAssertEqual(
            MessageRender.expandShortcodes("run `(smile)` now (smile)"),
            "run `(smile)` now 🙂")
    }

    func testRenderTextOnMessage() {
        let m = ChatMessage(id: "m", sender: "A", timestamp: "t", content: "hi (wave)")
        XCTAssertEqual(MessageRender.renderText(for: m), "hi 👋")
    }

    func testAttributedBodyExpandsAndKeepsMention() {
        let m = ChatMessage(
            id: "m", sender: "A", timestamp: "t",
            content: "Hi @Bo (smile)",
            raw: #"<p>Hi <at id="8:b">@Bo</at> (smile)</p>"#)
        let a = MessageRender.attributedBody(for: m)
        XCTAssertEqual(String(a.characters), "Hi @Bo 🙂")
        let styled = a.runs.filter { $0.isStyledSpan }
        XCTAssertEqual(styled.count, 1)
    }

    // MARK: - Cache keys

    func testCacheKeyStableAndScoped() {
        let a = RichMediaCache.key(url: "https://h/x.png", messageID: "m1")
        XCTAssertEqual(a, RichMediaCache.key(url: "https://h/x.png", messageID: "m1"))
        XCTAssertEqual(a.count, 64) // sha256 hex
        // Same URL, different message -> different key (URL+msg).
        XCTAssertNotEqual(a, RichMediaCache.key(url: "https://h/x.png", messageID: "m2"))
        XCTAssertNotEqual(a, RichMediaCache.key(url: "https://h/y.png", messageID: "m1"))
    }

    func testCacheDedupesConcurrentFetch() async throws {
        let cache = RichMediaCache(diskDir: nil)
        let calls = Counter()
        let bytes = Data([1, 2, 3, 4])
        let fetcher: RichMediaCache.Fetcher = { _ in
            calls.inc()
            try await Task.sleep(nanoseconds: 50_000_000)
            return bytes
        }
        async let a = cache.data(url: "https://h/x.png", messageID: "m1", fetcher: fetcher)
        async let b = cache.data(url: "https://h/x.png", messageID: "m1", fetcher: fetcher)
        async let c = cache.data(url: "https://h/x.png", messageID: "m1", fetcher: fetcher)
        let got = try await [a, b, c]
        XCTAssertEqual(got, [bytes, bytes, bytes])
        XCTAssertEqual(calls.count, 1)
        // Second wave hits memory: still 1.
        _ = try await cache.data(url: "https://h/x.png", messageID: "m1", fetcher: fetcher)
        XCTAssertEqual(calls.count, 1)
    }

    func testCacheFailureNotCached() async {
        let cache = RichMediaCache(diskDir: nil)
        let calls = Counter()
        let fetcher: RichMediaCache.Fetcher = { _ in
            calls.inc()
            throw MediaFetchError.failed("boom")
        }
        for _ in 0 ..< 2 {
            do {
                _ = try await cache.data(url: "https://h/x.png", messageID: "m1", fetcher: fetcher)
                XCTFail("expected throw")
            } catch { /* expected */ }
        }
        XCTAssertEqual(calls.count, 2)
    }

    func testCacheDiskPersistsAcrossInstances() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("om-rm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data([9, 9, 9])
        let c1 = RichMediaCache(diskDir: dir)
        _ = try await c1.data(url: "https://h/x.png", messageID: "m1", fetcher: { _ in bytes })
        // Fresh instance (cold memory) reads disk without fetching.
        let c2 = RichMediaCache(diskDir: dir)
        let hit = try await c2.data(
            url: "https://h/x.png", messageID: "m1",
            fetcher: { _ in throw MediaFetchError.failed("must not refetch") })
        XCTAssertEqual(hit, bytes)
    }

    // MARK: - Disk caps (om-s3-mediahot)

    private func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("om-rmcap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func plantFile(
        in dir: URL, name: String, bytes: Int, age: TimeInterval
    ) throws {
        let u = dir.appendingPathComponent(name, isDirectory: false)
        try Data(repeating: 0xAB, count: bytes).write(to: u, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: u.path)
    }

    private func diskNames(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    func testDiskFileCapTrimsOldest() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try plantFile(in: dir, name: "oldest", bytes: 10, age: 300)
        try plantFile(in: dir, name: "middle", bytes: 10, age: 200)
        try plantFile(in: dir, name: "newer", bytes: 10, age: 100)
        let cache = RichMediaCache(diskDir: dir, diskCapFiles: 3)
        _ = try await cache.data(
            url: "https://h/fresh.png", messageID: "m",
            fetcher: { _ in Data(repeating: 1, count: 10) })
        // 4 entries vs cap 3: exactly the oldest goes.
        let names = try diskNames(in: dir)
        XCTAssertEqual(names.count, 3)
        XCTAssertFalse(names.contains("oldest"))
        XCTAssertTrue(names.contains("middle"))
        let usage = await cache.diskUsage()
        XCTAssertEqual(usage.files, 3)
    }

    func testDiskTrimIsLRU() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two disk entries under their real keys; A is older than B.
        let keyA = RichMediaCache.key(url: "https://h/a.png", messageID: "m")
        let keyB = RichMediaCache.key(url: "https://h/b.png", messageID: "m")
        try plantFile(in: dir, name: keyA, bytes: 8, age: 300)
        try plantFile(in: dir, name: keyB, bytes: 8, age: 200)
        let cache = RichMediaCache(diskDir: dir, diskCapFiles: 2)
        // Reading A refreshes its recency (served from disk, no fetch).
        let hit = try await cache.data(
            url: "https://h/a.png", messageID: "m",
            fetcher: { _ in throw MediaFetchError.failed("must not refetch") })
        XCTAssertEqual(hit, Data(repeating: 0xAB, count: 8))
        // A new write overflows the cap: B (least-recently-read) goes, A stays.
        _ = try await cache.data(
            url: "https://h/c.png", messageID: "m",
            fetcher: { _ in Data(repeating: 3, count: 8) })
        let names = try diskNames(in: dir)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains(keyA))
        XCTAssertFalse(names.contains(keyB))
    }

    func testDiskByteCapTrims() async throws {
        let dir = try scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try plantFile(in: dir, name: "stale", bytes: 20, age: 300)
        let cache = RichMediaCache(diskDir: dir, diskCapBytes: 25)
        _ = try await cache.data(
            url: "https://h/fresh.png", messageID: "m",
            fetcher: { _ in Data(repeating: 1, count: 10) })
        // 30 bytes vs cap 25: the stale 20 goes, the fresh 10 stays.
        let usage = await cache.diskUsage()
        XCTAssertEqual(usage.files, 1)
        XCTAssertEqual(usage.bytes, 10)
        XCTAssertFalse(try diskNames(in: dir).contains("stale"))
    }

    // MARK: - Demo fixtures

    func testDemoMediaDecodes() throws {
        for url in [DemoMedia.photo1, DemoMedia.photo2] {
            let d = try DemoMedia.data(for: url)
            XCTAssertGreaterThan(d.count, 1000)
            let img = NSImage(data: d)
            XCTAssertNotNil(img)
            XCTAssertEqual(img?.size, NSSize(width: 480, height: 320))
        }
        XCTAssertThrowsError(try DemoMedia.data(for: "demo://missing"))
    }

    func testMediaDemoThreadShape() {
        let msgs = DemoData.mediaMessages()
        XCTAssertEqual(msgs.count, 7) // +media-7 animated GIF (om-gif-playback)
        // Captioned photo + image-only + failure + emoticon raws.
        XCTAssertEqual(MessageRender.images(fromRaw: msgs[1].raw).count, 1)
        XCTAssertEqual(msgs[2].content, "")
        XCTAssertEqual(MessageRender.images(fromRaw: msgs[2].raw).count, 1)
        XCTAssertEqual(MessageRender.images(fromRaw: msgs[4].raw).count, 1)
        XCTAssertTrue(MessageRender.images(fromRaw: msgs[5].raw).first?.isEmoticon ?? false)
        // Sidebar row tracks the tail.
        let row = DemoData.mediaChat()
        XCTAssertEqual(row.chatId, DemoData.mediaID)
        XCTAssertEqual(row.last_message_preview, msgs.last?.content)
        XCTAssertTrue(DemoData.chats.contains(where: { $0.id == DemoData.mediaID }))
        XCTAssertEqual(DemoData.messages(for: DemoData.mediaID).count, 7)
    }

    // MARK: - Image load states

    func testRemoteImageModelLoads() async throws {
        let bytes = try DemoMedia.data(for: DemoMedia.photo1)
        let model = RemoteImageModel(
            url: DemoMedia.photo1, messageID: "m1",
            cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in bytes })
        XCTAssertEqual(model.phase, .loading)
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNotNil(model.image)
    }

    func testRemoteImageModelFailsThenRetries() async {
        let calls = Counter()
        let model = RemoteImageModel(
            url: "demo://missing", messageID: "m1",
            cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in
                calls.inc()
                throw MediaFetchError.failed("nope")
            })
        await model.reload()
        if case .failed = model.phase {} else {
            XCTFail("expected failed, got \(model.phase)")
        }
        XCTAssertNil(model.image)
        await model.reload()
        XCTAssertEqual(calls.count, 2) // retry refetches
    }

    func testRemoteImageModelRejectsNonImage() async {
        let model = RemoteImageModel(
            url: "https://h/x", messageID: "m1",
            cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in Data("not png".utf8) })
        await model.reload()
        XCTAssertEqual(model.phase, .failed("not an image"))
    }

    // MARK: - Realtime raw passthrough

    func testRealtimeRawRoundTrip() throws {
        let withRaw = try JSONDecoder().decode(
            RealtimeMessage.self,
            from: Data(
                """
                {"chat_id":"19:a","id":"m1","sender":"S","text":"hi",
                 "time":"t","is_edit":false,"raw":"<p>hi <img src=\\"https://h/x.png\\"></p>"}
                """.utf8))
        XCTAssertEqual(MessageRender.images(fromRaw: withRaw.raw).count, 1)
        XCTAssertEqual(withRaw.asChatMessage.raw?.contains("<img"), true)
        // Old core builds omit raw: text-only, no crash.
        let legacy = try JSONDecoder().decode(
            RealtimeMessage.self,
            from: Data(
                """
                {"chat_id":"19:a","id":"m1","sender":"S","text":"hi",
                 "time":"t","is_edit":false}
                """.utf8))
        XCTAssertNil(legacy.raw)
        XCTAssertEqual(legacy.asChatMessage.content, "hi")
    }

    // MARK: - Disk dir rename (om-meetings-dirname follow-up)

    private func scratchAppSupport() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-mediacache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testDiskDirBaseURLUsesAppIdentityName() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(
            RichMediaCache.diskDirBaseURL(under: base).path,
            base.appendingPathComponent("Better Teams/MediaCache").path)
        XCTAssertEqual(
            RichMediaCache.legacyDiskDirBaseURL(under: base).path,
            base.appendingPathComponent("OstMac/MediaCache").path)
    }

    func testMigrateMovesLegacyCacheDir() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let legacy = RichMediaCache.legacyDiskDirBaseURL(under: base)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("px".utf8).write(to: legacy.appendingPathComponent("ab12.png"))
        XCTAssertTrue(RichMediaCache.migrateLegacyDirectory(under: base))
        let fresh = RichMediaCache.diskDirBaseURL(under: base)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(
            try Data(contentsOf: fresh.appendingPathComponent("ab12.png")), Data("px".utf8))
        XCTAssertFalse(RichMediaCache.migrateLegacyDirectory(under: base)) // idempotent
    }

    func testMigrateNoopWhenLegacyMissing() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(RichMediaCache.migrateLegacyDirectory(under: base))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: RichMediaCache.diskDirBaseURL(under: base).path))
    }

    func testMigrateNoopWhenNewDirExists() throws {
        let base = try scratchAppSupport()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let legacy = RichMediaCache.legacyDiskDirBaseURL(under: base)
        let fresh = RichMediaCache.diskDirBaseURL(under: base)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: legacy.appendingPathComponent("o.png"))
        try Data("new".utf8).write(to: fresh.appendingPathComponent("n.png"))
        XCTAssertFalse(RichMediaCache.migrateLegacyDirectory(under: base))
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("o.png").path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.appendingPathComponent("n.png").path))
    }
}
