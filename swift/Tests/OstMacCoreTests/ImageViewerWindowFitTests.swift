// ImageViewerWindowFitTests.swift — IMGWIN: viewer window fits the image,
// never more than 40% of the screen's visible area (chrome included).
import CoreGraphics
import XCTest

@testable import OstMacCore

final class ImageViewerWindowFitTests: XCTestCase {
    private let chrome = CGSize(width: 0, height: 28)
    private let minimum = CGSize(width: 480, height: 200)
    private let laptop = CGSize(width: 1512, height: 949)
    private let external = CGSize(width: 2560, height: 1415)
    private let small = CGSize(width: 1280, height: 775)

    private func size(_ w: CGFloat, _ h: CGFloat, on screen: CGSize) -> CGSize {
        ImageViewerWindowFit.windowSize(image: CGSize(width: w, height: h), chrome: chrome,
                                        minimum: minimum, screen: screen)
    }

    private func assertWithinBudget(_ s: CGSize, _ screen: CGSize, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(s.width * s.height, screen.width * screen.height * 0.4 + 2 * (s.width + s.height),
                                 "area over 40%", file: file, line: line)
        XCTAssertLessThanOrEqual(s.width, screen.width * 0.9, file: file, line: line)
        XCTAssertLessThanOrEqual(s.height, screen.height * 0.9, file: file, line: line)
    }

    private func aspect(_ s: CGSize) -> CGFloat { s.width / (s.height - chrome.height) }

    func testLandscapePhotoScalesDownKeepingAspect() {
        let s = size(4032, 3024, on: laptop)
        assertWithinBudget(s, laptop)
        XCTAssertEqual(aspect(s), 4032.0 / 3024.0, accuracy: 0.01)
        // Uses the budget, not a token size.
        XCTAssertGreaterThan(s.width * s.height, laptop.width * laptop.height * 0.38)
    }

    func testPortraitPhoneScreenshotHitsHeightOrAreaCap() {
        let s = size(1179, 2556, on: laptop)
        assertWithinBudget(s, laptop)
        // Height-capped; the image is narrower than the chrome minimum,
        // so the window holds the minimum width and letterboxes.
        XCTAssertEqual(s, CGSize(width: minimum.width, height: (laptop.height * 0.9).rounded(.down)))
        let scale = ImageViewerWindowFit.scale(image: CGSize(width: 1179, height: 2556), chrome: chrome, screen: laptop)
        XCTAssertEqual(2556 * scale + chrome.height, laptop.height * 0.9, accuracy: 1)
    }

    func testTinyImageIsNotUpscaledAndGetsMinimumWindow() {
        let scale = ImageViewerWindowFit.scale(image: CGSize(width: 64, height: 48), chrome: chrome, screen: laptop)
        XCTAssertEqual(scale, 1)
        XCTAssertEqual(size(64, 48, on: laptop), minimum)
    }

    func testMidSizeImageShowsAtNaturalSize() {
        XCTAssertEqual(size(600, 400, on: external), CGSize(width: 600, height: 428))
    }

    func testHugeImageStaysInsideBudget() {
        let s = size(20000, 15000, on: small)
        assertWithinBudget(s, small)
        XCTAssertEqual(aspect(s), 4.0 / 3.0, accuracy: 0.01)
    }

    func testVeryWidePanoramaIsWidthCapped() {
        let s = size(12000, 1000, on: laptop)
        XCTAssertEqual(s.width, (laptop.width * 0.9).rounded(.down))
        assertWithinBudget(s, laptop)
    }

    func testSquareImage() {
        let s = size(3000, 3000, on: laptop)
        assertWithinBudget(s, laptop)
        XCTAssertEqual(aspect(s), 1, accuracy: 0.01)
    }

    func testBiggerScreenGivesBiggerWindow() {
        let a = size(4032, 3024, on: laptop)
        let b = size(4032, 3024, on: external)
        XCTAssertGreaterThan(b.width, a.width)
        assertWithinBudget(b, external)
    }

    func testCenteredInVisibleFrame() {
        let f = ImageViewerWindowFit.centered(CGSize(width: 600, height: 400),
                                              in: CGRect(x: 1512, y: 25, width: 2560, height: 1415))
        XCTAssertEqual(f, CGRect(x: 2492, y: 533, width: 600, height: 400))
    }
}

// MARK: - IMGWIN2: open size (resolved before the window is ordered in)

final class ImageViewerOpenSizeTests: XCTestCase {
    func testOpenSizePrefersCachedHeaderThenMetadataThenThumbAspect() {
        let cached = CGSize(width: 1200, height: 900)
        let meta = CGSize(width: 1600, height: 900)
        let thumb = CGSize(width: 520, height: 260)
        XCTAssertEqual(ImageViewerOpenSize.natural(cached: cached, metadata: meta, thumb: thumb), cached)
        XCTAssertEqual(ImageViewerOpenSize.natural(cached: nil, metadata: meta, thumb: thumb), meta)
        // Display-size tag (≤ 520): aspect only, budget-capped "large".
        let small = ImageViewerOpenSize.natural(cached: nil, metadata: CGSize(width: 444, height: 250), thumb: thumb)
        XCTAssertEqual(small.width, ImageViewerOpenSize.aspectOnlyLongSide)
        XCTAssertEqual(small.width / small.height, 444.0 / 250.0, accuracy: 0.001)
        let byThumb = ImageViewerOpenSize.natural(cached: nil, metadata: nil, thumb: thumb)
        XCTAssertEqual(byThumb.width / byThumb.height, 2, accuracy: 0.001)
        let none = ImageViewerOpenSize.natural(cached: nil, metadata: nil, thumb: nil)
        XCTAssertEqual(none.width / none.height, 4.0 / 3.0, accuracy: 0.001)
        // Degenerate inputs fall through.
        XCTAssertEqual(ImageViewerOpenSize.natural(cached: .zero, metadata: meta, thumb: nil), meta)
    }

    func testNavItemsCarryTagSizeAndMatchCurrentWithoutIt() {
        let raw = #"<img src="https://x/views/imgpsh" width="1920" height="1080" alt="a"><img src="demo://b">"#
        let items = ImageViewerNav.items(from: [ChatMessage(id: "1", sender: "A", timestamp: "", content: "", raw: raw)])
        XCTAssertEqual(items.first?.pixelSize, CGSize(width: 1920, height: 1080))
        XCTAssertNil(items.last?.pixelSize)
        // The timeline click builds the item without the size; nav still finds it.
        let nav = ImageViewerNav(items: items, current: ImageViewerItem(url: "https://x/views/imgpsh", messageID: "1"))
        XCTAssertEqual(nav.position, "1 of 2")
        XCTAssertEqual(nav.current.pixelSize, CGSize(width: 1920, height: 1080))
    }
}
