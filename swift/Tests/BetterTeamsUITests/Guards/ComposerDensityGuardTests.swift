// ComposerDensityGuardTests.swift — COMPOSER-DENSITY: the input-row
// accessory clusters are compact VERTICAL strips so the text field keeps
// usable width at narrow windows. The format bar ABOVE the row is out of
// scope (full-width rows don't squeeze the input) and stays horizontal.
import XCTest

@testable import BetterTeamsUI

@MainActor
final class ComposerDensityGuardTests: XCTestCase {
    private var composer: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/Conversation/Composer.swift")
        // swiftlint:disable:next force_try
        return try! String(contentsOf: root, encoding: .utf8)
    }

    /// Section slice: from the first marker to the next `private var` /
    /// `private func` / `@ViewBuilder` / `// MARK:` boundary after it.
    private func section(_ src: String, from marker: String) -> String {
        guard let start = src.range(of: marker)?.upperBound else { return "" }
        let rest = src[start...]
        let bounds = ["\n    private var ", "\n    private func ", "\n    @ViewBuilder",
                      "\n    /// ", "\n// MARK:"]
        var end = rest.endIndex
        for b in bounds {
            if let r = rest.range(of: b), r.lowerBound < end { end = r.lowerBound }
        }
        return String(rest[..<end])
    }

    /// (a) The left cluster (style/importance/attach/emoji/GIF/templates)
    /// is ONE compact vertical strip, not a horizontal row.
    func testLeadingClusterIsVerticalStrip() {
        let body = section(composer, from: "private var leadingStrip")
        XCTAssertFalse(body.isEmpty, "leadingButtons must exist")
        XCTAssertTrue(body.contains("VStack"), "left cluster must stack vertically")
        XCTAssertFalse(body.contains("HStack"), "left cluster must not lay out horizontally")
    }

    /// Same buttons, same order, same actions in the strip (geometry only).
    func testLeadingStripKeepsButtonsAndOrder() {
        let body = section(composer, from: "private var leadingStrip")
        let marks = ["textformat.size", "importanceMenu", "\"paperclip\"",
                     "\"face.smiling\"", "\"photo.on.rectangle.angled\"", "TemplatesMenu"]
        var last = -1
        for m in marks {
            guard let r = body.range(of: m) else {
                // GIF + templates are conditional; the rest must be present.
                XCTAssertTrue(m.contains("photo") || m.contains("Templates"),
                              "missing leading control \(m)")
                continue
            }
            let i = body.distance(from: body.startIndex, to: r.lowerBound)
            XCTAssertGreaterThan(i, last, "\(m) out of order in the strip")
            last = i
        }
    }

    /// (b) Send + chevron is a vertical pair: a send button over a
    /// chevron menu (same two actions, same order — send first).
    func testSendAndChevronAreVerticalPair() {
        let body = section(composer, from: "private var sendColumn")
        XCTAssertFalse(body.isEmpty, "sendColumn must exist")
        XCTAssertTrue(body.contains("VStack"), "send + chevron must stack vertically")
        XCTAssertTrue(body.contains("Button(action: submit)"), "send button keeps the submit action")
        XCTAssertTrue(body.contains("Menu {"), "chevron keeps the Send Now / Send Later menu")
        XCTAssertTrue(body.contains("Send Now") && body.contains("Send Later"),
                      "menu keeps both send actions")
        let send = body.range(of: "Button(action: submit)")?.lowerBound
        let menu = body.range(of: "Menu {")?.lowerBound
        XCTAssertNotNil(send)
        XCTAssertNotNil(menu)
        if let s = send, let m = menu {
            XCTAssertLessThan(body.distance(from: body.startIndex, to: s),
                              body.distance(from: body.startIndex, to: m),
                              "send sits above the chevron")
        }
    }

    /// (c) The field keeps a pinned minimum usable width at narrow windows.
    func testFieldKeepsMinimumUsableWidth() {
        XCTAssertTrue(composer.contains("static let minFieldWidth: CGFloat = 140"),
                      "principled floor: ~20 avg glyphs @13pt body, ~6x the 24pt target")
        let body = section(composer, from: "private var field:")
        XCTAssertTrue(body.contains(".frame(minWidth:"), "field pins the floor")
        XCTAssertTrue(composer.contains("field\n                    .layoutPriority(1)"),
                      "field wins the row's flexible space")
    }

    /// (d) Every icon button in the row keeps a VoiceOver label.
    func testEveryRowIconKeepsVoiceOverLabel() {
        for label in ["Hide Formatting", "Show Formatting", "Message importance",
                      "Attach Files", "Emoji & Symbols", "GIF", "Insert Template",
                      "Send", "Send options"] {
            XCTAssertTrue(composer.contains(label), "missing VoiceOver label: \(label)")
        }
    }

    /// OUT-OF-SCOPE guard: the format bar above the row stays a full-width
    /// horizontal row (it never squeezed the input).
    func testFormatBarStaysHorizontal() {
        let body = section(composer, from: "private var formatBar")
        XCTAssertTrue(body.contains("HStack"), "format bar stays a horizontal row")
    }

    /// Pinned owner spec untouched: 2-line field, no band under it.
    func testTwoLineSpecUntouched() {
        XCTAssertTrue(composer.contains("minFieldHeight(1)"), "initial height stays 2 lines")
        XCTAssertTrue(composer.contains(".padding(.bottom, 10)"), "bottom inset unchanged")
    }
}
