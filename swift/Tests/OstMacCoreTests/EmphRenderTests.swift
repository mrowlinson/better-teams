// EmphRenderTests.swift — COMPOSER-A: composer markdown renders in
// bubbles (markers stripped, emphasis tagged), code spans stay
// literal, and syntax highlight keeps working through the new path.
import XCTest

@testable import OstMacCore

@MainActor
final class EmphRenderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MessageRender.resetRenderCaches()
    }

    private func emphKinds(in text: String, raw: String? = nil)
        -> [(String, EmphKind)]
    {
        let body = MessageRender.attributedBody(text: text, raw: raw)
        var out: [(String, EmphKind)] = []
        for run in body.runs {
            if let k = run[MessageTextAttributes.EmphAttribute.self] {
                out.append((String(body[run.range].characters), k))
            }
        }
        return out
    }

    // MARK: - Parser

    func testStripInlineMarkupBasic() {
        let r = MessageRender.stripInlineMarkup("**Budget** approved, *see notes*")
        XCTAssertEqual(r.clean, "Budget approved, see notes")
        XCTAssertEqual(r.code.count, 0)
        XCTAssertEqual(r.emph.count, 2)
        XCTAssertEqual(String(r.clean[r.emph[0].range]), "Budget")
        XCTAssertEqual(r.emph[0].kind, .bold)
        XCTAssertEqual(String(r.clean[r.emph[1].range]), "see notes")
        XCTAssertEqual(r.emph[1].kind, .italic)
    }

    func testStripMarksStrictEdges() {
        XCTAssertEqual(MessageRender.stripInlineMarkup("** not **").clean, "** not **")
        XCTAssertEqual(MessageRender.stripInlineMarkup("**a\nb**").clean, "**a\nb**")
        XCTAssertEqual(MessageRender.stripInlineMarkup("a * b").clean, "a * b")
        XCTAssertEqual(MessageRender.stripInlineMarkup("2*3*4").emph.count, 1)
    }

    func testStripSkipsTickSpans() {
        let r = MessageRender.stripInlineMarkup("run `**x**` now")
        XCTAssertEqual(r.clean, "run **x** now")
        XCTAssertEqual(r.emph.count, 0)
        XCTAssertEqual(r.code.count, 1)
        XCTAssertEqual(String(r.clean[r.code[0]]), "**x**")
    }

    func testStripSkipsPreRanges() {
        let raw: String? = "<pre>a *b* c</pre>"
        let text = "a *b* c"
        let pre = MessageRender.codeBlocks(fromRaw: raw).flatMap { MessageRender.ranges(of: $0, in: text) }
        let r = MessageRender.stripInlineMarkup(text, preRanges: pre)
        XCTAssertEqual(r.emph.count, 0)
        XCTAssertEqual(r.clean, text)
    }

    func testStripBoldBeatsItalic() {
        let r = MessageRender.stripInlineMarkup("***x***")
        XCTAssertEqual(r.clean, "*x*")
        XCTAssertEqual(r.emph.count, 1)
        XCTAssertEqual(r.emph[0].kind, .bold)
    }

    // MARK: - Bubble render

    func testAttributedBodyTagsEmphasis() {
        let kinds = emphKinds(in: "**Budget** ok *n* __s__ ~~o~~")
        XCTAssertEqual(kinds.map(\.0), ["Budget", "n", "s", "o"])
        XCTAssertEqual(kinds.map(\.1), [.bold, .italic, .underline, .strike])
    }

    func testAttributedBodyKeepsCodeLiteral() {
        let body = MessageRender.attributedBody(text: "run `**x**` now", raw: nil)
        XCTAssertEqual(String(body.characters), "run **x** now")
        XCTAssertTrue(emphKinds(in: "run `**x**` now").isEmpty)
    }

    func testAttributedBodyMentionAndLinksUnaffected() {
        let body = MessageRender.attributedBody(text: "**hi** https://x.example", raw: nil)
        XCTAssertEqual(String(body.characters), "hi https://x.example")
        let kinds = emphKinds(in: "**hi** https://x.example")
        XCTAssertEqual(kinds.count, 1)
        XCTAssertEqual(kinds[0].1, .bold)
    }

    func testHighlightStillWiredThroughNewPath() {
        // Fenced code keeps syntax buckets; prose emphasis works beside it.
        let text = "**note**\n```swift\nlet x = 1\n```"
        let body = MessageRender.attributedBody(text: text, raw: nil)
        XCTAssertEqual(String(body.characters), "note\nlet x = 1")
        var tokens = 0
        var bold = 0
        for run in body.runs {
            if run[MessageTextAttributes.CodeTokenAttribute.self] != nil { tokens += 1 }
            if run[MessageTextAttributes.EmphAttribute.self] == .bold { bold += 1 }
        }
        XCTAssertGreaterThan(tokens, 0, "highlight.js buckets must survive the new strip path")
        XCTAssertEqual(bold, 1)
    }
}
