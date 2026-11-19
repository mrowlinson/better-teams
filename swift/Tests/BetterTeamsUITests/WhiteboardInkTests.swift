// WhiteboardInkTests.swift — WHITEBOARD: local-only ink model for the
// whiteboard pane (no public board-content API exists, so ink is
// per-board local state, never synced).
import Foundation
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class WhiteboardInkTests: XCTestCase {
    private func stroke(_ xs: CGFloat...) -> WhiteboardStroke {
        WhiteboardStroke(points: xs.map { CGPoint(x: $0, y: $0) },
                         red: 0, green: 0, blue: 0, width: 3)
    }

    func testAddUndoClear() {
        let store = WhiteboardInkStore()
        XCTAssertTrue(store.strokes(for: "b1").isEmpty)
        store.add(stroke(1, 2), to: "b1")
        store.add(stroke(3), to: "b1")
        XCTAssertEqual(store.strokes(for: "b1").count, 2)
        store.undo(board: "b1")
        XCTAssertEqual(store.strokes(for: "b1").count, 1)
        store.clear(board: "b1")
        XCTAssertTrue(store.strokes(for: "b1").isEmpty)
    }

    func testUndoEmptyIsNoOp() {
        let store = WhiteboardInkStore()
        store.undo(board: "missing")
        store.clear(board: "missing")
        XCTAssertTrue(store.strokes(for: "missing").isEmpty)
    }

    func testBoardsAreIsolated() {
        let store = WhiteboardInkStore()
        store.add(stroke(1), to: "b1")
        XCTAssertTrue(store.strokes(for: "b2").isEmpty)
        store.clear(board: "b1")
        XCTAssertTrue(store.strokes(for: "b1").isEmpty)
    }

    func testCapsBoundMemory() {
        let store = WhiteboardInkStore()
        for i in 0..<(WhiteboardInkStore.maxStrokes + 5) {
            store.add(stroke(CGFloat(i)), to: "b1")
        }
        XCTAssertEqual(store.strokes(for: "b1").count, WhiteboardInkStore.maxStrokes)
        let many = (0..<(WhiteboardStroke.maxPoints + 10)).map { CGPoint(x: CGFloat($0), y: 0) }
        store.add(WhiteboardStroke(points: many, red: 0, green: 0, blue: 0, width: 3), to: "b2")
        XCTAssertEqual(store.strokes(for: "b2").count, 1)
        XCTAssertEqual(store.strokes(for: "b2").first?.points.count, WhiteboardStroke.maxPoints)
    }

    func testSketchCaptionStatesLocalOnly() {
        XCTAssertTrue(WhiteboardSketchView.localOnlyCaption.localizedCaseInsensitiveContains("not shared")
            || WhiteboardSketchView.localOnlyCaption.localizedCaseInsensitiveContains("local"))
    }
}
