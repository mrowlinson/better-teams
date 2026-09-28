// FullResImageModel.swift — P4 split: verbatim move from ImageFullRes.swift.
import AppKit
import Combine
import Foundation

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
        decodedCache: DecodedImageCache = .shared
    ) {
        self.thumbURL = thumbURL
        self.fullURL = ImageFullRes.fullResURL(for: thumbURL)
        self.messageID = messageID
        self.thumb = thumb
        self.cache = cache
        self.fetcher = fetcher ?? { try await RichMediaCache.defaultFetch(url: $0) }
        self.decodedCache = decodedCache
    }

    /// Load once; no-op while loaded or already loading.
    public func load() {
        guard phase == .loading, image == nil else { return }
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
                data: data, maxPixels: ImageDecode.viewerMaxPixels)
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
            phase = .loaded
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
