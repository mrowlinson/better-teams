// ComposerLayoutTests.swift — guard for the owner's composer layout spec:
// "this text box [is] 2 lines tall" and no blank space left below it.
// Any change of the minimum height or a reserved gap under the field
// fails here, loudly. (History: the 2-line spec landed in c14b903, the
// Diet-era tests were deleted with the UI purge, and the rewrite's height
// test encoded 1 line, so the regression passed silently.)
import AppKit
import XCTest

@testable import BetterTeamsUI

@MainActor
final class ComposerLayoutTests: XCTestCase {
    func testMinimumIsExactlyTwoLines() {
        XCTAssertEqual(ComposerTextView.minLines, 2, "the composer field must stay 2 lines tall")
        for scale in [0.85, 1.0, 1.25] {
            let font = ComposerTextView.font(scale)
            let line = NSLayoutManager().defaultLineHeight(for: font)
            let empty = ComposerTextView.height(for: "", width: 320, font: font)
            XCTAssertEqual(empty, (line * 2).rounded(.up), accuracy: 1, "empty field, scale \(scale)")
            XCTAssertEqual(ComposerTextView.height(for: "short", width: 320, font: font), empty, "one line, scale \(scale)")
            XCTAssertEqual(ComposerTextView.minFieldHeight(scale), ComposerTextView.lineHeight(scale) * 2)
            // Degenerate width (first layout pass) never falls below 2 lines.
            XCTAssertGreaterThanOrEqual(ComposerTextView.height(for: "", width: 0, font: font), (line * 2).rounded(.up) - 1)
        }
    }

    /// Every composer starts at the 2-line height (no 1-line initial state
    /// that snaps up after layout).
    func testEveryComposerStartsAtTwoLines() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BetterTeamsUI")
        for rel in ["Conversation/Composer.swift", "Sections/Teams/TeamsInspector.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            XCTAssertTrue(src.contains("fieldHeight: CGFloat = ComposerTextView.minFieldHeight(1)"), "\(rel) initial height")
        }
    }

    /// No reserved band under the field: the status line has no fixed
    /// height and the bottom inset stays small.
    func testNoTrailingGapUnderField() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BetterTeamsUI/Conversation/Composer.swift")
        let src = try String(contentsOf: root, encoding: .utf8)
        guard let a = src.range(of: "private var statusLine: some View {"),
              let b = src.range(of: "// MARK: popovers", range: a.upperBound ..< src.endIndex)
        else { return XCTFail("statusLine not found") }
        let body = String(src[a.upperBound ..< b.lowerBound])
        XCTAssertFalse(body.contains(".frame(height:"), "status line must not reserve a fixed-height band")
        XCTAssertFalse(body.contains(".frame(minHeight:"), "status line must not reserve a minimum band")
        XCTAssertTrue(src.contains(".padding(.bottom, 10)"), "composer bottom inset changed: re-check no blank band under the field")
    }
}
