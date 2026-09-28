// ImageFullResTests.swift — om-imgfull: viewer loads full-res, not thumbnail.
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class ImageFullResTests: XCTestCase {
    // MARK: - Full-res URL derivation

    func testFullResURLRewritesThumbViews() {
        XCTAssertEqual(
            ImageFullRes.fullResURL(
                for: "https://amer.ng.msg.teams.microsoft.com/v1/objects/0-abc/views/imgt1"),
            "https://amer.ng.msg.teams.microsoft.com/v1/objects/0-abc/views/imgo")
        XCTAssertEqual(
            ImageFullRes.fullResURL(
                for: "https://us-api.asm.skype.com/v1/objects/0-abc/views/imgt1"),
            "https://us-api.asm.skype.com/v1/objects/0-abc/views/imgo")
        // Query preserved across the rewrite.
        XCTAssertEqual(
            ImageFullRes.fullResURL(for: "https://h/v1/objects/0/views/imgt1?x=1"),
            "https://h/v1/objects/0/views/imgo?x=1")
        // Already full: untouched.
        XCTAssertEqual(
            ImageFullRes.fullResURL(for: "https://h/v1/objects/0/views/imgo"),
            "https://h/v1/objects/0/views/imgo")
        XCTAssertEqual(
            ImageFullRes.fullResURL(
                for: "https://euno-prod.asyncgw.teams.microsoft.com/v1/objects/0/views/imgpsh_fullsize"),
            "https://euno-prod.asyncgw.teams.microsoft.com/v1/objects/0/views/imgpsh_fullsize")
        // Demo fixtures: thumb -> -full render.
        XCTAssertEqual(
            ImageFullRes.fullResURL(for: DemoMedia.photo1), DemoMedia.photo1Full)
        XCTAssertEqual(
            ImageFullRes.fullResURL(for: DemoMedia.photo1Full), DemoMedia.photo1Full)
        // No view segment: untouched.
        XCTAssertEqual(
            ImageFullRes.fullResURL(for: "https://example.com/a.png"),
            "https://example.com/a.png")
    }

    // MARK: - Viewer loads full-res bytes

    func testViewerLoadsFullResNotThumb() async throws {
        let thumbData = try DemoMedia.data(for: DemoMedia.photo1) // 480x320
        let fullData = DemoMedia.render(seed: 1, width: 960, height: 640)
        let thumb = try XCTUnwrap(NSImage(data: thumbData))
        let cache = RichMediaCache(diskDir: nil)
        let seen = URLLog()
        let model = FullResImageModel(
            thumbURL: "https://h/v1/objects/0/views/imgt1", messageID: "m1",
            thumb: thumb, cache: cache,
            fetcher: { url in
                await seen.append(url)
                return fullData
            })
        XCTAssertEqual(model.fullURL, "https://h/v1/objects/0/views/imgo")
        XCTAssertEqual(model.phase, .loading)
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        // Full-res pixels on screen, not the thumbnail.
        XCTAssertEqual(model.image?.size, NSSize(width: 960, height: 640))
        // Fetched the full view exactly once; thumb never refetched.
        let urls = await seen.all()
        XCTAssertEqual(urls, ["https://h/v1/objects/0/views/imgo"])
    }

    func testViewerFailureKeepsThumbAndRetries() async throws {
        let thumb = try XCTUnwrap(NSImage(
            data: DemoMedia.data(for: DemoMedia.photo1)))
        let calls = Counter()
        let model = FullResImageModel(
            thumbURL: "https://h/v1/objects/0/views/imgt1", messageID: "m1",
            thumb: thumb, cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in
                calls.inc()
                throw MediaFetchError.failed("nope")
            })
        await model.reload()
        if case .failed = model.phase {} else {
            XCTFail("expected failed, got \(model.phase)")
        }
        XCTAssertNil(model.image)
        XCTAssertNotNil(model.thumb) // preview stays up behind the error
        await model.reload()
        XCTAssertEqual(calls.count, 2) // retry refetches
    }

    func testViewerFullResServedFromCache() async throws {
        let fullData = DemoMedia.render(seed: 2, width: 960, height: 640)
        let cache = RichMediaCache(diskDir: nil)
        let thumbURL = "https://h/v1/objects/0/views/imgt1"
        let primer = FullResImageModel(
            thumbURL: thumbURL, messageID: "m1", thumb: nil,
            cache: cache, fetcher: { _ in fullData })
        await primer.reload()
        XCTAssertEqual(primer.phase, .loaded)
        // Second open: throwing fetcher never fires, cache serves.
        let reopen = FullResImageModel(
            thumbURL: thumbURL, messageID: "m1", thumb: nil,
            cache: cache,
            fetcher: { _ in throw MediaFetchError.failed("must not refetch") })
        await reopen.reload()
        XCTAssertEqual(reopen.phase, .loaded)
        XCTAssertEqual(reopen.image?.size, NSSize(width: 960, height: 640))
    }

    // MARK: - Animated viewer (om-gif-playback)

    func testFullResModelLoadsGifClip() async throws {
        let bytes = try DemoMedia.data(for: DemoMedia.gif1Full)
        let model = FullResImageModel(
            thumbURL: DemoMedia.gif1, messageID: "m1", thumb: nil,
            cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in bytes })
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNotNil(model.image) // frame 0 still (paused/RM path)
        let clip = try XCTUnwrap(model.gif)
        XCTAssertEqual(clip.frames.count, 4)
        XCTAssertTrue(model.isAnimated)
    }

    func testFullResModelStillHasNoClip() async throws {
        let bytes = try DemoMedia.data(for: DemoMedia.photo1Full)
        let model = FullResImageModel(
            thumbURL: DemoMedia.photo1, messageID: "m1", thumb: nil,
            cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in bytes })
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNil(model.gif)
        XCTAssertFalse(model.isAnimated)
    }
}

/// Append-only URL log (Sendable for fetcher closures).
private actor URLLog {
    private var urls: [String] = []
    func append(_ url: String) { urls.append(url) }
    func all() -> [String] { urls }
}
