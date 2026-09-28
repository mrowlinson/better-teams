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
    /// Pooled input buffers (was: one CVPixelBuffer alloc per frame).
    /// Touched only on the encode queue (see `encode`).
    private var pool: CVPixelBufferPool?

    /// Nil when the session cannot be created or prepared.
    public init?(width: Int, height: Int, fps: Int32 = 15, bitrate: Int32 = 256_000) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: true as CFBoolean)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false as CFBoolean)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel as CFString)
        status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            return nil
        }
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
            [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ] as CFDictionary,
            &pool)
        if poolStatus == kCVReturnSuccess { self.pool = pool }
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// Encode one BGRA frame (`width*height*4` bytes) to raw NALs.
    /// Keyframes return [sps, pps, slices...]; inter frames return [slices...].
    /// Call from one serial queue (matches the camera delegate queue).
    public func encode(bgra: Data) throws -> [Data] {
        guard let session else { throw H264EncodeError.session(-1) }
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
                kCVPixelFormatType_32BGRA, nil, &pixels)
            guard cv == kCVReturnSuccess, pixels != nil else {
                throw H264EncodeError.pixelBuffer(cv)
            }
        }
        guard let pixels else { throw H264EncodeError.pixelBuffer(kCVReturnError) }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else {
            throw H264EncodeError.pixelBuffer(kCVReturnError)
        }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        bgra.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let s = src.baseAddress!
            for row in 0 ..< height {
                memcpy(base + row * stride, s + row * width * 4, width * 4)
            }
        }

        let forceKey = frameCount % 30 == 0
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
            presentationTimeStamp: CMTime(value: CMTimeValue(frameCount), timescale: 15),
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
        guard box.status == noErr, let sample = box.sample else {
            throw H264EncodeError.encode(box.status ?? -1)
        }
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
