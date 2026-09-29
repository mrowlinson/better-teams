// ImageViewerState.swift — IMGVIEW: pure navigation + zoom math for the
// full-resolution image viewer (views stay thin; tests pin the contract).
import CoreGraphics

/// One viewable image: the timeline (thumbnail) URL plus its message.
public struct ImageViewerItem: Sendable, Equatable, Hashable {
    public let url: String
    public let messageID: String
    public let alt: String
    /// The `<img>` tag's width/height attributes, when both are present
    /// (IMGWIN2: sizes the viewer before the original arrives).
    public let pixelSize: CGSize?

    public init(url: String, messageID: String, alt: String = "", pixelSize: CGSize? = nil) {
        self.url = url
        self.messageID = messageID
        self.alt = alt
        self.pixelSize = pixelSize
    }

    /// Same image (URL + message), whatever metadata either side carries.
    public func isSameImage(as other: ImageViewerItem) -> Bool {
        url == other.url && messageID == other.messageID
    }

    public static func == (a: ImageViewerItem, b: ImageViewerItem) -> Bool {
        a.url == b.url && a.messageID == b.messageID && a.alt == b.alt
            && a.pixelSize?.width == b.pixelSize?.width && a.pixelSize?.height == b.pixelSize?.height
    }

    public func hash(into h: inout Hasher) {
        h.combine(url)
        h.combine(messageID)
        h.combine(alt)
    }
}

/// ←/→ between the images of one chat, oldest first (timeline order).
public struct ImageViewerNav: Sendable, Equatable {
    public let items: [ImageViewerItem]
    public private(set) var index: Int

    /// Starts on `current`; when it is not in `items` (e.g. a card image)
    /// the viewer shows it alone.
    public init(items: [ImageViewerItem], current: ImageViewerItem) {
        if let i = items.firstIndex(where: { $0.isSameImage(as: current) }) {
            self.items = items
            index = i
        } else {
            self.items = [current]
            index = 0
        }
    }

    public var current: ImageViewerItem { items[index] }
    public var canPrevious: Bool { index > 0 }
    public var canNext: Bool { index < items.count - 1 }
    /// "3 of 7" (nil for a single image).
    public var position: String? { items.count > 1 ? "\(index + 1) of \(items.count)" : nil }

    /// Steps by `delta`; no wrap (Teams stops at the ends). False at an end.
    @discardableResult
    public mutating func move(by delta: Int) -> Bool {
        let n = index + delta
        guard items.indices.contains(n) else { return false }
        index = n
        return true
    }

    /// Every non-emoticon inline image in `messages`, in order, with the
    /// tag's width/height when it has both.
    public static func items(from messages: [ChatMessage]) -> [ImageViewerItem] {
        messages.filter { !$0.deleted }.flatMap { m in
            let sizes = tagSizes(m.raw)
            return MessageRender.images(fromRaw: m.raw)
                .filter { !$0.isEmoticon }
                .map { ImageViewerItem(url: $0.url, messageID: m.id, alt: $0.alt, pixelSize: sizes[$0.url]) }
        }
    }

    /// `src` → width×height from the `<img>` attributes (both > 0).
    static func tagSizes(_ raw: String?) -> [String: CGSize] {
        guard let raw, raw.range(of: "width", options: .caseInsensitive) != nil else { return [:] }
        var out: [String: CGSize] = [:]
        for tag in MessageRender.imgTags(in: raw) {
            let a = MessageRender.attributes(of: tag)
            guard let src = a["src"]?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty,
                  let w = a["width"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  let h = a["height"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
                  w > 0, h > 0 else { continue }
            out[MessageRender.decodeEntities(src)] = CGSize(width: w, height: h)
        }
        return out
    }
}

/// Magnification math. `imageSize` is the displayed decode in points;
/// `pixelSize` the original (so Actual Size = one original pixel per
/// point even when the decode was downsampled for memory).
public enum ImageViewerZoom {
    public static let step: CGFloat = 1.25
    public static let maxOverActual: CGFloat = 8

    /// One original pixel per point.
    public static func actual(imageSize: CGSize, pixelSize: CGSize?) -> CGFloat {
        guard let p = pixelSize, imageSize.width > 0, p.width > 0 else { return 1 }
        return p.width / imageSize.width
    }

    /// Whole image visible; never upscaled past Actual Size (small
    /// images sit at natural size, like Teams).
    public static func fit(imageSize: CGSize, viewport: CGSize, pixelSize: CGSize?) -> CGFloat {
        let a = actual(imageSize: imageSize, pixelSize: pixelSize)
        guard imageSize.width > 0, imageSize.height > 0, viewport.width > 0, viewport.height > 0 else { return a }
        return min(a, viewport.width / imageSize.width, viewport.height / imageSize.height)
    }

    public static func minimum(fit: CGFloat) -> CGFloat { min(fit, 0.1) }
    public static func maximum(actual: CGFloat) -> CGFloat { actual * maxOverActual }

    public static func zoomIn(_ m: CGFloat, fit: CGFloat, actual: CGFloat) -> CGFloat {
        min(m * step, maximum(actual: actual))
    }

    public static func zoomOut(_ m: CGFloat, fit: CGFloat, actual: CGFloat) -> CGFloat {
        max(m / step, minimum(fit: fit))
    }

    /// Double-click: fitted → Actual Size (2× fit when the image already
    /// fits at actual); anything else → fit.
    public static func toggle(_ m: CGFloat, fit: CGFloat, actual: CGFloat) -> CGFloat {
        guard abs(m - fit) < 0.001 else { return fit }
        return abs(actual - fit) < 0.001 ? min(fit * 2, maximum(actual: actual)) : actual
    }
}

/// IMGWIN: viewer window sizing. The window aspect-fits the image at its
/// natural point size (never upscaled), scaled down uniformly until the
/// whole window — chrome included — covers at most `maxAreaFraction` of
/// the screen's visible area and at most `maxSideFraction` of each side.
public enum ImageViewerWindowFit {
    public static let maxAreaFraction: CGFloat = 0.4
    public static let maxSideFraction: CGFloat = 0.9

    /// Uniform image scale (≤ 1) so `image * s + chrome` fits the budget.
    public static func scale(image: CGSize, chrome: CGSize, screen: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, screen.width > 0, screen.height > 0 else { return 1 }
        let budget = screen.width * screen.height * maxAreaFraction
        // (s·w + cw)(s·h + ch) ≤ budget → a·s² + b·s + c ≤ 0.
        let a = image.width * image.height
        let b = image.width * chrome.height + image.height * chrome.width
        let c = chrome.width * chrome.height - budget
        let disc = max(b * b - 4 * a * c, 0)
        let byArea = (-b + disc.squareRoot()) / (2 * a)
        let byWidth = (screen.width * maxSideFraction - chrome.width) / image.width
        let byHeight = (screen.height * maxSideFraction - chrome.height) / image.height
        return max(min(1, byArea, byWidth, byHeight), 0)
    }

    /// Window size for `image`; never below `minimum` (tiny images sit
    /// centered in a window the chrome fits), never above 90% per side.
    public static func windowSize(image: CGSize, chrome: CGSize, minimum: CGSize, screen: CGSize) -> CGSize {
        let s = scale(image: image, chrome: chrome, screen: screen)
        let w = (image.width * s + chrome.width).rounded()
        let h = (image.height * s + chrome.height).rounded()
        return CGSize(width: min(max(w, minimum.width), (screen.width * maxSideFraction).rounded(.down)),
                      height: min(max(h, minimum.height), (screen.height * maxSideFraction).rounded(.down)))
    }

    /// Frame of `size` centered in `visible` (a screen's visibleFrame).
    public static func centered(_ size: CGSize, in visible: CGRect) -> CGRect {
        CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
               width: size.width, height: size.height)
    }
}

/// IMGWIN2: the natural size the viewer window is sized for BEFORE it is
/// ordered in; the frame never changes while it is on screen (an image
/// that lands with another size or aspect is letterboxed inside it).
public enum ImageViewerOpenSize {
    /// Stand-in size when only the aspect is known: big enough that the
    /// window budget (`ImageViewerWindowFit`) always caps it.
    public static let aspectOnlyLongSide: CGFloat = 100_000
    /// Tag sizes at or under this are display sizes (Teams stores the
    /// compose-box size), trusted for their aspect only.
    public static let metadataMinLongSide: CGFloat = 520

    /// First known of: the cached original's header size; the tag's
    /// width/height (as a size when above the display cap, else its
    /// aspect); the thumbnail's aspect; 4:3.
    public static func natural(cached: CGSize?, metadata: CGSize?, thumb: CGSize?) -> CGSize {
        if let c = cached, valid(c) { return c }
        if let m = metadata, valid(m) {
            return max(m.width, m.height) > metadataMinLongSide ? m : aspectOnly(m)
        }
        if let t = thumb, valid(t) { return aspectOnly(t) }
        return aspectOnly(CGSize(width: 4, height: 3))
    }

    /// FIXPACK F7: whether the header of the original is worth fetching
    /// before the window opens: not cached, and the tag gave no size (or
    /// only a display-size stand-in, trusted for aspect alone).
    public static func needsHeader(cached: CGSize?, metadata: CGSize?) -> Bool {
        if let c = cached, valid(c) { return false }
        guard let m = metadata, valid(m) else { return true }
        return max(m.width, m.height) <= metadataMinLongSide
    }

    static func valid(_ s: CGSize) -> Bool { s.width >= 1 && s.height >= 1 && s.width.isFinite && s.height.isFinite }

    static func aspectOnly(_ s: CGSize) -> CGSize {
        let k = aspectOnlyLongSide / max(s.width, s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }
}
