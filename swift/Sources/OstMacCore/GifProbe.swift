// GifProbe.swift — P4 split: verbatim move from GifPlayback.swift.
import ImageIO
import UniformTypeIdentifiers

/// Animated-GIF detection over raw bytes. Nil where the bytes are not a
/// decodable image at all (mirrors `NSImage(data:)` rejection).
public enum GifProbe {
    /// Browsers clamp near-zero GIF delays; below this a frame would
    /// strobe. Matches the fastest sane frame step.
    public static let minFrameDuration = 0.02

    public static func source(data: Data) -> CGImageSource? {
        guard !data.isEmpty else { return nil }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    /// Frame count for any decodable image (stills report 1).
    public static func frameCount(_ data: Data) -> Int? {
        guard let src = source(data: data) else { return nil }
        let n = CGImageSourceGetCount(src)
        return n > 0 ? n : nil
    }

    /// True only for multi-frame GIFs. Single-frame GIFs and every
    /// still format take the static path (no overlay, no timers).
    public static func isAnimated(_ data: Data) -> Bool {
        guard let src = source(data: data) else { return false }
        return isAnimatedSource(src)
    }

    /// Animated check over an existing source (single-source decode:
    /// callers that already parsed the header skip re-creating it).
    public static func isAnimatedSource(_ src: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(src) as String?,
              UTType(type)?.conforms(to: .gif) == true
        else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// Per-frame display durations in seconds, clamped to the minimum.
    /// Nil for non-images; stills report their single frame.
    public static func durations(_ data: Data) -> [Double]? {
        guard let src = source(data: data) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        return (0 ..< n).map { duration(src: src, index: $0) }
    }

    static func duration(src: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil)
            as? [CFString: Any],
            let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        let d = unclamped > 0 ? unclamped : clamped
        return max(d > 0 ? d : 0.1, minFrameDuration)
    }
}
