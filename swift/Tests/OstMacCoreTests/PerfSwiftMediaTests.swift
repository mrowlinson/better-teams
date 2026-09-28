// PerfSwiftMediaTests.swift — om-perf-swift-media: pins the media-path
// perf contracts (one-source decode, decoded memo, amortized trim,
// key stability). Timing-free: benches live in throwaway scratch.
import AppKit
import XCTest

@testable import OstMacCore

final class PerfSwiftMediaTests: XCTestCase {
    // MARK: - One-source decode

    func testDecodedStill() throws {
        let data = try DemoMedia.data(for: DemoMedia.photo1)
        let result = ImageDecode.decoded(data: data, maxPixels: 520)
        guard case let .still(img) = result else {
            return XCTFail("expected .still, got \(String(describing: result))")
        }
        // photo1 is 480×320: under the 520 cap, no upscale.
        XCTAssertEqual(img.size.width, 480, accuracy: 1)
    }

    func testDecodedAnimated() throws {
        let data = try DemoMedia.data(for: DemoMedia.gif1)
        let result = ImageDecode.decoded(data: data, maxPixels: 520)
        guard case let .animated(clip) = result else {
            return XCTFail("expected .animated, got \(String(describing: result))")
        }
        XCTAssertEqual(clip.frames.count, DemoMedia.gifFrameCount)
    }

    func testDecodedRejectsGarbageAndEmpty() {
        XCTAssertNil(ImageDecode.decoded(
            data: Data("not an image".utf8), maxPixels: 520))
        XCTAssertNil(ImageDecode.decoded(data: Data(), maxPixels: 520))
    }

    func testFirstFrameMatchesStillPath() throws {
        let still = try DemoMedia.data(for: DemoMedia.photo1)
        let gif = try DemoMedia.data(for: DemoMedia.gif1)
        let s = ImageDecode.decoded(data: still, maxPixels: 520)?.firstFrame
        XCTAssertNotNil(s)
        let g = ImageDecode.decoded(data: gif, maxPixels: 520)?.firstFrame
        XCTAssertNotNil(g)
        XCTAssertGreaterThan(
            DecodedImage.animated(GifClip(frames: [g!], durations: [0.25])).pixelBytes, 0)
    }

    // MARK: - Decoded memo

    func testMemoSharesIdenticalBytes() async throws {
        let memo = DecodedImageCache()
        let bytes = try DemoMedia.data(for: DemoMedia.gif1)
        let first = await memo.decoded(data: bytes, maxPixels: 520)
        let second = await memo.decoded(data: bytes, maxPixels: 520)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let stats = await memo.stats()
        XCTAssertEqual(stats, DecodedImageCache.Stats(hits: 1, misses: 1))
    }

    func testMemoKeysOnSize() async throws {
        let memo = DecodedImageCache()
        let bytes = try DemoMedia.data(for: DemoMedia.photo1)
        _ = await memo.decoded(data: bytes, maxPixels: 520)
        _ = await memo.decoded(data: bytes, maxPixels: 2048)
        let stats = await memo.stats()
        XCTAssertEqual(stats.misses, 2)
        XCTAssertEqual(stats.hits, 0)
    }

    func testMemoSkipsFailures() async {
        let memo = DecodedImageCache()
        let junk = Data("not an image".utf8)
        let first = await memo.decoded(data: junk, maxPixels: 520)
        let second = await memo.decoded(data: junk, maxPixels: 520)
        XCTAssertNil(first)
        XCTAssertNil(second)
        let stats = await memo.stats()
        XCTAssertEqual(stats, DecodedImageCache.Stats(hits: 0, misses: 2))
    }

    @MainActor
    func testModelsShareDecodedImage() async throws {
        let memo = DecodedImageCache()
        let bytes = try DemoMedia.data(for: DemoMedia.photo1)
        let makeModel = { (i: Int) in
            RemoteImageModel(
                url: "demo://shared-\(i)", messageID: "m\(i)",
                cache: RichMediaCache(diskDir: nil),
                fetcher: { _ in bytes }, decodedCache: memo)
        }
        let a = makeModel(1)
        let b = makeModel(2)
        await a.reload()
        await b.reload()
        XCTAssertEqual(a.phase, .loaded)
        XCTAssertEqual(b.phase, .loaded)
        // Same bytes, different messages: one decode, shared instance.
        XCTAssertTrue(a.image === b.image)
        let stats = await memo.stats()
        XCTAssertEqual(stats.misses, 1)
    }

    // MARK: - Key stability (nibble-table hex)

    func testKeyVector() {
        XCTAssertEqual(
            RichMediaCache.key(url: "https://h/a.png", messageID: "m"),
            "dc507106bf45731fcfed0e3a8828b32ba5d203f78847a33db57009c832db530a")
    }

    func testBytesHexVector() {
        XCTAssertEqual(
            ImageDecode.bytesHex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Amortized trim (estimates stay exact under cap)

    func testUnderCapWritesSkipEviction() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perfmedia-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RichMediaCache(diskDir: dir, diskCapFiles: 100)
        for i in 0 ..< 10 {
            _ = try await cache.data(
                url: "https://h/\(i).png", messageID: "m",
                fetcher: { _ in Data(repeating: 7, count: 100) })
        }
        let usage = await cache.diskUsage()
        XCTAssertEqual(usage.files, 10)
        XCTAssertEqual(usage.bytes, 1000)
    }

    func testEstimateRecoversAfterCap() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perfmedia-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RichMediaCache(diskDir: dir, diskCapFiles: 3)
        for i in 0 ..< 6 {
            _ = try await cache.data(
                url: "https://h/\(i).png", messageID: "m",
                fetcher: { _ in Data(repeating: 7, count: 10) })
        }
        // Cap enforced across estimate-driven trims, usage exact.
        let usage = await cache.diskUsage()
        XCTAssertEqual(usage.files, 3)
        // Under-cap writes after a trim keep working (estimates reseeded).
        _ = try await cache.data(
            url: "https://h/6.png", messageID: "m",
            fetcher: { _ in Data(repeating: 7, count: 10) })
        let usage2 = await cache.diskUsage()
        XCTAssertEqual(usage2.files, 3)
    }
}
