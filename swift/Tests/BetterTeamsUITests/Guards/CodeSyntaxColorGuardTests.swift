// CodeSyntaxColorGuardTests — R2 (REGFIX-B): code in received messages is
// syntax-colored (research #8, built 5428ff2, guard Top10CodeTests
// .testPaletteCoversTokens deleted in da3945d). Behavior, not source text:
// a fenced block goes through the real render + the row's styling and the
// keyword run must come out with the keyword color, in both appearances.
import AppKit
import OstMacCore
import SwiftUI
import XCTest

@testable import BetterTeamsUI

@MainActor
final class CodeSyntaxColorGuardTests: XCTestCase {
    func testPaletteCoversEveryTokenExceptPlain() {
        for tok: CodeHighlight.Token in [.keyword, .string, .comment, .number, .title, .type, .tag] {
            XCTAssertNotNil(Palette.codeTokenNS(tok), "\(tok)")
        }
        XCTAssertNil(Palette.codeTokenNS(.plain))
    }

    func testFencedBlockRendersWithKeywordColorAndMono() throws {
        // Missing engine is a FAILURE (the colors silently vanish), never a skip.
        XCTAssertTrue(CodeHighlight.isAvailable(), "highlight engine not loaded: code blocks would lose their colors")
        guard CodeHighlight.isAvailable() else { return }
        let m = ChatMessage(id: "m1", sender: "A", timestamp: "t",
                            content: "see this\n```swift\nfunc f() {\n    return 1\n}\n```\nneat")
        let segs = MessageRowView.segments(MessageRender.attributedBody(for: m), scale: 1)
        let block = try XCTUnwrap(segs.first { $0.isBlock })
        let keyword = try XCTUnwrap(Palette.codeTokenNS(.keyword))
        let colored = block.text.runs.filter { $0.appKit.foregroundColor == keyword }
        XCTAssertFalse(colored.isEmpty, "no keyword-colored run in a highlighted fenced block")
        XCTAssertTrue(colored.allSatisfy { $0.appKit.font?.isFixedPitch == true }, "code stays monospaced")
        // Prose around the block keeps the default color.
        let prose = try XCTUnwrap(segs.first { !$0.isBlock })
        XCTAssertTrue(prose.text.runs.allSatisfy { $0.appKit.foregroundColor != keyword })
    }

    func testTokenColorsResolveInLightAndDark() throws {
        for tok: CodeHighlight.Token in [.keyword, .string, .comment, .number, .title, .type, .tag] {
            let c = try XCTUnwrap(Palette.codeTokenNS(tok))
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                var comps: CGFloat = -1
                NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                    comps = c.usingColorSpace(.deviceRGB)?.alphaComponent ?? -1
                }
                XCTAssertEqual(comps, 1, accuracy: 0.01, "\(tok) resolves opaque in \(name.rawValue)")
            }
        }
    }
}
