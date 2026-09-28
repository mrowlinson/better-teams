// LiveAvTests.swift — om-liveav: live-media models, stream codec, FFI joins.
// No network/auth/hardware: VT encode/decode + core loopback are offline.
import CoreGraphics
import XCTest

@testable import OstMacCore

@MainActor
final class LiveAvTests: XCTestCase {
    // MARK: - Model decode (pure)

    func testLiveMediaStatsDecode() throws {
        let j = """
        {"ok":true,"media":{"running":true,"audio_sent":10,"audio_recv":9,
         "video_sent":150,"video_recv":148,"send_queued":1,"send_dropped":0,
         "recv_pending":0,"recv_dropped":2,"ice_audio":"1.2.3.4:5000",
         "ice_video":"","error":null,"started_at":99}}
        """
        let v = try JSONDecoder().decode(LiveMediaPoll.self, from: Data(j.utf8))
        XCTAssertTrue(v.media.running)
        XCTAssertEqual(v.media.audio_sent, 10)
        XCTAssertEqual(v.media.video_recv, 148)
        XCTAssertEqual(v.media.ice_audio, "1.2.3.4:5000")
        XCTAssertNil(v.media.error)
    }

    func testNalFramingWireFormat() throws {
        // Absent AU is nil with its dropped count (no JSON envelope).
        let n = IncomingPoll(ok: true, au: nil, dropped: 2)
        XCTAssertNil(n.au)
        XCTAssertEqual(n.dropped, 2)
        // Framing round-trips bit-identical with prefix-only overhead.
        let nals = [Data([0x67, 0x42]), Data([0x68]), Data([0x65, 0, 1, 2, 3])]
        let framed = try XCTUnwrap(NalFraming.encode(nals))
        XCTAssertEqual(framed.count, 4 + 4 * nals.count + nals.map(\.count).reduce(0, +))
        XCTAssertEqual(NalFraming.decode(framed), nals)
        // Malformed payloads reject.
        XCTAssertNil(NalFraming.encode([]))
        XCTAssertNil(NalFraming.decode(Data()))
        XCTAssertNil(NalFraming.decode(Data([1, 0, 0])))
        XCTAssertNil(NalFraming.decode(framed + Data([0])))
        XCTAssertNil(NalFraming.decode(framed.dropLast()))
    }

    func testLoopbackResultDecode() throws {
        let v = try JSONDecoder().decode(
            LoopbackResult.self,
            from: Data(#"{"ok":true,"units":1,"packets":7,"aus":1,"nals":3}"#.utf8))
        XCTAssertEqual(v.packets, 7)
        XCTAssertEqual(v.nals, 3)
    }

    func testCallInfoLiveMedia() throws {
        let live = try JSONDecoder().decode(
            CallInfo.self,
            from: Data(#"{"id":"c","dir":"out","peer":"p","peer_name":"n","thread":"t","state":"connected","started_at":1,"live_media":true}"#.utf8))
        XCTAssertEqual(live.liveMedia, true)
        // Old payloads omit the key: still decodes.
        let old = try JSONDecoder().decode(
            CallInfo.self,
            from: Data(#"{"id":"c","dir":"out","peer":"p","peer_name":"n","thread":"t","state":"connected","started_at":1}"#.utf8))
        XCTAssertNil(old.liveMedia)
    }

    func testCallResultLiveMedia() throws {
        let r = try JSONDecoder().decode(
            CallResult.self,
            from: Data(#"{"ok":true,"placed":true,"accepted":true,"live_media":true}"#.utf8))
        XCTAssertEqual(r.liveMedia, true)
    }

    // MARK: - FFI wiring (staticlib linked into the test bundle)

    func testCallMediaIdle() throws {
        let v = try RustCore.callMedia()
        XCTAssertTrue(v.ok)
        XCTAssertFalse(v.media.running)
    }

    func testSendPushEmptyThrows() {
        XCTAssertThrowsError(try RustCore.videoSendPush(nals: []))
    }

    func testIncomingPollDrains() throws {
        // Loopback may leave a unit behind; drain, then expect null.
        _ = try RustCore.videoPollIncoming()
        _ = try RustCore.videoPollIncoming()
        XCTAssertNil(try RustCore.videoPollIncoming().au)
    }

    // MARK: - Stream codec (VideoToolbox, offline)

    private func markerFrame(w: Int = 320, h: Int = 240) -> Data {
        var d = Data(repeating: 64, count: w * h * 4)
        d.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let p = dst.baseAddress!
            for row in 0 ..< h / 2 {
                for col in 0 ..< w / 2 {
                    let o = (row * w + col) * 4
                    p.storeBytes(of: UInt8(40), toByteOffset: o, as: UInt8.self)
                    p.storeBytes(of: UInt8(120), toByteOffset: o + 1, as: UInt8.self)
                    p.storeBytes(of: UInt8(220), toByteOffset: o + 2, as: UInt8.self)
                }
            }
        }
        return d
    }

    func testStreamEncodeKeyframeCarriesParams() throws {
        let enc = try XCTUnwrap(H264StreamEncoder(width: 320, height: 240))
        let nals = try enc.encode(bgra: markerFrame())
        XCTAssertGreaterThanOrEqual(nals.count, 3)
        XCTAssertEqual(nals[0][0] & 0x1F, 7) // SPS
        XCTAssertEqual(nals[1][0] & 0x1F, 8) // PPS
        // Second frame is inter: no params.
        let inter = try enc.encode(bgra: markerFrame())
        XCTAssertFalse(inter.isEmpty)
        XCTAssertNotEqual(inter[0][0] & 0x1F, 7)
    }

    func testStreamEncodeRejectsBadDims() {
        XCTAssertNil(H264StreamEncoder(width: 0, height: 240))
        XCTAssertThrowsError(
            try XCTUnwrap(H264StreamEncoder(width: 320, height: 240))
                .encode(bgra: Data([1, 2, 3])))
    }

    func testStreamDecodeNeedsParams() {
        let dec = H264StreamDecoder()
        // Slice without SPS/PPS: throws (nothing to build the session from).
        XCTAssertThrowsError(try dec.decode(nals: [Data([0x65, 0x00, 0x01])]))
    }

    /// Full join proof (offline): stream-encode -> send_push -> engine
    /// packetize/SRTP/depacketize -> poll incoming -> stream-decode -> image.
    func testLiveLoopbackEndToEnd() throws {
        _ = try RustCore.videoPollIncoming() // drain stale
        let w = 320, h = 240
        let enc = try XCTUnwrap(H264StreamEncoder(width: w, height: h))
        let nals = try enc.encode(bgra: markerFrame(w: w, h: h))
        let push = try RustCore.videoSendPush(nals: nals)
        XCTAssertGreaterThanOrEqual(push.queued, 1)
        let lb = try RustCore.liveLoopback()
        XCTAssertEqual(lb.units, 1)
        XCTAssertEqual(lb.aus, 1)
        XCTAssertEqual(lb.nals, nals.count)
        let poll = try RustCore.videoPollIncoming()
        let au = try XCTUnwrap(poll.au)
        XCTAssertEqual(au.nals.count, nals.count)
        // NALs survive the engine path bit-identical.
        XCTAssertEqual(au.nals, nals)
        let img = try XCTUnwrap(H264StreamDecoder().decode(nals: au.nals))
        XCTAssertEqual(img.width, w)
        XCTAssertEqual(img.height, h)
        XCTAssertNil(try RustCore.videoPollIncoming().au) // drained
    }
}
