// H264StreamEncode.swift — om-liveav: persistent H.264 encode for live send.
// One VTCompressionSession across frames (the one-shot H264Encode rebuilds
// the session per frame — too slow for 15fps camera send). Keyframe every
// 30 frames; keyframes prepend [sps, pps] so the far end can join mid-call.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class H264StreamEncoder {
    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private var frameCount = 0
    private let fps: Int32
    private var keyPending = false
    /// Consecutive frames with no output (rate-control drops).
    private var emptyRun = 0
    private let path: String
    /// Pooled input buffers (was: one CVPixelBuffer alloc per frame).
    /// Touched only on the encode queue (see `encode`).
    private var pool: CVPixelBufferPool?

    /// VideoToolbox reports the hardware encoder is in use (HWACCEL).
    public let hardware: Bool
    /// The low-latency (real-time communication) rate controller is on.
    public let lowLatency: Bool

    /// Nil when the session cannot be created or prepared. `path` tags the
    /// HWACCEL log line (`camera`, `screen-share`, …). Live send always
    /// runs RealTime on the hardware encoder. `lowLatency` (the rtvc
    /// low-latency rate controller) is opt-in: measured at the shipped
    /// camera/share sizes it cost ~+0.5% of a core and ~+30% encode energy
    /// over the hardware encoder with RealTime alone, without a bit-rate
    /// gain there, and its wire shape is not yet proven against a Teams
    /// peer (tmp/HWACCEL.md R6).
    public init?(
        width: Int, height: Int, fps: Int32 = 15, bitrate: Int32 = 256_000,
        path: String = "live-send", lowLatency: Bool = false
    ) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        self.fps = max(fps, 1)
        self.path = path
        guard let made = HWVideo.makeCompressionSession(
            width: width, height: height, lowLatency: lowLatency, path: path)
        else { return nil }
        let session = made.session
        self.session = session
        hardware = made.hardware
        self.lowLatency = made.lowLatency
        var refused: [String] = []
        for (key, value) in [
            (kVTCompressionPropertyKey_RealTime, true as CFBoolean),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 30 as CFNumber),
            (kVTCompressionPropertyKey_AllowFrameReordering, false as CFBoolean),
        ] as [(CFString, CFTypeRef)] {
            let st = VTSessionSetProperty(session, key: key, value: value)
            if st != noErr { refused.append("\(key)=\(st)") }
        }
        if !refused.isEmpty {
            Log.media.warning("encoder path=\(path, privacy: .public) refused \(refused.joined(separator: ","), privacy: .public)")
        }
        // The low-latency controller takes constrained baseline (what
        // Apple's baseline output already is: no FMO/ASO); plain baseline
        // is the fallback when the profile is refused.
        if !made.lowLatency || VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel as CFString) != noErr
        {
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_Baseline_AutoLevel as CFString)
        }
        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            return nil
        }
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
            HWVideo.surfaceAttributes(width: width, height: height) as CFDictionary,
            &pool)
        if poolStatus == kCVReturnSuccess { self.pool = pool }
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// Encode one BGRA frame (`width*height*4` bytes) to raw NALs.
    /// Keyframes return [sps, pps, slices...]; inter frames return [slices...].
    /// Call from one serial queue (matches the camera delegate queue).
    /// Copies into a pooled IOSurface buffer; capture paths that already
    /// hold a pixel buffer use `encode(pixelBuffer:)` (no copy).
    public func encode(bgra: Data) throws -> [Data] {
        guard session != nil else { throw H264EncodeError.session(-1) }
        guard bgra.count >= width * height * 4 else { throw H264EncodeError.badDims }
        var pixels: CVPixelBuffer?
        if let pool {
            let cv = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixels)
            guard cv == kCVReturnSuccess, pixels != nil else {
                throw H264EncodeError.pixelBuffer(cv)
            }
        } else {
            let cv = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, HWVideo.surfaceAttributes() as CFDictionary, &pixels)
            guard cv == kCVReturnSuccess, pixels != nil else {
                throw H264EncodeError.pixelBuffer(cv)
            }
        }
        guard let pixels else { throw H264EncodeError.pixelBuffer(kCVReturnError) }
        CVPixelBufferLockBaseAddress(pixels, [])
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            CVPixelBufferUnlockBaseAddress(pixels, [])
            throw H264EncodeError.pixelBuffer(kCVReturnError)
        }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        bgra.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.baseAddress!
            for row in 0 ..< height {
                memcpy(base + row * stride, s + row * width * 4, width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return try encode(pixelBuffer: pixels)
    }

    /// Encode a capture frame as-is (zero copy: the IOSurface-backed
    /// buffer from AVCapture / ScreenCaptureKit goes straight to the
    /// hardware encoder). Must match the encoder's width x height.
    public func encode(pixelBuffer pixels: CVPixelBuffer) throws -> [Data] {
        guard let session else { throw H264EncodeError.session(-1) }
        guard CVPixelBufferGetWidth(pixels) == width,
              CVPixelBufferGetHeight(pixels) == height
        else { throw H264EncodeError.badDims }
        let forceKey = frameCount % 30 == 0 || keyPending
        keyPending = false
        frameCount += 1
        let box = StreamEncodeBox()
        let sema = DispatchSemaphore(value: 0)
        var flagsOut = VTEncodeInfoFlags()
        let props: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixels,
            presentationTimeStamp: CMTime(value: CMTimeValue(frameCount), timescale: fps),
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: &flagsOut,
            outputHandler: { encodeStatus, _, sampleBuffer in
                box.status = encodeStatus
                box.sample = sampleBuffer
                sema.signal()
            })
        guard status == noErr else { throw H264EncodeError.encode(status) }
        if sema.wait(timeout: .now() + 5) == .timedOut {
            throw H264EncodeError.timeout
        }
        guard box.status == noErr else {
            throw H264EncodeError.encode(box.status ?? -1)
        }
        guard let sample = box.sample else {
            // Rate controller dropped the frame (low-latency mode holds
            // the bit rate): nothing to send. A dropped keyframe is
            // re-forced on the next frame so joiners are not held back.
            if forceKey { keyPending = true }
            emptyRun += 1
            if emptyRun == 30 { // never silent: a stuck encoder shows up in the log
                Log.media.warning("encoder path=\(self.path, privacy: .public) 30 frames in a row produced no output")
            }
            return []
        }
        emptyRun = 0
        var nals: [Data] = []
        if forceKey, let (sps, pps) = parameterSets(from: sample) {
            nals.append(sps)
            nals.append(pps)
        }
        nals.append(contentsOf: try sliceNALs(from: sample))
        return nals
    }

    private func parameterSets(from sample: CMSampleBuffer) -> (Data, Data)? {
        guard let desc = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            let spsPtr, spsSize > 0,
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            let ppsPtr, ppsSize > 0
        else { return nil }
        return (Data(bytes: spsPtr, count: spsSize), Data(bytes: ppsPtr, count: ppsSize))
    }

    private func sliceNALs(from sample: CMSampleBuffer) throws -> [Data] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw H264EncodeError.noOutput
        }
        var total = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &total, dataPointerOut: &dataPtr)
        guard status == noErr, let dataPtr, total > 4 else {
            throw H264EncodeError.noOutput
        }
        var slices: [Data] = []
        var off = 0
        let raw = UnsafeRawPointer(dataPtr)
        while off + 4 <= total {
            var be: UInt32 = 0
            memcpy(&be, raw + off, 4)
            let len = Int(UInt32(bigEndian: be))
            off += 4
            guard len > 0, off + len <= total else { break }
            slices.append(Data(bytes: raw + off, count: len))
            off += len
        }
        guard !slices.isEmpty else { throw H264EncodeError.noOutput }
        return slices
    }
}

private final class StreamEncodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: OSStatus?
    private var _sample: CMSampleBuffer?
    var status: OSStatus? {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var sample: CMSampleBuffer? {
        get { lock.withLock { _sample } }
        set { lock.withLock { _sample = newValue } }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
