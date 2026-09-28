// H264Encode.swift — om-av: native H.264 encode via VideoToolbox (no openh264).
// Encodes one BGRA frame to raw NALs ([SPS, PPS, IDR]) — the round-trip
// partner of H264Decode and the future camera send-side encoder.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum H264EncodeError: Error, Sendable {
    case session(OSStatus)
    case pixelBuffer(CVReturn)
    case encode(OSStatus)
    case timeout
    case noOutput
    case badDims
}

public enum H264Encode {
    /// Encode one BGRA frame (`w*h*4` bytes) to raw NALs (no start codes).
    /// First frame of the session is forced to a keyframe. Blocks ~1-2s.
    public static func encode(
        bgra: Data, width: Int, height: Int, timeoutSecs: Double = 10
    ) throws -> (sps: Data, pps: Data, slices: [Data]) {
        guard width > 0, height > 0, bgra.count >= width * height * 4 else {
            throw H264EncodeError.badDims
        }

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
        guard status == noErr, let session else {
            throw H264EncodeError.session(status)
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: true as CFBoolean)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 15 as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate, value: 256_000 as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 15 as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false as CFBoolean)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel as CFString)
        status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else { throw H264EncodeError.session(status) }

        var pixels: CVPixelBuffer?
        let cv = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, nil, &pixels)
        guard cv == kCVReturnSuccess, let pixels else {
            throw H264EncodeError.pixelBuffer(cv)
        }
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

        let box = EncodeBox()
        let sema = DispatchSemaphore(value: 0)
        var flagsOut = VTEncodeInfoFlags()
        status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixels,
            presentationTimeStamp: CMTime(value: 0, timescale: 15),
            duration: .invalid,
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary,
            infoFlagsOut: &flagsOut,
            outputHandler: { encodeStatus, _, sampleBuffer in
                box.status = encodeStatus
                box.sample = sampleBuffer
                sema.signal()
            })
        guard status == noErr else { throw H264EncodeError.encode(status) }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if sema.wait(timeout: .now() + timeoutSecs) == .timedOut {
            throw H264EncodeError.timeout
        }
        guard box.status == noErr, let sample = box.sample else {
            throw H264EncodeError.encode(box.status ?? -1)
        }

        // Parameter sets from the format description.
        guard let desc = CMSampleBufferGetFormatDescription(sample) else {
            throw H264EncodeError.noOutput
        }
        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        var paramCount = 0
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil)
        guard status == noErr, let spsPtr, spsSize > 0 else {
            throw H264EncodeError.noOutput
        }
        status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            desc, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard status == noErr, let ppsPtr, ppsSize > 0 else {
            throw H264EncodeError.noOutput
        }
        let sps = Data(bytes: spsPtr, count: spsSize)
        let pps = Data(bytes: ppsPtr, count: ppsSize)

        // Slice NALs: AVCC block is [u32be len + NAL]*.
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw H264EncodeError.noOutput
        }
        var total = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        status = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &total, dataPointerOut: &dataPtr)
        guard status == noErr, let dataPtr, total > 4 else {
            throw H264EncodeError.noOutput
        }
        var slices: [Data] = []
        var off = 0
        let raw = UnsafeRawPointer(dataPtr)
        while off + 4 <= total {
            var be: UInt32 = 0 // memcpy: off is not 4-aligned after NALs
            memcpy(&be, raw + off, 4)
            let len = Int(UInt32(bigEndian: be))
            off += 4
            guard len > 0, off + len <= total else { break }
            slices.append(Data(bytes: raw + off, count: len))
            off += len
        }
        guard !slices.isEmpty else { throw H264EncodeError.noOutput }
        return (sps, pps, slices)
    }
}

private final class EncodeBox: @unchecked Sendable {
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
