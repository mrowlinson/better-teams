// GifClip.swift — P4 split: verbatim move from GifPlayback.swift.
import AppKit
import Foundation
import ImageIO

/// Decoded animation: downsampled frames + durations. Nil unless the
/// bytes are an animated GIF (see GifProbe).
public struct GifClip: Sendable {
    public let frames: [NSImage]
    public let durations: [Double]

    /// Frame cap: huge GIFs stride-sample down to this many frames
    /// (durations scale by the stride, so the loop keeps its length).
    public static let maxFrames = 60

    public init(frames: [NSImage], durations: [Double]) {
        self.frames = frames
        self.durations = durations
    }

    public var totalDuration: Double { durations.reduce(0, +) }

    /// Stride-sampled frame indices for a count over the cap.
    /// Pure so tests pin the sampling without a 200-frame fixture.
    public static func sampledIndices(count: Int, max: Int = maxFrames) -> [Int] {
        guard count > max, max > 0 else { return Array(0 ..< Swift.max(count, 0)) }
        let stride = Double(count) / Double(max)
        return (0 ..< max).map { Int(Double($0) * stride) }
    }

    /// Loop position → frame index. Degenerate inputs (no/zero total
    /// duration, negative time) pin to frame 0; time wraps modulo the loop.
    public static func frameIndex(at time: Double, durations: [Double]) -> Int {
        guard !durations.isEmpty else { return 0 }
        let total = durations.reduce(0, +)
        guard total > 0, time > 0 else { return 0 }
        var t = time.truncatingRemainder(dividingBy: total)
        // Exact loop boundary (t == 0 after wrap, time > 0) restarts at 0.
        if t == 0 { return 0 }
        for (i, d) in durations.enumerated() {
            if t < d { return i }
            t -= d
        }
        return durations.count - 1
    }

    /// Downsampled per-frame decode, synchronous (call off the main thread).
    public static func decode(data: Data, maxPixels: CGFloat) -> GifClip? {
        guard let src = GifProbe.source(data: data),
              GifProbe.isAnimatedSource(src)
        else { return nil }
        return decode(src: src, maxPixels: maxPixels)
    }

    /// Per-frame decode over an existing (already animated-checked)
    /// source. Nil when a frame fails to decode.
    public static func decode(src: CGImageSource, maxPixels: CGFloat) -> GifClip? {
        let count = CGImageSourceGetCount(src)
        let indices = sampledIndices(count: count)
        let stride = Double(count) / Double(Swift.max(indices.count, 1))
        let opts: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        var frames: [NSImage] = []
        var durations: [Double] = []
        frames.reserveCapacity(indices.count)
        for i in indices {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts) else {
                return nil
            }
            frames.append(NSImage(
                cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            durations.append(GifProbe.duration(src: src, index: i) * stride)
        }
        guard !frames.isEmpty else { return nil }
        return GifClip(frames: frames, durations: durations)
    }

    /// Downsampled per-frame decode off the caller's actor.
    public static func decodeOffMain(data: Data, maxPixels: CGFloat) async -> GifClip? {
        await Task.blocking(priority: .userInitiated) {
            decode(data: data, maxPixels: maxPixels)
        }.value
    }
}
