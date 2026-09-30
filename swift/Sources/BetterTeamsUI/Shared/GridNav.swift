// GridNav.swift — pure arrow-key movement over a row-major picker grid
// (emoji + GIF pickers; ported from om-a3-keyboard, GridNavTests deleted
// with the old UI). Horizontal steps stay inside the row (no wrap);
// vertical steps move a row, clamped to the last item on a short last row.
import Foundation

enum GridNav {
    /// Stepped index, clamped into `0 ..< count` (0 when empty).
    static func move(current: Int, dx: Int, dy: Int, columns: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let cols = max(columns, 1)
        let start = min(max(current, 0), count - 1)
        let row = start / cols
        let col = start % cols
        let maxRow = (count - 1) / cols
        let newRow = min(max(row + dy, 0), maxRow)
        let newCol = min(max(col + dx, 0), cols - 1)
        return min(newRow * cols + newCol, count - 1)
    }
}
