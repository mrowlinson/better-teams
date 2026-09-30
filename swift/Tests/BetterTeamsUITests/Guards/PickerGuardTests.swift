// PickerGuardTests — R5 (REGFIX-B): the emoji picker has a Recent tab,
// categories and arrow-key navigation; the GIF picker has the same arrow
// navigation (built 598ba08 / 0919bb5; GridNavTests deleted with the old
// UI). Drives the pure page model, the grid stepping and the search
// field's real key handling.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class PickerGuardTests: XCTestCase {
    // MARK: emoji tabs

    func testRecentTabShowsTheRecentsRingAndEveryCategoryHasItsOwnTab() {
        let recents = ["\u{1F44D}", "\u{1F389}"]
        let recent = EmojiPage.entries(query: "", tab: EmojiPage.recentsID, recents: recents)
        XCTAssertEqual(recent.map(\.emoji), recents)
        // A fresh user's ring is the seeded top-12, never an empty tab.
        let seeded = EmojiPage.entries(query: "", tab: EmojiPage.recentsID,
                                       recents: ReactionRecents.load(defaults: MemoryDefaults()))
        XCTAssertEqual(seeded.count, ReactionRecents.maxCount)
        XCTAssertGreaterThanOrEqual(ReactionCatalog.categories.count, 4, "categories are the picker's tabs")
        for c in ReactionCatalog.categories {
            XCTAssertEqual(EmojiPage.entries(query: "", tab: c.id, recents: recents).map(\.emoji), c.entries.map(\.emoji), c.id)
            XCTAssertFalse(c.entries.isEmpty)
        }
    }

    func testSearchOverridesTheTab() {
        let hits = EmojiPage.entries(query: "party", tab: EmojiPage.recentsID, recents: ["\u{1F44D}"])
        XCTAssertEqual(hits.map(\.emoji), ReactionCatalog.search("party").map(\.emoji))
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(EmojiPage.entries(query: "zzzzqqq", tab: "faces", recents: []).isEmpty)
    }

    // MARK: arrow navigation

    func testGridNavStepsWithinRowsAndClampsAtEdges() {
        // 8 columns, 20 items: rows of 8, 8, 4.
        func move(_ i: Int, _ dx: Int, _ dy: Int) -> Int { GridNav.move(current: i, dx: dx, dy: dy, columns: 8, count: 20) }
        XCTAssertEqual(move(0, 1, 0), 1)
        XCTAssertEqual(move(7, 1, 0), 7, "right stops at the row end")
        XCTAssertEqual(move(0, -1, 0), 0, "left stops at the row start")
        XCTAssertEqual(move(3, 0, 1), 11)
        XCTAssertEqual(move(11, 0, -1), 3)
        XCTAssertEqual(move(3, 0, -1), 3, "up stops on the first row")
        XCTAssertEqual(move(15, 0, 1), 19, "down onto a short last row clamps to its last item")
        XCTAssertEqual(move(19, 1, 0), 19)
        XCTAssertEqual(GridNav.move(current: 0, dx: 1, dy: 1, columns: 8, count: 0), 0, "empty grid")
        XCTAssertEqual(GridNav.move(current: 5, dx: 0, dy: 1, columns: 0, count: 3), 2, "degenerate columns")
    }

    func testSearchFieldForwardsArrowKeysToTheGrid() {
        var text = ""
        let field = SearchField(text: .init(get: { text }, set: { text = $0 }), onSubmit: nil, onMove: nil)
        let coord = field.makeCoordinator()
        var moves: [[Int]] = []
        coord.onMove = { dx, dy in moves.append([dx, dy]); return true }
        let tv = NSTextView()
        let f = NSSearchField()
        tv.string = ""
        XCTAssertTrue(coord.control(f, textView: tv, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(coord.control(f, textView: tv, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(coord.control(f, textView: tv, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertTrue(coord.control(f, textView: tv, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertEqual(moves, [[0, 1], [0, -1], [1, 0], [-1, 0]])
        // With typed text, Left/Right belong to the caret; Up/Down still navigate.
        tv.string = "par"
        moves = []
        XCTAssertFalse(coord.control(f, textView: tv, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertFalse(coord.control(f, textView: tv, doCommandBy: #selector(NSResponder.moveRight(_:))))
        XCTAssertTrue(coord.control(f, textView: tv, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(moves, [[0, 1]])
    }

    func testPickerGridsUseTheSameColumnsAsTheirNavigation() {
        XCTAssertEqual(ReactionPicker.columns, 8)
        XCTAssertEqual(GIFPicker.columns, 3)
    }
}
