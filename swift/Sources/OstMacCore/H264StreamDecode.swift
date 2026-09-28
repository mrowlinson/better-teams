// H264StreamDecode.swift — om-liveav: persistent H.264 decode for live recv.
// One VTDecompressionSession across frames (the one-shot H264Decode rebuilds
// format + session per AU — too slow for 15fps display). The session is
// (re)created when an AU carries new SPS+PPS; param-only AUs arm the session
// and return nil.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class H264StreamDecoder {
    private var session: VTDecompressionSession?
    private var paramDesc: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?

    public init() {}

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decode one access unit (raw NALs, no start codes) to a CGImage.
    /// Nil when the AU holds no slice NALs (params cached for the next AU).
    /// Call from one serial queue (matches the video poll loop).
    public func decode(nals: [Data]) throws -> CGImage? {
        var slices: [Data] = []
        var newSps: Data?
        var newPps: Data?
        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: newSps = nal
            case 8: newPps = nal
            default: slices.append(nal)
            }
        }
        if let newSps, let newPps, (newSps != sps || newPps != pps) {
            try rebuildSession(sps: newSps, pps: newPps)
            sps = newSps
            pps = newPps
        }
        guard !slices.isEmpty else { return nil }
        guard session != nil else {
            throw H264DecodeError.badNALs("no SPS/PPS seen yet")
        }
        return try decodeSlices(slices)
    }

    private func rebuildSession(sps: Data, pps: Data) throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        self.session = nil
        var formatDesc: CMFormatDescription?
        let spsArr = sps.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        let ppsArr = pps.withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
        let status = spsArr.withUnsafeBufferPointer { spsPtr in
            ppsArr.withUnsafeBufferPointer { ppsPtr in
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
        paramDesc = formatDesc
        var newSession: VTDecompressionSession?
        let ds = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard ds == noErr, let newSession else {
            throw H264DecodeError.session(ds)
        }
        session = newSession
    }

    private func decodeSlices(_ slices: [Data]) throws -> CGImage {
        guard let session, paramDesc != nil else {
            throw H264DecodeError.session(-1)
        }
        var avcc = Data()
        for nal in slices {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw H264DecodeError.decode(status)
        }
        status = avcc.withUnsafeBytes { ptr in
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
                formatDescription: paramDesc!,
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

        let box = StreamDecodeBox()
        let sema = DispatchSemaphore(value: 0)
        var flagsOut = VTDecodeInfoFlags()
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
        guard status == noErr else { throw H264DecodeError.decode(status) }
        if sema.wait(timeout: .now() + 5) == .timedOut {
            throw H264DecodeError.timeout
        }
        if let image = box.image { return image }
        if let vtStatus = box.status, vtStatus != noErr {
            throw H264DecodeError.decode(vtStatus)
        }
        throw H264DecodeError.noImage
    }
}

private final class StreamDecodeBox {
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
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
