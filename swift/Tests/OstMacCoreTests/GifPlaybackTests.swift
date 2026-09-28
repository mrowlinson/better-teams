// GifPlaybackTests.swift — om-gif-playback: inline GIFs animate w/ play-stop.
//
// Animated GIF bubbles play inline (Teams-style) with a native Play/Pause
// overlay; Reduce Motion opens paused on the still first frame. Static
// images (incl. single-frame GIFs) keep the plain path: no clip, no
// overlay, no timers.
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class GifPlaybackTests: XCTestCase {
    // MARK: - Probe (pure, no views)

    func testProbeDetectsAnimatedGIF() throws {
        let data = try DemoMedia.data(for: DemoMedia.gif1)
        XCTAssertEqual(GifProbe.frameCount(data), DemoMedia.gifFrameCount)
        XCTAssertTrue(GifProbe.isAnimated(data))
        let durations = try XCTUnwrap(GifProbe.durations(data))
        XCTAssertEqual(durations.count, DemoMedia.gifFrameCount)
        for d in durations {
            XCTAssertEqual(d, DemoMedia.gifFrameDelay, accuracy: 0.001)
        }
    }

    func testProbeRejectsStillsAndGarbage() throws {
        let png = try DemoMedia.data(for: DemoMedia.photo1)
        XCTAssertEqual(GifProbe.frameCount(png), 1)
        XCTAssertFalse(GifProbe.isAnimated(png))
        XCTAssertNil(GifProbe.frameCount(Data("not an image".utf8)))
        XCTAssertFalse(GifProbe.isAnimated(Data("not an image".utf8)))
        XCTAssertNil(GifProbe.durations(Data("not an image".utf8)))
        XCTAssertNil(GifProbe.frameCount(Data()))
        XCTAssertFalse(GifProbe.isAnimated(Data()))
    }

    func testProbeRejectsSingleFrameGIF() throws {
        // 1×1 static GIF: valid GIF bytes, no animation, no overlay.
        let still = try XCTUnwrap(Data(base64Encoded:
            "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        XCTAssertEqual(GifProbe.frameCount(still), 1)
        XCTAssertFalse(GifProbe.isAnimated(still))
    }

    // MARK: - Clip math (pure)

    func testSampledIndicesIdentityUnderCap() {
        XCTAssertEqual(GifClip.sampledIndices(count: 4), [0, 1, 2, 3])
        XCTAssertEqual(GifClip.sampledIndices(count: 0), [])
        XCTAssertEqual(GifClip.sampledIndices(count: 60).count, 60)
    }

    func testSampledIndicesStrideOverCap() {
        let idx = GifClip.sampledIndices(count: 200)
        XCTAssertEqual(idx.count, GifClip.maxFrames)
        XCTAssertEqual(idx.first, 0)
        XCTAssertTrue(idx.allSatisfy { $0 < 200 })
        XCTAssertEqual(idx, idx.sorted()) // strictly increasing
        XCTAssertEqual(Set(idx).count, idx.count)
    }

    func testFrameIndexBucketsAndWraps() {
        let d = [0.25, 0.25, 0.25, 0.25] // total 1.0
        XCTAssertEqual(GifClip.frameIndex(at: 0, durations: d), 0)
        XCTAssertEqual(GifClip.frameIndex(at: 0.1, durations: d), 0)
        XCTAssertEqual(GifClip.frameIndex(at: 0.25, durations: d), 1)
        XCTAssertEqual(GifClip.frameIndex(at: 0.6, durations: d), 2)
        XCTAssertEqual(GifClip.frameIndex(at: 0.99, durations: d), 3)
        XCTAssertEqual(GifClip.frameIndex(at: 1.0, durations: d), 0) // loop seam
        XCTAssertEqual(GifClip.frameIndex(at: 1.3, durations: d), 1)
        XCTAssertEqual(GifClip.frameIndex(at: -1, durations: d), 0)
        XCTAssertEqual(GifClip.frameIndex(at: 0.5, durations: []), 0)
        XCTAssertEqual(GifClip.frameIndex(at: 0.5, durations: [0, 0]), 0)
    }

    // MARK: - Clip decode

    func testDecodeAnimatedGIF() throws {
        let data = try DemoMedia.data(for: DemoMedia.gif1)
        let clip = try XCTUnwrap(GifClip.decode(
            data: data, maxPixels: ImageDecode.bubbleMaxPixels))
        XCTAssertEqual(clip.frames.count, DemoMedia.gifFrameCount)
        XCTAssertEqual(clip.durations.count, DemoMedia.gifFrameCount)
        XCTAssertEqual(
            clip.totalDuration,
            DemoMedia.gifFrameDelay * Double(DemoMedia.gifFrameCount),
            accuracy: 0.01)
        // 480-wide fixture fits the bubble slot: no downscale.
        XCTAssertEqual(clip.frames.first?.size, NSSize(width: 480, height: 320))
    }

    func testDecodeRejectsStills() throws {
        let png = try DemoMedia.data(for: DemoMedia.photo1)
        XCTAssertNil(GifClip.decode(data: png, maxPixels: 520))
        XCTAssertNil(GifClip.decode(data: Data("nope".utf8), maxPixels: 520))
    }

    // MARK: - Play gate (A1: Reduce Motion → still)

    func testInitiallyPlayingGate() {
        XCTAssertTrue(GifPlayback.initiallyPlaying(
            animated: true, reduceMotion: false))
        XCTAssertFalse(GifPlayback.initiallyPlaying(
            animated: true, reduceMotion: true))
        XCTAssertFalse(GifPlayback.initiallyPlaying(
            animated: false, reduceMotion: false))
        XCTAssertFalse(GifPlayback.initiallyPlaying(
            animated: false, reduceMotion: true))
    }

    // MARK: - Playhead state

    func testPlayerStateToggle() {
        let s = GifPlayerState(playing: true)
        XCTAssertTrue(s.playing)
        s.toggle()
        XCTAssertFalse(s.playing)
        s.toggle()
        XCTAssertTrue(s.playing)
    }

    func testPlayerStateTickAdvancesAndWraps() {
        let s = GifPlayerState(playing: true)
        let t0 = Date()
        s.tick(now: t0, totalDuration: 1.0) // first tick stamps, no jump
        XCTAssertEqual(s.playhead, 0, accuracy: 0.0001)
        s.tick(now: t0.addingTimeInterval(0.3), totalDuration: 1.0)
        XCTAssertEqual(s.playhead, 0.3, accuracy: 0.0001)
        s.tick(now: t0.addingTimeInterval(1.2), totalDuration: 1.0)
        XCTAssertEqual(s.playhead, 0.2, accuracy: 0.0001) // wrapped
    }

    func testPlayerStateTickFrozenWhilePaused() {
        let s = GifPlayerState(playing: true)
        s.toggle()
        let t0 = Date()
        s.tick(now: t0, totalDuration: 1.0)
        s.tick(now: t0.addingTimeInterval(5), totalDuration: 1.0)
        XCTAssertEqual(s.playhead, 0, accuracy: 0.0001)
    }

    func testPlayerStateReduceMotion() {
        let s = GifPlayerState(playing: true)
        s.applyReduceMotion(true)
        XCTAssertFalse(s.playing)
        s.applyReduceMotion(false)
        XCTAssertTrue(s.playing)
    }

    // MARK: - Bubble model

    func testRemoteImageModelLoadsGifClip() async throws {
        let bytes = try DemoMedia.data(for: DemoMedia.gif1)
        let model = RemoteImageModel(
            url: DemoMedia.gif1, messageID: "m1",
            cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in bytes })
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.isAnimated)
        XCTAssertNotNil(model.image) // frame 0 still (paused/RM path)
        let clip = try XCTUnwrap(model.gif)
        XCTAssertEqual(clip.frames.count, DemoMedia.gifFrameCount)
    }

    func testRemoteImageModelStillHasNoClip() async throws {
        let bytes = try DemoMedia.data(for: DemoMedia.photo1)
        let model = RemoteImageModel(
            url: DemoMedia.photo1, messageID: "m1",
            cache: RichMediaCache(diskDir: nil),
            fetcher: { _ in bytes })
        await model.reload()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.isAnimated)
        XCTAssertNil(model.gif)
    }

    // MARK: - Demo fixtures + thread

    func testDemoGifFixturesDecode() throws {
        for url in [DemoMedia.gif1, DemoMedia.gif1Full] {
            let data = try DemoMedia.data(for: url)
            XCTAssertTrue(GifProbe.isAnimated(data), url)
            XCTAssertEqual(GifProbe.frameCount(data), DemoMedia.gifFrameCount, url)
            XCTAssertNotNil(NSImage(data: data), url)
        }
        XCTAssertEqual(
            ImageFullRes.fullResURL(for: DemoMedia.gif1), DemoMedia.gif1Full)
    }

    func testMediaThreadCarriesGIFBubble() {
        let msgs = DemoData.mediaMessages()
        XCTAssertEqual(msgs.count, 7)
        let images = MessageRender.images(fromRaw: msgs.last?.raw)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.url, DemoMedia.gif1)
    }
}
