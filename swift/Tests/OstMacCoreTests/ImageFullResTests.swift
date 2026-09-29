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

    // MARK: - IMGVIEW: every source kind maps thumb → original

    func testFullResURLPerSourceKind() {
        // AMS thumbnail views → imgo (original).
        for view in ["imgt1_anim", "imgpsh_mobile_save_anim", "imgt2"] {
            XCTAssertEqual(
                ImageFullRes.fullResURL(for: "https://us-api.asm.skype.com/v1/objects/0-eus-d1-abc/views/\(view)"),
                "https://us-api.asm.skype.com/v1/objects/0-eus-d1-abc/views/imgo", view)
        }
        // Already full (animated full size keeps its animation view).
        let anim = "https://us-api.asm.skype.com/v1/objects/0-abc/views/imgpsh_fullsize_anim"
        XCTAssertEqual(ImageFullRes.fullResURL(for: anim), anim)
        // Graph inline hosted content: `$value` is the original.
        let hosted = "https://graph.microsoft.com/v1.0/chats/19:a@thread.v2/messages/1/hostedContents/aWQ9/$value"
        XCTAssertEqual(ImageFullRes.fullResURL(for: hosted), hosted)
        // Graph / SharePoint drive-item thumbnails → the item download.
        XCTAssertEqual(
            ImageFullRes.fullResURL(for: "https://graph.microsoft.com/v1.0/drives/b!x/items/01AB/thumbnails/0/large/content"),
            "https://graph.microsoft.com/v1.0/drives/b!x/items/01AB/content")
        XCTAssertEqual(
            ImageFullRes.fullResURL(
                for: "https://contoso.sharepoint.com/_api/v2.1/drives/b!x/items/01AB/thumbnails/0/c400x400/content?prefer=noredirect"),
            "https://contoso.sharepoint.com/_api/v2.1/drives/b!x/items/01AB/content")
        // Drive item content already: untouched.
        let content = "https://graph.microsoft.com/v1.0/drives/b!x/items/01AB/content"
        XCTAssertEqual(ImageFullRes.fullResURL(for: content), content)
    }

    // MARK: - IMGVIEW: viewer state machine (placeholder → full)

    func testViewerPlaceholderThenFullKeepsOriginalBytes() async throws {
        let thumb = try XCTUnwrap(NSImage(data: DemoMedia.data(for: DemoMedia.photo1)))
        let fullData = DemoMedia.render(seed: 1, width: 960, height: 640)
        let model = FullResImageModel(
            thumbURL: "https://h/v1/objects/0/views/imgt1", messageID: "m1", thumb: thumb,
            cache: RichMediaCache(diskDir: nil, memory: .pinned), fetcher: { _ in fullData }, maxPixels: 480)
        // Before the fetch lands: thumbnail placeholder, loading, nothing to save.
        XCTAssertTrue(model.isLoadingFull)
        XCTAssertTrue(model.displayImage === thumb)
        XCTAssertNil(model.originalData)
        await model.reload()
        XCTAssertFalse(model.isLoadingFull)
        XCTAssertFalse(model.displayImage === thumb)
        // Display decode capped (memory-safe) …
        XCTAssertEqual(model.image?.size, NSSize(width: 480, height: 320))
        // … while the original bytes + pixel size survive for Save/Copy.
        XCTAssertEqual(model.originalData, fullData)
        XCTAssertEqual(model.pixelSize, CGSize(width: 960, height: 640))
        XCTAssertNotNil(model.originalType)
    }

    func testViewerFailureShowsThumbAsDisplay() async throws {
        let thumb = try XCTUnwrap(NSImage(data: DemoMedia.data(for: DemoMedia.photo1)))
        let model = FullResImageModel(
            thumbURL: "https://h/v1/objects/0/views/imgt1", messageID: "m1", thumb: thumb,
            cache: RichMediaCache(diskDir: nil, memory: .pinned),
            fetcher: { _ in throw MediaFetchError.failed("nope") })
        await model.reload()
        guard case .failed = model.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(model.displayImage === thumb) // never blanks
        XCTAssertNil(model.originalData)            // nothing to save
    }

    // MARK: - IMGVIEW: navigation + zoom math

    func testViewerNavStepsThroughChatImagesInOrder() {
        func msg(_ id: String, _ raw: String, deleted: Bool = false) -> ChatMessage {
            ChatMessage(id: id, sender: "A", timestamp: "", content: "", raw: raw, deleted: deleted)
        }
        let msgs = [
            msg("1", #"<img src="demo://photo-1" alt="one"><img src="demo://e" width="20" height="20" alt="(smile)">"#),
            msg("2", "<p>text</p>"),
            msg("3", #"<img src="demo://photo-2"><img src="demo://gif-1">"#),
            msg("4", #"<img src="demo://photo-3">"#, deleted: true),
        ]
        let items = ImageViewerNav.items(from: msgs)
        XCTAssertEqual(items.map(\.url), ["demo://photo-1", "demo://photo-2", "demo://gif-1"])
        XCTAssertEqual(items.first?.alt, "one")
        var nav = ImageViewerNav(items: items, current: items[1])
        XCTAssertEqual(nav.position, "2 of 3")
        XCTAssertTrue(nav.move(by: 1))
        XCTAssertEqual(nav.current.url, "demo://gif-1")
        XCTAssertFalse(nav.move(by: 1)) // no wrap
        XCTAssertFalse(nav.canNext)
        // An image outside the list (card) opens alone.
        let solo = ImageViewerNav(items: items, current: ImageViewerItem(url: "demo://x", messageID: "9"))
        XCTAssertEqual(solo.items.count, 1)
        XCTAssertNil(solo.position)
    }

    func testViewerZoomMath() {
        let img = CGSize(width: 2048, height: 1536)
        // Original 4096 wide decoded at 2048: Actual Size = 2 (1 px per pt).
        let actual = ImageViewerZoom.actual(imageSize: img, pixelSize: CGSize(width: 4096, height: 3072))
        XCTAssertEqual(actual, 2)
        let fit = ImageViewerZoom.fit(imageSize: img, viewport: CGSize(width: 1024, height: 1024), pixelSize: CGSize(width: 4096, height: 3072))
        XCTAssertEqual(fit, 0.5)
        // Small images never upscale past natural size.
        XCTAssertEqual(ImageViewerZoom.fit(imageSize: CGSize(width: 200, height: 100),
                                           viewport: CGSize(width: 1000, height: 1000), pixelSize: nil), 1)
        // Double-click: fit ↔ actual.
        XCTAssertEqual(ImageViewerZoom.toggle(fit, fit: fit, actual: actual), actual)
        XCTAssertEqual(ImageViewerZoom.toggle(actual, fit: fit, actual: actual), fit)
        // Clamped steps.
        XCTAssertEqual(ImageViewerZoom.zoomIn(15.9, fit: fit, actual: actual), 16)
        XCTAssertEqual(ImageViewerZoom.zoomOut(0.1, fit: fit, actual: actual), 0.1)
    }

    // MARK: - Viewer loads full-res bytes

    func testViewerLoadsFullResNotThumb() async throws {
        let thumbData = try DemoMedia.data(for: DemoMedia.photo1) // 480x320
        let fullData = DemoMedia.render(seed: 1, width: 960, height: 640)
        let thumb = try XCTUnwrap(NSImage(data: thumbData))
        let cache = RichMediaCache(diskDir: nil, memory: .pinned)
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
            thumb: thumb, cache: RichMediaCache(diskDir: nil, memory: .pinned),
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
        let cache = RichMediaCache(diskDir: nil, memory: .pinned)
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
            cache: RichMediaCache(diskDir: nil, memory: .pinned),
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
            cache: RichMediaCache(diskDir: nil, memory: .pinned),
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
