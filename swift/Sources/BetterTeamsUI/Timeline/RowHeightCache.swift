// RowHeightCache.swift — explicit, cached row heights (UI-SPEC §6.2.1,
// DL4). Each row is measured once at the current column width and
// cached by (id, revision, width, ContentTextScale); `heightOfRow` reads
// the cache, so estimated heights never self-correct mid-scroll.
import CoreGraphics

public struct RowHeightKey: Hashable, Sendable {
    public var id: String
    public var revision: Int
    /// Width in whole points (sub-point jitter never re-measures).
    public var width: Int
    /// Scale in hundredths.
    public var scale: Int

    public init(id: String, revision: Int, width: CGFloat, scale: Double) {
        self.id = id
        self.revision = revision
        self.width = Int(width.rounded())
        self.scale = Int((scale * 100).rounded())
    }
}

public final class RowHeightCache {
    private var store: [RowHeightKey: CGFloat] = [:]
    public private(set) var measurements = 0

    public init() {}

    public func height(for key: RowHeightKey, measure: () -> CGFloat) -> CGFloat {
        if let h = store[key] { return h }
        let h = max(1, measure().rounded(.up))
        measurements += 1
        store[key] = h
        return h
    }

    public func cached(_ key: RowHeightKey) -> CGFloat? { store[key] }

    /// Drops entries for other widths/scales (bounded memory after a
    /// resize or text-size change).
    public func retain(width: CGFloat, scale: Double) {
        let w = Int(width.rounded())
        let s = Int((scale * 100).rounded())
        store = store.filter { $0.key.width == w && $0.key.scale == s }
    }

    public func removeAll() { store.removeAll() }

    public var count: Int { store.count }
}
