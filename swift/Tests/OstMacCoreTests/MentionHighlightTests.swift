// MentionHighlightTests.swift — om-mention-highlight: timeline bold for
// live `<span itemtype="…Mention">` shapes (demo `<at>` covered too).
import XCTest

@testable import OstMacCore

@MainActor
final class MentionHighlightTests: XCTestCase {
    static func bubble(content: String, raw: String?) -> ChatMessage {
        ChatMessage(
            id: "m", sender: "A", timestamp: "2026-09-24T10:00:00Z",
            content: content, raw: raw)
    }

    // MARK: - mining

    func testSpanMining() {
        let live = #"Hey <span itemscope="" itemtype="http://schema.skype.com/Mention" itemid="0">Rowlinson, Michael</span> hi"#
        XCTAssertEqual(MessageRender.mentions(fromRaw: live), ["Rowlinson, Michael"])
        // Split-name spans (one person, two spans) mine both parts.
        let split = #"<span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="0">Rowlinson,</span> <span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="1">Michael</span> x"#
        XCTAssertEqual(MessageRender.mentions(fromRaw: split), ["Rowlinson,", "Michael"])
        // `<at>` still mines; non-mention spans never do.
        XCTAssertEqual(
            MessageRender.mentions(fromRaw: #"<p>Hi <at id="8:t">@Tom Becker</at></p>"#),
            ["@Tom Becker"])
        XCTAssertEqual(MessageRender.mentions(fromRaw: "<p>plain <b>bold</b></p>"), [])
        XCTAssertEqual(MessageRender.mentions(fromRaw: nil), [])
    }

    // MARK: - bubble bold

    /// Live span shape (no @ anywhere) bolds the mined name.
    func testAttributedBodyBoldsLiveSpan() {
        let m = Self.bubble(
            content: "Hey Rowlinson, Michael Mario doesn't come in until 15:00.",
            raw: #"Hey <span itemscope="" itemtype="http://schema.skype.com/Mention" itemid="0">Rowlinson, Michael</span> Mario doesn’t come in until 15:00."#)
        let a = MessageRender.attributedBody(for: m)
        let styled = a.runs.filter { $0.isStyledSpan }
        XCTAssertEqual(styled.count, 1)
        guard styled.count == 1 else { return }
        let want = Range(m.content.range(of: "Rowlinson, Michael")!, in: a)!
        XCTAssertEqual(styled[0].range, want)
    }

    /// Split spans bold each part (no @ fallback involved).
    func testAttributedBodyBoldsSplitSpan() {
        let m = Self.bubble(
            content: "Rowlinson, Michael STOP ASSIGNING ME TICKETS",
            raw: #"<span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="0">Rowlinson,</span> <span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="1">Michael</span>STOP ASSIGNING ME TICKETS"#)
        let a = MessageRender.attributedBody(for: m)
        let styled = a.runs.filter { $0.isStyledSpan }
        XCTAssertEqual(styled.count, 2)
    }

    /// Demo `<at>` shape keeps its exact bold range.
    func testAttributedBodyBoldsDemoAt() {
        let m = Self.bubble(
            content: "Kicking off the richness pass. @Tom Becker can you own code blocks?",
            raw: "<p>Kicking off the richness pass. <at id=\"8:t\">@Tom Becker</at> can you own code blocks?</p>")
        let a = MessageRender.attributedBody(for: m)
        let styled = a.runs.filter { $0.isStyledSpan }
        XCTAssertEqual(styled.count, 1)
        guard styled.count == 1 else { return }
        let want = Range(m.content.range(of: "@Tom Becker")!, in: a)!
        XCTAssertEqual(styled[0].range, want)
    }

    /// Owner wash fires for a live span naming the owner.
    func testAttributedBodyWashesLiveSpanMine() {
        let m = Self.bubble(
            content: "Hey Rowlinson, Michael please double-check.",
            raw: #"Hey <span itemtype="http://schema.skype.com/Mention" itemscope="" itemid="0">Rowlinson, Michael</span> please double-check."#)
        let a = MessageRender.attributedBody(for: m, highlighting: "Rowlinson, Michael")
        XCTAssertEqual(a.runs.filter { $0.mention == .own }.count, 1)
        // Someone else's name: bold, no wash.
        let other = MessageRender.attributedBody(for: m, highlighting: "Bo")
        XCTAssertTrue(other.runs.filter { $0.mention == .own }.isEmpty)
        XCTAssertEqual(other.runs.filter { $0.isStyledSpan }.count, 1)
    }
}
