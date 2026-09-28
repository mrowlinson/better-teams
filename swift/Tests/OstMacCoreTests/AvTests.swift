// AvTests.swift — om-av: A/V models, YUV convert, VideoToolbox decode, FFI wiring.
// No hardware touched (mic/camera devices excluded); FFI tests use synthetic frames.
import CoreGraphics
import XCTest

@testable import OstMacCore

@MainActor
final class AvTests: XCTestCase {
    // MARK: - Model decode (pure)

    func testAvInfoDecode() throws {
        let j = """
        {"ok":true,"mic":"cpal","speaker":"cpal","camera":"avfoundation",
         "display":"swiftui","tone":true,"packetizer":"rust-h264",
         "srtp":"rust-aes-128-cm","dry_run":true}
        """
        let v = try JSONDecoder().decode(AvInfo.self, from: Data(j.utf8))
        XCTAssertEqual(v.camera, "avfoundation")
        XCTAssertTrue(v.tone && v.dry_run)
    }

    func testCameraStatsDecode() throws {
        let j = """
        {"ok":true,"running":true,"width":320,"height":240,"fps_want":15,
         "frames":7,"dropped":1,"fps_actual":14.5,"last_bytes":115200}
        """
        let v = try JSONDecoder().decode(CameraStats.self, from: Data(j.utf8))
        XCTAssertTrue(v.running)
        XCTAssertEqual(v.frames, 7)
        XCTAssertEqual(v.fps_actual, 14.5)
    }

    func testRemotePollNullAndFrame() {
        let n = RemotePoll(ok: true, frame: nil)
        XCTAssertNil(n.frame)
        let f = RemotePoll(
            ok: true,
            frame: RemoteFrame(width: 2, height: 2, data: Data([0x41, 0x42, 0x43])))
        XCTAssertEqual(f.frame?.width, 2)
        XCTAssertEqual(f.frame?.data, Data([0x41, 0x42, 0x43]))
    }

    func testDryRunDecode() throws {
        let j = """
        {"ok":true,"audio_sent":25,"audio_received":25,"echo_detected":true,
         "echo_delay_ms":50.0,"echo_correlation":0.99,
         "video_packets":5,"video_nals":5}
        """
        let v = try JSONDecoder().decode(DryRunResult.self, from: Data(j.utf8))
        XCTAssertEqual(v.audio_received, 25)
        XCTAssertTrue(v.echo_detected)
        XCTAssertEqual(v.video_packets, 5)
    }

    // MARK: - FFI wiring (staticlib linked into the test bundle)

    func testAvInfoCaps() throws {
        let v = try RustCore.avInfo()
        XCTAssertEqual(v.mic, "cpal")
        XCTAssertEqual(v.camera, "avfoundation")
        XCTAssertEqual(v.display, "swiftui")
        XCTAssertTrue(v.tone)
    }

    func testToneCheckDetects() throws {
        let v = try RustCore.toneCheck()
        XCTAssertTrue(v.detected, "corr=\(v.correlation_peak)")
        XCTAssertGreaterThan(abs(v.correlation_peak), 0.3)
    }

    func testCameraPushStatsRoundtrip() throws {
        let b = try RustCore.cameraBegin(width: 320, height: 240, fps: 15)
        XCTAssertEqual(b.width, 320)
        let bgra = Data(repeating: 0x80, count: 320 * 240 * 4)
        let s = try RustCore.cameraPush(pixels: bgra, width: 320, height: 240, fmt: "bgra")
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.frames, 1)
        XCTAssertEqual(s.last_bytes, 320 * 240 * 3 / 2)
        try RustCore.cameraEnd()
        XCTAssertFalse(try RustCore.cameraStats().running)
    }

    func testVideoPushPollRoundtrip() throws {
        _ = try RustCore.videoPollRemote() // drain
        XCTAssertNil(try RustCore.videoPollRemote().frame)
        let i420 = Data(repeating: 0x10, count: 64 * 64 * 3 / 2)
        try RustCore.videoPushRemote(i420: i420, width: 64, height: 64)
        let p = try RustCore.videoPollRemote()
        XCTAssertEqual(p.frame?.width, 64)
        XCTAssertEqual(p.frame?.height, 64)
        XCTAssertEqual(p.frame?.data, i420)
        XCTAssertNil(try RustCore.videoPollRemote().frame) // drains
    }

    func testBlackIframeThreeNALs() throws {
        let v = try RustCore.avBlackIframe()
        XCTAssertEqual(v.width, 176)
        XCTAssertEqual(v.height, 144)
        XCTAssertEqual(v.nals.count, 3)
        let types = try v.nals.map { s -> UInt8 in
            guard let d = Data(base64Encoded: s), !d.isEmpty else {
                throw CoreCallError.failed("bad NAL base64")
            }
            return d[0] & 0x1F
        }
        XCTAssertEqual(types, [7, 8, 5]) // SPS, PPS, IDR
    }

    func testDryRunLoops() throws {
        let v = try RustCore.callDryRun()
        XCTAssertEqual(v.audio_sent, 25)
        XCTAssertEqual(v.audio_received, 25)
        XCTAssertTrue(v.echo_detected)
        XCTAssertEqual(v.video_packets, 5)
        XCTAssertEqual(v.video_nals, 5)
    }

    // MARK: - YUV convert (pure)

    private func pixels(of img: CGImage) -> [UInt8] {
        let data = img.dataProvider!.data! as Data
        return Array(data)
    }

    func testGrayStaysGray() throws {
        // 2x2: Y=128 neutral chroma -> ~128 gray, opaque
        let i420 = Data([128, 128, 128, 128, 128, 128])
        let img = try XCTUnwrap(YUVConvert.cgImage(i420: i420, width: 2, height: 2))
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual(img.height, 2)
        let px = pixels(of: img)
        XCTAssertEqual(px.count, 16)
        for i in stride(from: 0, to: 16, by: 4) {
            XCTAssertEqual(px[i], 128, "B at \(i)")
            XCTAssertEqual(px[i + 1], 128, "G at \(i)")
            XCTAssertEqual(px[i + 2], 128, "R at \(i)")
            XCTAssertEqual(px[i + 3], 255, "A at \(i)")
        }
    }

    func testBlackMapsToZero() {
        let i420 = Data([0, 0, 0, 0, 128, 128])
        let img = YUVConvert.cgImage(i420: i420, width: 2, height: 2)!
        let px = pixels(of: img)
        XCTAssertEqual(px[0], 0)
        XCTAssertEqual(px[1], 0)
        XCTAssertEqual(px[2], 0)
    }

    func testRejectsBadSizes() {
        XCTAssertNil(YUVConvert.cgImage(i420: Data([0, 0, 0]), width: 2, height: 2))
        XCTAssertNil(YUVConvert.cgImage(i420: Data(repeating: 0, count: 6), width: 3, height: 2))
        XCTAssertNil(YUVConvert.cgImage(i420: Data(repeating: 0, count: 6), width: 0, height: 2))
    }

    // MARK: - VideoToolbox round-trip (native encode -> decode)

    /// Bright-quadrant BGRA marker frame.
    private func markerFrame(w: Int = 320, h: Int = 240) -> Data {
        var d = Data(repeating: 64, count: w * h * 4)
        d.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let p = dst.baseAddress!
            for row in 0 ..< h {
                for col in 0 ..< w {
                    let bright = row < h / 2 && col < w / 2
                    let v: UInt8 = bright ? 220 : 64
                    let o = (row * w + col) * 4
                    p.storeBytes(of: v, toByteOffset: o, as: UInt8.self)
                    p.storeBytes(of: v, toByteOffset: o + 1, as: UInt8.self)
                    p.storeBytes(of: v, toByteOffset: o + 2, as: UInt8.self)
                    p.storeBytes(of: UInt8(255), toByteOffset: o + 3, as: UInt8.self)
                }
            }
        }
        return d
    }

    func testEncodeDecodeRoundTrip() throws {
        let w = 320, h = 240
        let (sps, pps, slices) = try H264Encode.encode(
            bgra: markerFrame(w: w, h: h), width: w, height: h)
        XCTAssertFalse(sps.isEmpty)
        XCTAssertFalse(pps.isEmpty)
        XCTAssertFalse(slices.isEmpty)
        XCTAssertEqual(sps[0] & 0x1F, 7) // SPS
        XCTAssertEqual(pps[0] & 0x1F, 8) // PPS

        var nals = [sps, pps]
        nals.append(contentsOf: slices)
        let img = try H264Decode.decode(nals: nals)
        XCTAssertEqual(img.width, w)
        XCTAssertEqual(img.height, h)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try H264Decode.decode(nals: [Data([0x67]), Data([0x68])]))
        XCTAssertThrowsError(try H264Decode.decode(nals: []))
    }
}
