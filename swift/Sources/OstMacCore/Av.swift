// Av.swift — om-av: A/V models + RustCore wrappers (mic/tone/camera/display/dry-run).
// Blocking calls (micTest, tonePlay) must run off the main thread; the panel
// ViewModel dispatches them with Task.detached.
import COstMac
import Foundation

// MARK: - Models

public struct AvInfo: Decodable, Sendable {
    public let ok: Bool
    public let mic: String
    public let speaker: String
    public let camera: String
    public let display: String
    public let tone: Bool
    public let packetizer: String
    public let srtp: String
    public let dry_run: Bool
}

public struct MicProbe: Decodable, Sendable {
    public let ok: Bool
    public let input: Bool
    public let output: Bool
}

public struct MicTestResult: Decodable, Sendable {
    public let ok: Bool
    public let frames: Int
    public let seconds: Double
    public let peak_db: Double
    public let played_back: Bool
}

public struct TonePlayResult: Decodable, Sendable {
    public let ok: Bool
    public let frames: Int
}

public struct ToneCheckResult: Decodable, Sendable {
    public let ok: Bool
    public let detected: Bool
    public let delay_ms: Double
    public let correlation_peak: Double
}

public struct CameraBegin: Decodable, Sendable {
    public let ok: Bool
    public let width: Int
    public let height: Int
    public let fps: Int
}

public struct CameraStats: Decodable, Sendable {
    public let ok: Bool
    public let running: Bool
    public let width: Int
    public let height: Int
    public let fps_want: Int
    public let frames: Int
    public let dropped: Int
    public let fps_actual: Double
    public let last_bytes: Int
}

public struct RemoteFrame: Sendable {
    public let width: Int
    public let height: Int
    /// Planar I420 bytes (zero-copy view of the core payload).
    public let data: Data

    public init(width: Int, height: Int, data: Data) {
        self.width = width
        self.height = height
        self.data = data
    }
}

public struct RemotePoll: Sendable {
    public let ok: Bool
    public let frame: RemoteFrame?

    public init(ok: Bool, frame: RemoteFrame?) {
        self.ok = ok
        self.frame = frame
    }
}

public struct BlackIframe: Decodable, Sendable {
    public let ok: Bool
    public let width: Int
    public let height: Int
    /// Raw H.264 NALs (no start codes), base64: [SPS, PPS, IDR].
    public let nals: [String]
}

public struct DryRunResult: Decodable, Sendable {
    public let ok: Bool
    public let audio_sent: Int
    public let audio_received: Int
    public let echo_detected: Bool
    public let echo_delay_ms: Double
    public let echo_correlation: Double
    public let video_packets: Int
    public let video_nals: Int
}

public struct LiveMediaStats: Decodable, Sendable {
    public let running: Bool
    public let audio_sent: Int
    public let audio_recv: Int
    public let video_sent: Int
    public let video_recv: Int
    public let send_queued: Int
    public let send_dropped: Int
    public let recv_pending: Int
    public let recv_dropped: Int
    public let ice_audio: String
    public let ice_video: String
    public let error: String?
    public let started_at: UInt64
    /// Mic mute flag (om-call-ux). Nil on old core builds — treat as unmuted.
    public let muted: Bool?
    /// Effective speaker route, nil = system default (nil on old builds too).
    public let speaker: String?
    /// Last speaker-reroute failure (nil when the route is healthy).
    public let speakerError: String?

    enum CodingKeys: String, CodingKey {
        case running, audio_sent, audio_recv, video_sent, video_recv
        case send_queued, send_dropped, recv_pending, recv_dropped
        case ice_audio, ice_video, error, started_at, muted, speaker
        case speakerError = "speaker_error"
    }
}

public struct LiveMediaPoll: Decodable, Sendable {
    public let ok: Bool
    public let media: LiveMediaStats
}

public struct IncomingAu: Sendable {
    /// Raw H.264 NALs (no start codes). First AU carries SPS+PPS.
    /// Zero-copy slices of the polled core payload.
    public let nals: [Data]

    public init(nals: [Data]) {
        self.nals = nals
    }
}

public struct IncomingPoll: Sendable {
    public let ok: Bool
    public let au: IncomingAu?
    public let dropped: Int

    public init(ok: Bool, au: IncomingAu?, dropped: Int) {
        self.ok = ok
        self.au = au
        self.dropped = dropped
    }
}

/// Length-prefixed NAL framing for the byte+len FFI ABI (om-s3-mediahot):
/// `u32LE nal_count (1..=32)`, then per NAL `u32LE len + raw bytes`.
/// Mirrors `frame_nals`/`unframe_nals` in core. Decode slices the payload
/// without copying (Data slicing shares storage).
public enum NalFraming {
    public static let maxNALs = 32
    public static let maxBytes = 4 * 1024 * 1024

    /// Frame NALs for `videoSendPush`. Nil when the unit is out of limits.
    public static func encode(_ nals: [Data]) -> Data? {
        guard !nals.isEmpty, nals.count <= maxNALs else { return nil }
        var total = 0
        for n in nals {
            guard !n.isEmpty, n.count <= maxBytes else { return nil }
            total += n.count
            guard total <= maxBytes else { return nil }
        }
        var out = Data()
        out.reserveCapacity(4 + 4 * nals.count + total)
        var count = UInt32(nals.count).littleEndian
        out.append(Data(bytes: &count, count: 4))
        for n in nals {
            var len = UInt32(n.count).littleEndian
            out.append(Data(bytes: &len, count: 4))
            out.append(n)
        }
        return out
    }

    /// Parse a polled payload into NAL slices. Nil when malformed.
    public static func decode(_ data: Data) -> [Data]? {
        guard data.count >= 4 else { return nil }
        let n = Int(data.u32LE(at: 0))
        guard n >= 1, n <= maxNALs else { return nil }
        var nals: [Data] = []
        nals.reserveCapacity(n)
        var off = 4
        var total = 0
        for _ in 0 ..< n {
            guard off + 4 <= data.count else { return nil }
            let len = Int(data.u32LE(at: off))
            off += 4
            guard len >= 1, len <= maxBytes, off + len <= data.count else { return nil }
            total += len
            guard total <= maxBytes else { return nil }
            nals.append(data[off ..< off + len])
            off += len
        }
        guard off == data.count else { return nil }
        return nals
    }
}

private extension Data {
    /// Little-endian u32 at a byte offset (caller bounds-checks).
    func u32LE(at off: Int) -> UInt32 {
        UInt32(self[off]) | (UInt32(self[off + 1]) << 8)
            | (UInt32(self[off + 2]) << 16) | (UInt32(self[off + 3]) << 24)
    }
}

public struct SendPushResult: Decodable, Sendable {
    public let ok: Bool
    public let queued: Int
}

public struct LoopbackResult: Decodable, Sendable {
    public let ok: Bool
    public let units: Int
    public let packets: Int
    public let aus: Int
    public let nals: Int
}

public struct AudioDevices: Decodable, Sendable {
    public let ok: Bool
    public let inputs: [String]
    public let outputs: [String]
    public let default_input: String?
    public let default_output: String?
}

public struct MicLevel: Decodable, Sendable {
    public let ok: Bool
    public let peak_db: Double
    public let has_input: Bool
}

/// `{ok, muted}` from `ostmac_call_mute` (om-call-ux in-call window).
public struct MuteResult: Decodable, Sendable {
    public let ok: Bool
    public let muted: Bool
}

/// `{ok, speaker?}` from `ostmac_call_speaker` (nil = system default).
public struct SpeakerResult: Decodable, Sendable {
    public let ok: Bool
    public let speaker: String?
}

// MARK: - RustCore wrappers

/// Optional C string arg: nil/empty Swift string passes NULL (= default device).
func withOptCString<T>(_ s: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    guard let s, !s.isEmpty else { return try body(nil) }
    return try s.withCString { try body($0) }
}

public extension RustCore {
    /// Swift-native (R12 ffi-move-now B1; was `ostmac_av_info`).
    static func avInfo() throws -> AvInfo {
        try CoreLocal.avInfo()
    }

    static func micProbe() throws -> MicProbe {
        try call(ostmac_mic_probe(), as: MicProbe.self)
    }

    /// Blocks ~`seconds` + playback. Call off-main.
    static func micTest(seconds: Int32 = 3) throws -> MicTestResult {
        try call(ostmac_mic_test(seconds), as: MicTestResult.self)
    }

    /// Blocks ~`msecs` while the tone plays. Call off-main.
    static func tonePlay(msecs: Int32 = 1000) throws -> TonePlayResult {
        try call(ostmac_tone_play(msecs), as: TonePlayResult.self)
    }

    /// Swift-native (R12 ffi-move-now B2; was `ostmac_tone_check`).
    static func toneCheck() throws -> ToneCheckResult {
        try CoreLocal.toneCheck()
    }

    static func audioDevices() throws -> AudioDevices {
        try call(ostmac_audio_devices(), as: AudioDevices.self)
    }

    /// Named-device mic test (nil/"" = default). Blocks ~`seconds` + playback. Call off-main.
    static func micTestOn(seconds: Int32 = 3, input: String?, output: String?) throws -> MicTestResult {
        try withOptCString(input) { inPtr in
            try withOptCString(output) { outPtr in
                try call(ostmac_mic_test_on(seconds, inPtr, outPtr), as: MicTestResult.self)
            }
        }
    }

    /// Named-device tone play (nil/"" = default). Blocks ~`msecs`. Call off-main.
    static func tonePlayOn(msecs: Int32 = 1000, output: String?) throws -> TonePlayResult {
        try withOptCString(output) { outPtr in
            try call(ostmac_tone_play_on(msecs, outPtr), as: TonePlayResult.self)
        }
    }

    /// Short mic level sample for a live meter (nil/"" = default).
    /// Never throws for missing hardware (`has_input` tells). Call off-main.
    static func micLevel(msecs: Int32 = 150, input: String?) throws -> MicLevel {
        try withOptCString(input) { inPtr in
            try call(ostmac_mic_level(msecs, inPtr), as: MicLevel.self)
        }
    }

    static func cameraBegin(width: Int32, height: Int32, fps: Int32) throws -> CameraBegin {
        try call(ostmac_camera_begin(width, height, fps), as: CameraBegin.self)
    }

    /// Push one camera frame by pointer+len (no encode; core borrows).
    static func cameraPush(pixels: Data, width: Int, height: Int, fmt: String) throws -> CameraStats {
        try fmt.withCString { fmtPtr in
            try pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                // Empty Data has no base address; core treats len 0 as empty.
                let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return try call(
                    ostmac_camera_push_bytes(
                        ptr, pixels.count, Int32(width), Int32(height), fmtPtr),
                    as: CameraStats.self)
            }
        }
    }

    static func cameraStats() throws -> CameraStats {
        try call(ostmac_camera_stats(), as: CameraStats.self)
    }

    static func cameraEnd() throws {
        struct OkOnly: Decodable { let ok: Bool }
        let _: OkOnly = try call(ostmac_camera_end(), as: OkOnly.self)
    }

    static func videoPushRemote(i420: Data, width: Int, height: Int) throws {
        struct OkBytes: Decodable { let ok: Bool; let bytes: Int }
        let _: OkBytes = try i420.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            try call(
                ostmac_video_push_remote_bytes(
                    buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    i420.count, Int32(width), Int32(height)),
                as: OkBytes.self)
        }
    }

    /// Drain the latest remote frame. The payload is adopted without
    /// copying (freed back to core when the Data dies).
    static func videoPollRemote() throws -> RemotePoll {
        var w: Int32 = 0
        var h: Int32 = 0
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let rc = ostmac_video_poll_remote_bytes(&w, &h, &out, &outLen)
        guard rc >= 0 else { throw CoreCallError.failed("remote poll failed") }
        guard rc == 1, let ptr = out, outLen > 0 else {
            return RemotePoll(ok: true, frame: nil)
        }
        let data = Data(
            bytesNoCopy: ptr, count: outLen,
            deallocator: .custom({ _, _ in ostmac_bytes_free(ptr, outLen) }))
        return RemotePoll(
            ok: true,
            frame: RemoteFrame(width: Int(w), height: Int(h), data: data))
    }

    static func avBlackIframe() throws -> BlackIframe {
        try call(ostmac_av_black_iframe(), as: BlackIframe.self)
    }

    static func callDryRun() throws -> DryRunResult {
        try call(ostmac_call_dry_run(), as: DryRunResult.self)
    }

    static func callMedia() throws -> LiveMediaPoll {
        try call(ostmac_call_media(), as: LiveMediaPoll.self)
    }

    static func callMediaStop() throws -> LiveMediaPoll {
        try call(ostmac_call_media_stop(), as: LiveMediaPoll.self)
    }

    /// Set live-call mic mute (sticky; stored when idle). Fast, but call
    /// off-main with the other core calls.
    static func callMute(muted: Bool) throws -> MuteResult {
        try call(ostmac_call_mute(muted ? 1 : 0), as: MuteResult.self)
    }

    /// Select the call speaker route (nil/"" = system default). Stored
    /// always; reroutes a live call without dropping audio on failure.
    static func callSpeaker(name: String?) throws -> SpeakerResult {
        try withOptCString(name) { ptr in
            try call(ostmac_call_speaker(ptr), as: SpeakerResult.self)
        }
    }

    /// Push one send-side access unit (raw NALs, no start codes),
    /// framed once; core borrows the bytes.
    static func videoSendPush(nals: [Data]) throws -> SendPushResult {
        guard let framed = NalFraming.encode(nals) else {
            throw CoreCallError.failed("send unit out of limits")
        }
        return try framed.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            try call(
                ostmac_video_send_push_bytes(
                    buf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    framed.count),
                as: SendPushResult.self)
        }
    }

    /// Drain the newest incoming access unit. NALs slice the adopted
    /// core payload without copying.
    static func videoPollIncoming() throws -> IncomingPoll {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        var dropped: Int32 = 0
        let rc = ostmac_video_poll_incoming_bytes(&out, &outLen, &dropped)
        guard rc >= 0 else { throw CoreCallError.failed("incoming poll failed") }
        guard rc == 1, let ptr = out, outLen > 0 else {
            return IncomingPoll(ok: true, au: nil, dropped: Int(dropped))
        }
        let payload = Data(
            bytesNoCopy: ptr, count: outLen,
            deallocator: .custom({ _, _ in ostmac_bytes_free(ptr, outLen) }))
        guard let nals = NalFraming.decode(payload) else {
            throw CoreCallError.failed("incoming framing corrupt")
        }
        return IncomingPoll(ok: true, au: IncomingAu(nals: nals), dropped: Int(dropped))
    }

    /// Offline join check: queued send units through packetize -> SRTP ->
    /// depacketize -> incoming queue. No network/auth/hardware.
    static func liveLoopback() throws -> LoopbackResult {
        try call(ostmac_live_loopback(), as: LoopbackResult.self)
    }
}
