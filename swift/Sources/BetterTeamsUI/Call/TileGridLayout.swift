// TileGridLayout.swift — the call stage grid (UI-SPEC R8, §8): places
// n tiles at a fixed aspect ratio, picking the column count that gives
// the largest tile inside the proposed size; rows are centered. Pure
// function of the proposal (no geometry readers, no feedback loop).
import SwiftUI

struct TileGridLayout: Layout {
    var spacing: CGFloat = 8
    var aspect: CGFloat = 16.0 / 9.0

    struct Grid: Equatable {
        var columns: Int
        var rows: Int
        var tile: CGSize
    }

    /// Best grid for `count` tiles in `size` (largest tile area).
    static func grid(count: Int, in size: CGSize, spacing: CGFloat, aspect: CGFloat) -> Grid {
        guard count > 0, size.width > 0, size.height > 0 else { return Grid(columns: 1, rows: 1, tile: .zero) }
        var best = Grid(columns: 1, rows: count, tile: .zero)
        for cols in 1...count {
            let rows = (count + cols - 1) / cols
            var w = (size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            var h = w / aspect
            let maxH = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            if h > maxH {
                h = maxH
                w = h * aspect
            }
            guard w > 0, h > 0 else { continue }
            if w * h > best.tile.width * best.tile.height {
                best = Grid(columns: cols, rows: rows, tile: CGSize(width: floor(w), height: floor(h)))
            }
        }
        return best
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 360))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = subviews.count
        guard n > 0 else { return }
        let g = Self.grid(count: n, in: bounds.size, spacing: spacing, aspect: aspect)
        let gridHeight = CGFloat(g.rows) * g.tile.height + CGFloat(g.rows - 1) * spacing
        let top = bounds.minY + (bounds.height - gridHeight) / 2
        for (i, v) in subviews.enumerated() {
            let row = i / g.columns, col = i % g.columns
            let inRow = min(g.columns, n - row * g.columns)
            let rowWidth = CGFloat(inRow) * g.tile.width + CGFloat(inRow - 1) * spacing
            let x = bounds.minX + (bounds.width - rowWidth) / 2 + CGFloat(col) * (g.tile.width + spacing)
            let y = top + CGFloat(row) * (g.tile.height + spacing)
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: g.tile.width, height: g.tile.height))
        }
    }
}
