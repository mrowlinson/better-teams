// FullResImageModel.swift — P4 split: verbatim move from ImageFullRes.swift.
import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Full-res load state for one open viewer. Mirrors RemoteImageModel's
/// shape (phase + image + reload) with the thumbnail held alongside:
/// the view shows `image ?? thumb` so loading and failure never blank.
@MainActor
public final class FullResImageModel: ObservableObject {
    @Published public private(set) var phase: RemoteImagePhase = .loading
    @Published public private(set) var image: NSImage?
    /// Decoded animation when the full-res bytes are multi-frame
    /// (om-gif-playback). `image` still holds frame 0.
    @Published public private(set) var gif: GifClip?
    public var isAnimated: Bool { gif != nil }
    /// Original bytes as fetched (Save / Copy / Share use these, never
    /// the downsampled display decode). Nil until loaded.
    @Published public private(set) var originalData: Data?
    /// Pixel size of the original (the display decode may be smaller).
    @Published public private(set) var pixelSize: CGSize?
    /// Original file type (jpeg/png/gif/…), from the bytes.
    public private(set) var originalType: UTType?
    /// What the viewer shows: the full image once decoded, else the
    /// thumbnail placeholder (loading and failure never blank).
    public var displayImage: NSImage? { image ?? thumb }
    /// True while the full image is still on its way.
    public var isLoadingFull: Bool { phase == .loading }
    /// Display decode cap (screen-sized; the original stays in `originalData`).
    public let maxPixels: CGFloat
    private var started = false
    public let thumbURL: String
    public let fullURL: String
    public let messageID: String
    public let thumb: NSImage?
    private let cache: RichMediaCache
    private let fetcher: RichMediaCache.Fetcher
    private let decodedCache: DecodedImageCache

    public init(
        thumbURL: String, messageID: String,
        thumb: NSImage? = nil,
        cache: RichMediaCache = .shared,
        fetcher: RichMediaCache.Fetcher? = nil,
        decodedCache: DecodedImageCache = .shared,
        maxPixels: CGFloat = ImageDecode.viewerMaxPixels
    ) {
        self.thumbURL = thumbURL
        self.fullURL = ImageFullRes.fullResURL(for: thumbURL)
        self.messageID = messageID
        self.thumb = thumb
        self.cache = cache
        self.fetcher = fetcher ?? { try await RichMediaCache.defaultFetch(url: $0) }
        self.decodedCache = decodedCache
        self.maxPixels = maxPixels
    }

    /// Load once; no-op while loaded or already loading.
    public func load() {
        guard !started, phase == .loading, image == nil else { return }
        started = true
        Task { await reload() }
    }

    /// Fetch full-res bytes (cache first), decoding to an image.
    /// The thumbnail is untouched throughout — it stays on screen
    /// behind loading and failure states.
    public func reload() async {
        phase = .loading
        image = nil
        gif = nil
        do {
            let data = try await cache.data(
                url: fullURL, messageID: messageID, fetcher: fetcher)
            // Memoized one-source decode (reopens reuse the stored
            // image instead of re-decoding the same bytes per open).
            guard let result = await decodedCache.decoded(
                data: data, maxPixels: maxPixels)
            else {
                phase = .failed("not an image")
                return
            }
            switch result {
            case let .still(img):
                image = img
            case let .animated(clip):
                image = clip.frames.first
                gif = clip
            }
            originalData = data
            (pixelSize, originalType) = Self.probe(data)
            phase = .loaded
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Original pixel size + type from the image header (no decode).
    nonisolated static func probe(_ data: Data) -> (CGSize?, UTType?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return (nil, nil) }
        let type = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return (nil, type) }
        // EXIF orientations 5–8 rotate 90°: the decode (with transform)
        // is h×w, so report the displayed orientation.
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (o >= 5 && o <= 8 ? CGSize(width: h, height: w) : CGSize(width: w, height: h), type)
    }
}
