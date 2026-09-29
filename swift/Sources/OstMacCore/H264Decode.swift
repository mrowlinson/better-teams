// H264Decode.swift — om-av: native H.264 decode via VideoToolbox (no openh264).
// Decodes one access unit ([SPS, PPS, IDR]…) into a CGImage. Proven by the
// H264Encode round-trip test (real VT NALs, offline, no network).
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum H264DecodeError: Error, Sendable {
    case badNALs(String)
    case format(OSStatus)
    case session(OSStatus)
    case decode(OSStatus)
    case timeout
    case noImage
}

public enum H264Decode {
    /// Decode raw NALs (no start codes; first two must be SPS+PPS) to CGImage.
    /// Blocks up to ~5s for the async VT callback. Thread-safe.
    public static func decode(nals: [Data], timeoutSecs: Double = 5) throws -> CGImage {
        guard nals.count >= 3 else {
            throw H264DecodeError.badNALs("need SPS+PPS+IDR, got \(nals.count) NALs")
        }
        let sps = nals[0].withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        let pps = nals[1].withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        guard !sps.isEmpty, !pps.isEmpty else {
            throw H264DecodeError.badNALs("empty SPS/PPS")
        }

        var formatDesc: CMFormatDescription?
        var status = sps.withUnsafeBufferPointer { spsPtr in
            pps.withUnsafeBufferPointer { ppsPtr in
                guard let spsBase = spsPtr.baseAddress,
                      let ppsBase = ppsPtr.baseAddress
                else { return OSStatus(paramErr) }
                let params: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [spsPtr.count, ppsPtr.count]
                return params.withUnsafeBufferPointer { pBuf in
                    sizes.withUnsafeBufferPointer { sBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pBuf.baseAddress!,
                            parameterSetSizes: sBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDesc)
                    }
                }
            }
        }
        guard status == noErr, let formatDesc else {
            throw H264DecodeError.format(status)
        }

        // Length-prefixed (AVCC) block: one slice NAL (IDR) is enough.
        var avcc = Data()
        for nal in nals.dropFirst(2) {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        var blockBuffer: CMBlockBuffer?
        status = avcc.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &blockBuffer)
        }
        guard status == noErr, let blockBuffer else {
            throw H264DecodeError.decode(status)
        }
        status = avcc.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { throw H264DecodeError.decode(status) }

        var sampleBuffer: CMSampleBuffer?
        status = [avcc.count].withUnsafeBufferPointer { sizeBuf in
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDesc,
                sampleCount: 1,
                sampleTimingEntryCount: 0,
                sampleTimingArray: nil,
                sampleSizeEntryCount: 1,
                sampleSizeArray: sizeBuf.baseAddress!,
                sampleBufferOut: &sampleBuffer)
        }
        guard status == noErr, let sampleBuffer else {
            throw H264DecodeError.decode(status)
        }

        let box = ResultBox()
        // HWACCEL: hardware decoder required (logged software fallback);
        // IOSurface BGRA out, wrapped into a CGImage without a copy.
        guard let made = HWVideo.makeDecompressionSession(
            format: formatDesc, path: "oneshot-decode")
        else { throw H264DecodeError.session(-1) }
        let session = made.session

        var flagsOut = VTDecodeInfoFlags()
        let sema = DispatchSemaphore(value: 0)
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut,
            completionHandler: { decodeStatus, _, imageBuffer, _, _, _ in
                box.status = decodeStatus
                if decodeStatus == noErr, let imageBuffer,
                   let image = VideoPixel.cgImage(from: imageBuffer)
                {
                    box.image = image
                }
                sema.signal()
            })
        guard status == noErr else {
            VTDecompressionSessionInvalidate(session)
            throw H264DecodeError.decode(status)
        }
        if sema.wait(timeout: .now() + timeoutSecs) == .timedOut {
            VTDecompressionSessionInvalidate(session)
            throw H264DecodeError.timeout
        }
        VTDecompressionSessionInvalidate(session)

        if let image = box.take() {
            return image
        }
        if let vtStatus = box.status, vtStatus != noErr {
            throw H264DecodeError.decode(vtStatus)
        }
        throw H264DecodeError.noImage
    }
}

// MARK: - Callback plumbing

private final class ResultBox {
    private let lock = NSLock()
    private var _image: CGImage?
    private var _status: OSStatus?
    var image: CGImage? {
        get { lock.withLock { _image } }
        set { lock.withLock { _image = newValue } }
    }
    var status: OSStatus? {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    func take() -> CGImage? { image }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
