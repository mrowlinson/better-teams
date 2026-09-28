// MediaHotTests.swift — om-s3-mediahot: perf-guard tests (caps/counts only, no timings).
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class MediaHotTests: XCTestCase {
    func testLiveVideoPacingBacksOff() {
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 0), 250)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 1), 500)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 2), 1000)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 9), 1000)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: -1), 250)
    }

    func testCameraStatsGate() {
        XCTAssertTrue(CameraStatsGate.shouldPublish(nowMs: 10_000, lastMs: nil))
        XCTAssertFalse(CameraStatsGate.shouldPublish(nowMs: 10_500, lastMs: 10_000))
        XCTAssertFalse(CameraStatsGate.shouldPublish(nowMs: 10_999, lastMs: 10_000))
        XCTAssertTrue(CameraStatsGate.shouldPublish(nowMs: 11_000, lastMs: 10_000))
    }

    func testSharePreviewGate() {
        XCTAssertTrue(SharePreviewGate.shouldPublish(nowMs: 5_000, lastMs: nil))
        XCTAssertFalse(SharePreviewGate.shouldPublish(nowMs: 5_100, lastMs: 5_000))
        XCTAssertFalse(SharePreviewGate.shouldPublish(nowMs: 5_249, lastMs: 5_000))
        XCTAssertTrue(SharePreviewGate.shouldPublish(nowMs: 5_250, lastMs: 5_000))
    }

    func testImageDecodeDownsamplesToSlot() throws {
        let full = DemoMedia.render(seed: 1, width: 960, height: 640)
        let thumb = try XCTUnwrap(ImageDecode.thumbnail(
            data: full, maxPixels: ImageDecode.bubbleMaxPixels))
        XCTAssertLessThanOrEqual(Int(thumb.size.width), 520)
        XCTAssertLessThanOrEqual(Int(thumb.size.height), 520)
        XCTAssertEqual(thumb.size.width / thumb.size.height, 1.5, accuracy: 0.02)
        // Under-cap images pass through at native size.
        let small = DemoMedia.render(seed: 2, width: 480, height: 320)
        XCTAssertEqual(
            ImageDecode.thumbnail(data: small, maxPixels: 520)?.size,
            NSSize(width: 480, height: 320))
        // Empty/non-image still reject.
        XCTAssertNil(ImageDecode.thumbnail(data: Data(), maxPixels: 520))
        XCTAssertNil(ImageDecode.thumbnail(data: Data("not png".utf8), maxPixels: 520))
    }

    func testDecodeOffMainMatchesSync() async throws {
        let data = try DemoMedia.data(for: DemoMedia.photo1)
        let decoded = await ImageDecode.decodeOffMain(
            data: data, maxPixels: ImageDecode.bubbleMaxPixels)
        let img = try XCTUnwrap(decoded)
        XCTAssertEqual(img.size, NSSize(width: 480, height: 320))
    }
}
