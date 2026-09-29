// ImageHeaderProbeTests.swift — FIXPACK F7: an uncached image with no tag
// size opens at its exact fitted size, read from its first bytes.
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class ImageHeaderProbeTests: XCTestCase {
    private let thumb = "https://amer.ng.msg.teams.microsoft.com/v1/objects/0-abc/views/imgt1"

    /// A real PNG of `w`×`h` (flat colour), plus a truncated copy that keeps
    /// only the first `prefix` bytes (what a range read returns).
    private func encoded(_ w: Int, _ h: Int, _ type: NSBitmapImageRep.FileType) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: type, properties: [:]))
    }
    private func png(_ w: Int, _ h: Int) throws -> Data { try encoded(w, h, .png) }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _log: [String] = []
        func add(_ s: String) { lock.withLock { _log.append(s) } }
        var log: [String] { lock.withLock { _log } }
    }

    private func model(_ head: @escaping FullResImageModel.HeadFetcher) -> FullResImageModel {
        FullResImageModel(thumbURL: thumb, messageID: "m1", headFetcher: head)
    }

    func testTruncatedHeaderBytesGiveTheExactPixelSize() async throws {
        let whole = try png(1234, 777)
        let prefix = whole.prefix(64)  // a range read: IHDR only, far short of the file
        XCTAssertLessThan(prefix.count, whole.count)
        let calls = Calls()
        let m = model { url, n, ms in
            calls.add("\(url)|\(n)|\(ms)")
            return Data(prefix)
        }
        let size = await m.headPixelSize()
        XCTAssertEqual(size, CGSize(width: 1234, height: 777))
        // Full view URL, header-sized budget, 300 ms deadline.
        XCTAssertEqual(calls.log, ["https://amer.ng.msg.teams.microsoft.com/v1/objects/0-abc/views/imgo|131072|300"])
    }

    func testTruncatedJpegAndGifHeadersAlsoGiveTheirSize() async throws {
        let jpeg = try encoded(900, 600, .jpeg)
        let jm = model { _, _, _ in Data(jpeg.prefix(4000)) }
        let js = await jm.headPixelSize()
        XCTAssertEqual(js, CGSize(width: 900, height: 600))
        let gif = try encoded(321, 123, .gif)
        let gm = model { _, _, _ in Data(gif.prefix(40)) }
        let gs = await gm.headPixelSize()
        XCTAssertEqual(gs, CGSize(width: 321, height: 123))
    }

    func testSlowSourceGivesUpAtTheDeadlineAndFallsBack() async {
        let m = model { _, _, _ in
            try await Task.sleep(for: .seconds(5))
            return Data()
        }
        let t0 = Date()
        let size = await m.headPixelSize(timeout: .milliseconds(100))
        XCTAssertNil(size)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "did not wait for the slow read")
    }

    func testFailureAndGarbageFallBackToNil() async {
        let failing = model { _, _, _ in throw CoreCallError.failed("HTTP 404") }
        let a = await failing.headPixelSize()
        XCTAssertNil(a)
        let garbage = model { _, _, _ in Data("not an image".utf8) }
        let b = await garbage.headPixelSize()
        XCTAssertNil(b)
    }

    func testDemoAndNonHTTPSNeverProbe() async {
        let calls = Calls()
        let m = FullResImageModel(thumbURL: DemoMedia.photo1, messageID: "m1", headFetcher: { u, _, _ in
            calls.add(u); return Data()
        })
        let size = await m.headPixelSize()
        XCTAssertNil(size)
        XCTAssertTrue(calls.log.isEmpty)
    }

    func testOnlyAnUncachedImageWithoutATagSizeNeedsTheHeader() {
        let big = CGSize(width: 2000, height: 1500)
        let display = CGSize(width: 400, height: 300)
        XCTAssertTrue(ImageViewerOpenSize.needsHeader(cached: nil, metadata: nil))
        XCTAssertTrue(ImageViewerOpenSize.needsHeader(cached: nil, metadata: display), "display size = aspect only")
        XCTAssertFalse(ImageViewerOpenSize.needsHeader(cached: nil, metadata: big), "a real tag size is trusted")
        XCTAssertFalse(ImageViewerOpenSize.needsHeader(cached: big, metadata: nil), "cached header wins")
    }

    /// The probed size feeds the window sizing exactly like a cached header.
    func testProbedSizeSizesTheWindowExactly() {
        let probed = CGSize(width: 1234, height: 777)
        let natural = ImageViewerOpenSize.natural(cached: probed, metadata: nil, thumb: CGSize(width: 320, height: 200))
        XCTAssertEqual(natural, probed)
    }
}
