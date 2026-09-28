// RemoteImageModel.swift — P4 split: verbatim move from RemoteImage.swift.
import AppKit
import Combine
import Foundation

@MainActor
public final class RemoteImageModel: ObservableObject {
    @Published public private(set) var phase: RemoteImagePhase = .loading
    @Published public private(set) var image: NSImage?
    /// Decoded animation when the bytes are multi-frame (om-gif-playback).
    /// `image` still holds frame 0 — the paused / Reduce Motion still.
    @Published public private(set) var gif: GifClip?
    public var isAnimated: Bool { gif != nil }
    public private(set) var url: String
    public private(set) var messageID: String
    private let cache: RichMediaCache
    private let fetcher: RichMediaCache.Fetcher
    private let decodedCache: DecodedImageCache

    public init(
        url: String, messageID: String,
        cache: RichMediaCache = .shared,
        fetcher: RichMediaCache.Fetcher? = nil,
        decodedCache: DecodedImageCache = .shared
    ) {
        self.url = url
        self.messageID = messageID
        self.cache = cache
        self.fetcher = fetcher ?? { try await RichMediaCache.defaultFetch(url: $0) }
        self.decodedCache = decodedCache
    }

    /// Load once; no-op while loaded or already loading the same key.
    public func load() {
        guard phase == .loading, image == nil else { return }
        Task { await reload() }
    }

    public func reload() async {
        phase = .loading
        image = nil
        gif = nil
        do {
            let data = try await cache.data(url: url, messageID: messageID, fetcher: fetcher)
            // Memoized one-source decode (scroll churn + duplicates
            // reuse the stored image instead of re-decoding per appear).
            guard let result = await decodedCache.decoded(
                data: data, maxPixels: ImageDecode.bubbleMaxPixels)
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
