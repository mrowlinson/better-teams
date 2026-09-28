// ImageDecode.swift — om-s3-mediahot: off-main, downsampled image decode.
//
// Bubble and viewer models used to run `NSImage(data:)` on the main actor
// at full pixel size. Decode now runs detached and downsamples to the
// display slot via ImageIO thumbnails: bubbles to the 260pt slot @2x,
// the zoom viewer to a 2048px cap (still full-detail at its zoom range).
import AppKit
import CryptoKit
import ImageIO

public enum ImageDecode {
    /// sha256 hex of raw bytes (nibble table, no `String(format:)`).
    public static func bytesHex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: 0, count: SHA256.byteCount * 2)
        for (i, byte) in digest.enumerated() {
            out[i * 2] = hex[Int(byte >> 4)]
            out[i * 2 + 1] = hex[Int(byte & 0x0F)]
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Bubble slot (260×200pt) at 2x retina.
    public static let bubbleMaxPixels: CGFloat = 520
    /// Zoom-viewer cap: keeps full detail for fit-width + 400% zoom on
    /// typical photos while bounding huge-image memory.
    public static let viewerMaxPixels: CGFloat = 2048

    /// Downsampled decode, synchronous (call off the main thread).
    /// Nil for empty/non-image data, like `NSImage(data:)`.
    public static func thumbnail(data: Data, maxPixels: CGFloat) -> NSImage? {
        guard !data.isEmpty else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return thumbnail(src: src, maxPixels: maxPixels)
    }

    /// Downsampled decode over an existing source (single-source path).
    public static func thumbnail(src: CGImageSource, maxPixels: CGFloat) -> NSImage? {
        let opts: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Downsampled decode off the caller's actor.
    public static func decodeOffMain(data: Data, maxPixels: CGFloat) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            thumbnail(data: data, maxPixels: maxPixels)
        }.value
    }

    /// One-source still-or-clip decode, synchronous (call off main).
    /// Replaces the probe-then-decode shape (2–3 image sources per
    /// load) with a single parse: nil for empty/non-image data, like
    /// `NSImage(data:)`; animated GIFs decode to `.animated`.
    public static func decoded(data: Data, maxPixels: CGFloat) -> DecodedImage? {
        guard !data.isEmpty else { return nil }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        if GifProbe.isAnimatedSource(src) {
            guard let clip = GifClip.decode(src: src, maxPixels: maxPixels),
                  !clip.frames.isEmpty
            else { return nil }
            return .animated(clip)
        }
        guard let img = thumbnail(src: src, maxPixels: maxPixels) else { return nil }
        return .still(img)
    }

    /// One-source still-or-clip decode off the caller's actor.
    public static func decodedOffMain(data: Data, maxPixels: CGFloat) async -> DecodedImage? {
        await Task.detached(priority: .userInitiated) {
            decoded(data: data, maxPixels: maxPixels)
        }.value
    }
}

/// Still-or-animated decode result (see `ImageDecode.decoded`).
public enum DecodedImage: Sendable {
    case still(NSImage)
    case animated(GifClip)

    /// First frame (the paused / Reduce Motion still for clips).
    public var firstFrame: NSImage? {
        switch self {
        case let .still(img): return img
        case let .animated(clip): return clip.frames.first
        }
    }

    /// Approximate pixel footprint (4 bytes/pixel/frame) for cache cost.
    public var pixelBytes: Int {
        switch self {
        case let .still(img):
            return Int(img.size.width * img.size.height) * 4
        case let .animated(clip):
            return clip.frames.reduce(0) {
                $0 + Int($1.size.width * $1.size.height) * 4
            }
        }
    }
}

/// NSObject box for the decoded memo (NSCache needs class values).
final class DecodedImageBox: NSObject {
    let value: DecodedImage
    init(_ value: DecodedImage) { self.value = value }
}

/// Decoded-image memo (om-perf-swift-media): one decode per
/// (bytes-sha256, maxPixels). Keying on the bytes (not the URL key)
/// shares across re-appears AND forwards/duplicates of the same
/// image in different messages; a sha256 (~µs) is noise next to a
/// decode (~ms). Entries never invalidate (bytes are content); NSCache
/// bounds memory by pixel bytes.
public actor DecodedImageCache {
    public static let shared = DecodedImageCache()

    public struct Stats: Sendable, Equatable {
        public var hits = 0
        public var misses = 0
    }

    private let memory = NSCache<NSString, DecodedImageBox>()
    private var hits = 0
    private var misses = 0

    public init(memoryLimitMB: Int = 64) {
        memory.totalCostLimit = memoryLimitMB * 1024 * 1024
    }

    public func stats() -> Stats { Stats(hits: hits, misses: misses) }

    public func clear() {
        memory.removeAllObjects()
    }

    /// Memoized decode: hit returns the stored image; miss decodes
    /// off-main once and stores it. Nil results are never stored
    /// (failures retry, like the bytes cache).
    public func decoded(data: Data, maxPixels: CGFloat) async -> DecodedImage? {
        let k = "\(ImageDecode.bytesHex(data))#\(Int(maxPixels))"
        if let hit = memory.object(forKey: k as NSString) {
            hits += 1
            return hit.value
        }
        misses += 1
        guard let result = await ImageDecode.decodedOffMain(
            data: data, maxPixels: maxPixels)
        else { return nil }
        memory.setObject(
            DecodedImageBox(result), forKey: k as NSString,
            cost: max(1, result.pixelBytes))
        return result
    }
}
