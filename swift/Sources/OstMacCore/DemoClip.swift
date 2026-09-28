// DemoClip.swift — P4 split: verbatim move from RecordingsDemo.swift.
import AVFoundation
import CoreGraphics
import Foundation

/// Programmatic demo meeting clip (no binary blob): 48 H.264 frames
/// of the DemoMedia sunset with its disc arcing left→right, so every
/// frame's pixels differ. Rendered once, cached in the temp dir.
public enum DemoClip {
    public static let frameCount = 48
    public static let fps: Int32 = 24
    public static let width = 480
    public static let height = 270

    /// Cached clip URL, rendering on first use (blocking encode:
    /// demo callers run this off the main thread).
    public static func url() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("om-recordings-demo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("demo-meeting.mp4")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try render(to: out)
        return out
    }

    static func render(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else {
            throw MediaFetchError.failed("demo clip writer rejected input")
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0 ..< frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let px = makeFrame(i) else {
                throw MediaFetchError.failed("demo clip frame \(i) failed")
            }
            adaptor.append(
                px, withPresentationTime: CMTime(
                    value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        var finishError: Error?
        writer.finishWriting {
            finishError = writer.error
            done.signal()
        }
        done.wait()
        if let e = finishError {
            throw MediaFetchError.failed("demo clip finish: \(e)")
        }
    }

    /// One sunset frame (progress 0…1 across the loop).
    static func makeFrame(_ i: Int) -> CVPixelBuffer? {
        let f = Double(i) / Double(frameCount - 1)
        var px: CVPixelBuffer?
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32ARGB, nil,
            &px) == kCVReturnSuccess, let buf = px
        else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let top = CGColor(
            red: 0.13 - 0.06 * f, green: 0.16 - 0.08 * f,
            blue: 0.38 - 0.10 * f, alpha: 1)
        let bottom = CGColor(
            red: 0.98 - 0.55 * f, green: 0.55 - 0.30 * f,
            blue: 0.30 + 0.10 * f, alpha: 1)
        let grad = CGGradient(
            colorsSpace: space, colors: [top, bottom] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(
            grad, start: CGPoint(x: 0, y: h),
            end: CGPoint(x: 0, y: 0), options: [])
        ctx.setFillColor(CGColor(
            red: 1, green: 0.85 - 0.25 * f, blue: 0.55, alpha: 1))
        let dx = w * (0.15 + 0.55 * f)
        let dy = h * (0.58 - 0.22 * f)
        ctx.fillEllipse(in: CGRect(
            x: dx, y: dy, width: w * 0.14, height: w * 0.14))
        ctx.setFillColor(CGColor(
            red: 0.12, green: 0.20, blue: 0.34, alpha: 0.92))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.22))
        return buf
    }
}
