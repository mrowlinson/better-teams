// ComposerFormatTests.swift — COMPOSER-A: format bar transforms,
// ⌘B/I/U shortcut map, and the emphasis → font/style mapping.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ComposerFormatTests: XCTestCase {
    private func apply(_ action: ComposerFormatAction, _ text: String,
                       _ loc: Int, _ len: Int) -> (String, NSRange)
    {
        ComposerFormat.apply(action, to: text, selection: NSRange(location: loc, length: len))
    }

    // MARK: - Inline toggles

    func testBoldWrapsSelection() {
        let (t, s) = apply(.bold, "hello", 1, 3)
        XCTAssertEqual(t, "h**ell**o")
        XCTAssertEqual(s, NSRange(location: 1, length: 7))
    }

    func testBoldUnwrapsExactlyWrapped() {
        let (t, s) = apply(.bold, "h**ell**o", 1, 7)
        XCTAssertEqual(t, "hello")
        XCTAssertEqual(s, NSRange(location: 1, length: 3))
    }

    func testBoldEmptySelectionInsertsBarePair() {
        let (t, s) = apply(.bold, "hi", 2, 0)
        XCTAssertEqual(t, "hi****")
        XCTAssertEqual(s, NSRange(location: 4, length: 0))
    }

    func testItalicOnBoldNestsInsteadOfCorrupting() {
        // "**hi**" + italic must not unwrap to "*hi*".
        let (t, _) = apply(.italic, "**hi**", 0, 6)
        XCTAssertEqual(t, "***hi***")
    }

    func testBoldWinsTripleAmbiguity() {
        let (t, _) = apply(.bold, "***hi***", 0, 8)
        XCTAssertEqual(t, "*hi*")
    }

    func testUnderlineStrikeCodeRoundTrip() {
        let (u, _) = apply(.underline, "sign", 0, 4)
        XCTAssertEqual(u, "__sign__")
        let (u2, _) = apply(.underline, "__sign__", 0, 8)
        XCTAssertEqual(u2, "sign")
        let (s, _) = apply(.strike, "old", 0, 3)
        XCTAssertEqual(s, "~~old~~")
        let (c, _) = apply(.inlineCode, "run", 0, 3)
        XCTAssertEqual(c, "`run`")
        let (c2, _) = apply(.inlineCode, "`run`", 0, 5)
        XCTAssertEqual(c2, "run")
    }

    // MARK: - Line toggles

    func testBulletToggleAddsAndRemoves() {
        let (t, s) = apply(.bulletList, "a\nb", 0, 3)
        XCTAssertEqual(t, "- a\n- b")
        XCTAssertEqual(s, NSRange(location: 0, length: 7))
        let (u, _) = apply(.bulletList, "- a\n- b", 0, 7)
        XCTAssertEqual(u, "a\nb")
    }

    func testNumberedToggleRenumbersTopDown() {
        let (t, _) = apply(.numberedList, "a\nb\nc", 0, 5)
        XCTAssertEqual(t, "1. a\n2. b\n3. c")
        let (u, _) = apply(.numberedList, "1. a\n2. b\n3. c", 0, 14)
        XCTAssertEqual(u, "a\nb\nc")
    }

    func testQuoteToggle() {
        let (t, _) = apply(.quote, "line", 0, 4)
        XCTAssertEqual(t, "> line")
        let (u, _) = apply(.quote, "> line", 0, 6)
        XCTAssertEqual(u, "line")
    }

    func testPartialPrefixOnlyFillsMissing() {
        let (t, _) = apply(.bulletList, "- a\nb", 0, 5)
        XCTAssertEqual(t, "- a\n- b")
    }

    func testTableInsertsSkeletonOnOwnLines() {
        let (t, s) = apply(.table, "hi", 2, 0)
        XCTAssertEqual(t, "hi\n" + ComposerFormat.tableSkeleton)
        XCTAssertEqual(s, NSRange(location: 5, length: 0))
        // Caret lands inside the first cell.
        XCTAssertEqual((t as NSString).substring(with: NSRange(location: 3, length: 2)), "| ")
    }

    // MARK: - Shortcuts

    func testShortcutMap() {
        XCTAssertEqual(ComposerFormat.shortcutAction(keyCode: 11, modifiers: .command), .bold)
        XCTAssertEqual(ComposerFormat.shortcutAction(keyCode: 34, modifiers: .command), .italic)
        XCTAssertEqual(ComposerFormat.shortcutAction(keyCode: 32, modifiers: .command), .underline)
        XCTAssertNil(ComposerFormat.shortcutAction(keyCode: 11, modifiers: [.command, .shift]))
        XCTAssertNil(ComposerFormat.shortcutAction(keyCode: 11, modifiers: [.command, .option]))
        XCTAssertNil(ComposerFormat.shortcutAction(keyCode: 36, modifiers: .command))
        XCTAssertNil(ComposerFormat.shortcutAction(keyCode: 11, modifiers: []))
    }

    // MARK: - Timeline mapping (MessageRowView.segments)

    func testSegmentsUnderlineAndStrikeMapToAppKitStyles() {
        for (kind, key) in [(EmphKind.underline, NSAttributedString.Key.underlineStyle),
                            (EmphKind.strike, NSAttributedString.Key.strikethroughStyle)]
        {
            var a = AttributedString("x")
            a[a.startIndex ..< a.endIndex].emph = kind
            let segs = MessageRowView.segments(a, scale: 1.0)
            XCTAssertEqual(segs.count, 1)
            XCTAssertFalse(segs[0].isBlock)
            // Selectable text draws through AppKit attributes: read the
            // NSAttributedString the bubble hands AppKit.
            let ns = NSAttributedString(segs[0].text)
            var range = NSRange(location: 0, length: 0)
            let attrs = ns.attributes(at: 0, effectiveRange: &range)
            XCTAssertEqual(attrs[key] as? Int, NSUnderlineStyle.single.rawValue)
            XCTAssertEqual(range, NSRange(location: 0, length: 1))
        }
    }

    func testSegmentsItalicMapsToItalicFont() {
        var a = AttributedString("x")
        a[a.startIndex ..< a.endIndex].emph = .italic
        let segs = MessageRowView.segments(a, scale: 1.0)
        let ns = NSAttributedString(segs[0].text)
        var range = NSRange(location: 0, length: 0)
        let attrs = ns.attributes(at: 0, effectiveRange: &range)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.italic))
    }
}
