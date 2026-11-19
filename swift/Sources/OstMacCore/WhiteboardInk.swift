// WhiteboardInk.swift — WHITEBOARD: local-only ink for the whiteboard
// pane's sketch section.
//
// There is no public board-content API (Graph carries only the tab
// shell: teamsAppId 95de633a-… + the board's content URL; board
// creation lives behind the undocumented whiteboard.microsoft.com
// service), so collaborative ink is impossible here. The shared board
// itself renders through the tab's embed URL; this store holds only
// the user's own sketch strokes, per board, in memory. Nothing here
// is synced, saved to disk, or sent anywhere.
import Combine
import CoreGraphics
import Foundation

/// One local ink stroke: a capped point run plus its pen.
public struct WhiteboardStroke: Equatable, Sendable {
    /// Longest run kept per stroke (bounds one drag's memory).
    public static let maxPoints = 1000
    public var points: [CGPoint]
    public var red: Double
    public var green: Double
    public var blue: Double
    public var width: CGFloat

    public init(points: [CGPoint], red: Double, green: Double, blue: Double, width: CGFloat) {
        self.points = Array(points.prefix(Self.maxPoints))
        self.red = red
        self.green = green
        self.blue = blue
        self.width = width
    }
}

/// Per-board local strokes (in memory only; undo/clear, capped).
@MainActor
public final class WhiteboardInkStore: ObservableObject {
    /// Most strokes kept per board (bounds memory).
    public static let maxStrokes = 200
    @Published public private(set) var boards: [String: [WhiteboardStroke]] = [:]

    public init() {}

    public func strokes(for board: String) -> [WhiteboardStroke] { boards[board] ?? [] }

    public func add(_ stroke: WhiteboardStroke, to board: String) {
        guard !stroke.points.isEmpty else { return }
        var list = boards[board] ?? []
        list.append(stroke)
        boards[board] = Array(list.suffix(Self.maxStrokes))
    }

    public func undo(board: String) {
        guard var list = boards[board], !list.isEmpty else { return }
        list.removeLast()
        boards[board] = list
    }

    public func clear(board: String) {
        boards[board] = []
    }
}
