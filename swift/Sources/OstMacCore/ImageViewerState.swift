// ImageViewerState.swift — IMGVIEW: pure navigation + zoom math for the
// full-resolution image viewer (views stay thin; tests pin the contract).
import CoreGraphics

/// One viewable image: the timeline (thumbnail) URL plus its message.
public struct ImageViewerItem: Sendable, Equatable, Hashable {
    public let url: String
    public let messageID: String
    public let alt: String

    public init(url: String, messageID: String, alt: String = "") {
        self.url = url
        self.messageID = messageID
        self.alt = alt
    }
}

/// ←/→ between the images of one chat, oldest first (timeline order).
public struct ImageViewerNav: Sendable, Equatable {
    public let items: [ImageViewerItem]
    public private(set) var index: Int

    /// Starts on `current`; when it is not in `items` (e.g. a card image)
    /// the viewer shows it alone.
    public init(items: [ImageViewerItem], current: ImageViewerItem) {
        if let i = items.firstIndex(of: current) {
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

    /// Every non-emoticon inline image in `messages`, in order.
    public static func items(from messages: [ChatMessage]) -> [ImageViewerItem] {
        messages.filter { !$0.deleted }.flatMap { m in
            MessageRender.images(fromRaw: m.raw)
                .filter { !$0.isEmoticon }
                .map { ImageViewerItem(url: $0.url, messageID: m.id, alt: $0.alt) }
        }
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
