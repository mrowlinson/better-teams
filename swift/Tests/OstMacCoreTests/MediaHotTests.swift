// MediaHotTests.swift — om-s3-mediahot: perf-guard tests (caps/counts only, no timings).
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class MediaHotTests: XCTestCase {
    func testLiveVideoPacingBacksOff() {
        // One 30 fps frame while video flows; misses double to the ceiling.
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 0), 33)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 1), 66)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 3), 264)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 4), 500)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: 9), 500)
        XCTAssertEqual(LiveVideoPacing.delayMs(nilStreak: -1), 33)
    }

    /// CALLFIX: a tick decodes every queued unit in order (no reference
    /// frame skipped) and shows the newest; after a decode failure units
    /// are skipped until a keyframe.
    func testLiveVideoDrainDecodesEveryUnitInOrder() throws {
        enum Bad: Error { case frame }
        let key = { (n: UInt8) in [Data([0x67, 0x42]), Data([0x65, n])] }
        let p = { (n: UInt8) in [Data([0x41, n])] }
        var queue: [[Data]] = [key(1), p(2), p(3), p(4), p(5), key(6), p(7)]
        var decoded: [UInt8] = []
        var needKey = false
        let tick = try LiveVideoDrain.run(needKey: &needKey, poll: {
            queue.isEmpty ? nil : queue.removeFirst()
        }, decode: { (nals: [Data]) throws -> UInt8? in
            let tag = nals.last!.last!
            if tag == 3 { throw Bad.frame }
            decoded.append(tag)
            return tag
        })
        XCTAssertEqual(decoded, [1, 2, 6, 7], "4 and 5 wait for the keyframe after 3 failed")
        XCTAssertEqual(tick.latest, 7)
        XCTAssertEqual(tick.units, 7)
        XCTAssertEqual(tick.decoded, 4)
        XCTAssertFalse(needKey)
        let idle = try LiveVideoDrain.run(needKey: &needKey, poll: { nil as [Data]? },
                                          decode: { (_: [Data]) throws -> UInt8? in nil })
        XCTAssertEqual(idle.units, 0)
        XCTAssertNil(idle.latest)
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
