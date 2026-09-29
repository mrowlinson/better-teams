// HWVideo.swift — HWACCEL: the one place VideoToolbox sessions are made.
//
// Every video decode and encode in the app goes through here so hardware
// acceleration is asked for (required for H.264/HEVC, which every
// supported Mac decodes and encodes in hardware), checked after creation,
// and logged once per session:
//
//   hw=true codec=h264 path=call-recv kind=decode 1280x720
//
// Software is a fallback only: when the hardware session cannot be made
// (unsupported codec, size or profile) the helper logs a warning and
// retries without the requirement, so playback and calls keep working.
// AVPlayer playback cannot take a decoder specification; `makePlayer`
// probes the asset's own format through a hardware-required session
// instead and logs the same line. `HWAccelGuardTests` fails if any
// source file creates a VT session, an AVPlayer or an AVAssetWriter
// video input outside this helper.
//
// Read the lines: /usr/bin/log show --last 30m --predicate
//   'subsystem == "dev.ostmac.OstMac" AND category == "media"'
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

public enum HWVideo {
    // MARK: - Codecs

    /// Formats every supported Mac decodes and encodes in hardware; the
    /// hardware is required for these (software only as a logged fallback).
    public static func alwaysHardware(_ codec: CMVideoCodecType) -> Bool {
        codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC
    }

    /// Short codec name for the log line (`h264`, `hevc`, else the FourCC).
    public static func codecName(_ codec: CMVideoCodecType) -> String {
        switch codec {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "hevc"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((codec >> UInt32($0)) & 0xFF) }
            let s = String(bytes: bytes, encoding: .ascii) ?? "\(codec)"
            return s.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Specifications

    public static func decoderSpecification(requireHardware: Bool) -> [String: Any] {
        var spec: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
        ]
        if requireHardware {
            spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String] = true
        }
        return spec
    }

    /// `lowLatency` turns on the real-time-communication rate controller
    /// (H.264 only; calls): each frame goes out without waiting for the
    /// next, and the bit rate follows the target frame by frame.
    public static func encoderSpecification(
        requireHardware: Bool, lowLatency: Bool = false
    ) -> [String: Any] {
        var spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ]
        if requireHardware {
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        }
        if lowLatency {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
        }
        return spec
    }

    /// IOSurface-backed, Metal-compatible pixel buffer attributes: decoder
    /// output and encoder input stay in GPU-shareable memory (no copy on
    /// the way to the display layer or from capture to the encoder).
    public static func surfaceAttributes(
        format: OSType = kCVPixelFormatType_32BGRA, width: Int? = nil, height: Int? = nil
    ) -> [String: Any] {
        var a: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        if let width { a[kCVPixelBufferWidthKey as String] = width }
        if let height { a[kCVPixelBufferHeightKey as String] = height }
        return a
    }

    /// AVAssetWriter video settings with the hardware encoder required
    /// (`requireHardware: false` is the logged fallback retry).
    public static func writerVideoSettings(
        codec: AVVideoCodecType, width: Int, height: Int, requireHardware: Bool = true
    ) -> [String: Any] {
        [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: encoderSpecification(requireHardware: requireHardware),
        ]
    }

    // MARK: - Sessions

    /// One session attempt: the spec used and whether it is a fallback.
    struct Attempt: Equatable {
        let requireHardware: Bool
        let lowLatency: Bool
    }

    /// Hardware-required first (H.264/HEVC), then without low latency,
    /// then software allowed. Other codecs start at "hardware preferred".
    static func attempts(codec: CMVideoCodecType, lowLatency: Bool) -> [Attempt] {
        var out: [Attempt] = []
        let lowLat = lowLatency && codec == kCMVideoCodecType_H264
        if alwaysHardware(codec) {
            if lowLat { out.append(Attempt(requireHardware: true, lowLatency: true)) }
            out.append(Attempt(requireHardware: true, lowLatency: false))
        }
        out.append(Attempt(requireHardware: false, lowLatency: false))
        return out
    }

    public struct Session<S> {
        public let session: S
        /// VideoToolbox reports the hardware codec is in use.
        public let hardware: Bool
        public let lowLatency: Bool
    }

    /// Create a compression session through the attempt ladder. Nil only
    /// when even the software encoder refuses (logged as an error).
    public static func makeCompressionSession(
        width: Int, height: Int, codec: CMVideoCodecType = kCMVideoCodecType_H264,
        lowLatency: Bool = false,
        sourceAttributes: [String: Any]? = nil,
        path: String
    ) -> Session<VTCompressionSession>? {
        let name = codecName(codec)
        var failures: [String] = []
        for (i, a) in attempts(codec: codec, lowLatency: lowLatency).enumerated() {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width), height: Int32(height),
                codecType: codec,
                encoderSpecification: encoderSpecification(
                    requireHardware: a.requireHardware, lowLatency: a.lowLatency) as CFDictionary,
                imageBufferAttributes: (sourceAttributes ?? surfaceAttributes()) as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session)
            guard status == noErr, let session else {
                failures.append("attempt\(i) status=\(status)")
                continue
            }
            // The low-latency (rtvc) encoder does not answer the
            // "using hardware" query (kVTPropertyNotSupportedErr); a
            // session made under RequireHardware is hardware by contract.
            let reported = copyBool(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
            let hw = reported ?? a.requireHardware
            let via = reported != nil ? "reported" : (a.requireHardware ? "required" : "unknown")
            let encoder = copyString(session, kVTCompressionPropertyKey_EncoderID) ?? "?"
            report(kind: "encode", hw: hw, codec: name, path: path,
                   detail: "\(width)x\(height)\(a.lowLatency ? " lowlatency" : "") via=\(via) encoder=\(encoder)",
                   fallback: failures)
            return Session(session: session, hardware: hw, lowLatency: a.lowLatency)
        }
        report(kind: "encode", hw: false, codec: name, path: path,
               detail: "\(width)x\(height) no encoder", fallback: failures, failed: true)
        return nil
    }

    /// Create a decompression session through the attempt ladder.
    public static func makeDecompressionSession(
        format: CMVideoFormatDescription,
        outputAttributes: [String: Any]? = nil,
        path: String
    ) -> Session<VTDecompressionSession>? {
        makeDecompressionSession(format: format, outputAttributes: outputAttributes, path: path, ladder: nil)
    }

    /// `ladder` overrides the attempt list (tests: exercise a real
    /// Require-hardware refusal and the logged software rung).
    static func makeDecompressionSession(
        format: CMVideoFormatDescription,
        outputAttributes: [String: Any]?,
        path: String,
        ladder: [Attempt]?
    ) -> Session<VTDecompressionSession>? {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let name = codecName(codec)
        var failures: [String] = []
        for (i, a) in (ladder ?? attempts(codec: codec, lowLatency: false)).enumerated() {
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: decoderSpecification(
                    requireHardware: a.requireHardware) as CFDictionary,
                imageBufferAttributes: (outputAttributes ?? surfaceAttributes()) as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session)
            guard status == noErr, let session else {
                failures.append("attempt\(i) status=\(status)")
                continue
            }
            let reported = copyBool(session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)
            let hw = reported ?? a.requireHardware
            let via = reported != nil ? "reported" : (a.requireHardware ? "required" : "unknown")
            report(kind: "decode", hw: hw, codec: name, path: path,
                   detail: "\(dims.width)x\(dims.height) via=\(via)", fallback: failures)
            return Session(session: session, hardware: hw, lowLatency: false)
        }
        report(kind: "decode", hw: false, codec: name, path: path,
               detail: "\(dims.width)x\(dims.height) no decoder", fallback: failures, failed: true)
        return nil
    }

    /// Nil when the codec does not answer the query.
    private static func copyBool(_ session: VTSession, _ key: CFString) -> Bool? {
        copy(session, key) as? Bool
    }

    private static func copyString(_ session: VTSession, _ key: CFString) -> String? {
        copy(session, key) as? String
    }

    private static func copy(_ session: VTSession, _ key: CFString) -> Any? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: $0)
        }
        return status == noErr ? value : nil
    }

    // MARK: - Playback (AVPlayer / AVAsset)

    /// The app's AVPlayer factory: the player plus a one-off probe of the
    /// asset's video format through a hardware-required decode session
    /// (AVPlayer itself decodes through VideoToolbox, hardware first, and
    /// takes no decoder specification).
    public static func makePlayer(url: URL, path: String) -> AVPlayer {
        let asset = AVURLAsset(url: url)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        Task.blocking(priority: .utility) {
            _ = await probePlayback(asset: asset, path: path)
        }
        return player
    }

    /// Probe what AVPlayer will decode: codec + size from the first video
    /// track, then a hardware-required VT session for that exact format.
    /// Nil when the asset has no video track (audio-only, unreadable).
    @discardableResult
    public static func probePlayback(asset: AVAsset, path: String) async -> Bool? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first
        else { return nil }
        guard let made = makeDecompressionSession(
            format: format, path: "avplayer-\(path)")
        else { return false }
        VTDecompressionSessionInvalidate(made.session)
        return made.hardware
    }

    // MARK: - Zero-copy CGImage

    /// CGImage over a BGRA pixel buffer's own memory (no pixel copy): the
    /// image retains the buffer and keeps it read-locked until released.
    /// Other formats go through VTCreateCGImageFromCVPixelBuffer.
    public static func cgImage(wrapping buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            var image: CGImage?
            guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr
            else { return nil }
            return image
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let info = Unmanaged.passRetained(buffer).toOpaque()
        guard let provider = CGDataProvider(
            dataInfo: info, data: base, size: stride * h,
            releaseData: { info, _, _ in
                guard let info else { return }
                let pb = Unmanaged<CVPixelBuffer>.fromOpaque(info).takeRetainedValue()
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            })
        else {
            Unmanaged<CVPixelBuffer>.fromOpaque(info).release()
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Report

    /// Recent session lines, newest last (tests + the proof harness).
    public static var recentReports: [String] { ring.snapshot().map(\.line) }
    /// Same lines with their log level (`notice`, `warning`, `error`).
    public static var recentReportEntries: [(level: String, line: String)] { ring.snapshot() }

    private static let ring = ReportRing()

    static func report(
        kind: String, hw: Bool, codec: String, path: String, detail: String,
        fallback: [String], failed: Bool = false
    ) {
        var line = "hw=\(hw) codec=\(codec) path=\(path) kind=\(kind) \(detail)"
        if !fallback.isEmpty { line += " fallback=[\(fallback.joined(separator: ","))]" }
        if failed {
            ring.append(level: "error", line)
            Log.media.error("\(line, privacy: .public)")
        } else if !hw || !fallback.isEmpty {
            // Software (or a lesser mode) in use: never silent.
            ring.append(level: "warning", line)
            Log.media.warning("\(line, privacy: .public)")
        } else {
            ring.append(level: "notice", line)
            Log.media.notice("\(line, privacy: .public)")
        }
    }
}

private final class ReportRing: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(level: String, line: String)] = []
    func append(level: String, _ s: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append((level, s))
        if lines.count > 64 { lines.removeFirst(lines.count - 64) }
    }
    func snapshot() -> [(level: String, line: String)] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
