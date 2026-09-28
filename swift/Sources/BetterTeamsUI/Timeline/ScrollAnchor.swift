// ScrollAnchor.swift — pure scroll policy (UI-SPEC §6.2.1), unit-tested
// on synthetic row frames. Coordinates are flipped (y grows down).
import CoreGraphics

public enum ScrollAnchor: Equatable, Sendable {
    /// Within `bottomTolerance` of the bottom; updates keep it pinned.
    case pinnedToBottom
    /// The anchor row's offset from the visible top is restored after
    /// any update (history prepend, height change).
    case anchored(id: String, offset: CGFloat)
    /// Center a row (and highlight it).
    case jump(id: String)

    public static let bottomTolerance: CGFloat = 24

    public struct Row: Sendable {
        public var id: String
        public var minY: CGFloat
        public var maxY: CGFloat

        public init(id: String, minY: CGFloat, maxY: CGFloat) {
            self.id = id
            self.minY = minY
            self.maxY = maxY
        }
    }

    public static func isPinned(visibleMinY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        contentHeight - (visibleMinY + visibleHeight) <= bottomTolerance
    }

    /// The anchor to keep across an update.
    public static func capture(visibleMinY: CGFloat, visibleHeight: CGFloat, contentHeight: CGFloat,
                               rows: [Row]) -> ScrollAnchor {
        if isPinned(visibleMinY: visibleMinY, visibleHeight: visibleHeight, contentHeight: contentHeight) {
            return .pinnedToBottom
        }
        guard let top = rows.first(where: { $0.maxY > visibleMinY }) else { return .pinnedToBottom }
        return .anchored(id: top.id, offset: top.minY - visibleMinY)
    }

    /// Scroll origin (visible top) that honors `anchor` after an update.
    /// Nil when the anchor row is gone (caller keeps its position).
    public static func restoreOriginY(_ anchor: ScrollAnchor, contentHeight: CGFloat, visibleHeight: CGFloat,
                                      frame: (String) -> (minY: CGFloat, maxY: CGFloat)?) -> CGFloat? {
        let maxOrigin = max(0, contentHeight - visibleHeight)
        switch anchor {
        case .pinnedToBottom:
            return maxOrigin
        case .anchored(let id, let offset):
            guard let f = frame(id) else { return nil }
            return min(maxOrigin, max(0, f.minY - offset))
        case .jump(let id):
            guard let f = frame(id) else { return nil }
            let mid = (f.minY + f.maxY) / 2
            return min(maxOrigin, max(0, mid - visibleHeight / 2))
        }
    }
}
