// P2aConversationTests.swift — P2a pure-logic tests (UI-SPEC §6.2.1,
// §6.2.2, §11.1): Return-key policy (IME-safe), @-mention trigger, row
// state (receipt target, quotes, send state, extra revision), link
// preview choice, body segmentation, composer height clamp.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class P2aConversationTests: XCTestCase {
    private func msg(_ id: String, own: Bool = false, content: String = "hi", raw: String? = nil,
                     replyTo: String? = nil, deleted: Bool = false) -> ChatMessage {
        ChatMessage(id: id, sender: own ? "Me" : "Megan Harper", timestamp: "2026-09-27T09:00:00Z",
                    content: content, isOwn: own, raw: raw, reply_to: replyTo, deleted: deleted)
    }

    // MARK: composer keys

    func testReturnPolicy() {
        XCTAssertEqual(ComposerKeyPolicy.action(shift: false, markedText: false), .send)
        XCTAssertEqual(ComposerKeyPolicy.action(shift: true, markedText: false), .newline)
        // IME: marked text always goes to the input method first.
        XCTAssertEqual(ComposerKeyPolicy.action(shift: false, markedText: true), .passThrough)
        XCTAssertEqual(ComposerKeyPolicy.action(shift: true, markedText: true), .passThrough)
        // Swapped setting: Return = newline, ⇧Return = send.
        XCTAssertEqual(ComposerKeyPolicy.action(shift: false, markedText: false, returnSends: false), .newline)
        XCTAssertEqual(ComposerKeyPolicy.action(shift: true, markedText: false, returnSends: false), .send)
    }

    func testMentionTrigger() {
        XCTAssertEqual(MentionTrigger.query(in: "@"), "")
        XCTAssertEqual(MentionTrigger.query(in: "thanks @Me"), "Me")
        XCTAssertEqual(MentionTrigger.query(in: "thanks @Megan Ha"), "Megan Ha")
        XCTAssertNil(MentionTrigger.query(in: "mail me@example.com"))
        XCTAssertNil(MentionTrigger.query(in: "no mention"))
        XCTAssertNil(MentionTrigger.query(in: "@Tom\nnext line"))
        XCTAssertEqual(MentionTrigger.complete("thanks @Meg", with: "Megan Harper"), "thanks @Megan Harper ")
        XCTAssertEqual(MentionTrigger.complete("", with: "Tom Becker"), "@Tom Becker ")
    }

    func testComposerHeightClampsToOneThroughEightLines() {
        let font = ComposerTextView.font(1.0)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let one = ComposerTextView.height(for: "", width: 300, font: font)
        XCTAssertEqual(one, line.rounded(.up), accuracy: 1)
        let two = ComposerTextView.height(for: "a\nb", width: 300, font: font)
        XCTAssertGreaterThan(two, one)
        let many = ComposerTextView.height(for: String(repeating: "x\n", count: 30), width: 300, font: font)
        XCTAssertEqual(many, (line * 8).rounded(.up), accuracy: 1)
        // A trailing newline already counts as a line (caret on it).
        XCTAssertGreaterThan(ComposerTextView.height(for: "a\n", width: 300, font: font), one)
    }

    // MARK: row state

    func testSendState() {
        XCTAssertEqual(SendState.of(msg("pending-1", own: true), failed: []), .sending)
        XCTAssertEqual(SendState.of(msg("pending-1", own: true), failed: ["pending-1"]), .failed)
        XCTAssertEqual(SendState.of(msg("m1", own: true), failed: []), .none)
        XCTAssertEqual(SendState.of(msg("pending-x"), failed: []), .none)
    }

    func testReceiptSitsOnLastOwnMessageOnly() {
        let sent = [msg("a", own: true), msg("b"), msg("c", own: true), msg("d", own: true)]
        XCTAssertEqual(TimelineRowState.receiptTarget(sent, failed: []), "d")
        // The newest own message failed or is still sending: no receipt
        // moves back onto an older message.
        XCTAssertNil(TimelineRowState.receiptTarget(sent, failed: ["d"]))
        XCTAssertNil(TimelineRowState.receiptTarget(sent + [msg("pending-e", own: true)], failed: []))
        XCTAssertNil(TimelineRowState.receiptTarget([msg("x")], failed: []))
    }

    func testQuoteFromHistoryThenRawThenStub() {
        let parent = msg("p1", content: "Showcase thread is open")
        let reply = msg("r1", raw: #"<quote author="Megan Harper" guid="p1">Showcase &amp; more</quote><p>In.</p>"#,
                        replyTo: "p1")
        let inHistory = TimelineRowState.quote(for: reply, in: ["p1": parent])
        XCTAssertEqual(inHistory, QuoteData(sender: "Megan Harper", preview: "Showcase thread is open", jumpID: "p1"))
        let evicted = TimelineRowState.quote(for: reply, in: [:])
        XCTAssertEqual(evicted, QuoteData(sender: "Megan Harper", preview: "Showcase & more", jumpID: nil))
        XCTAssertEqual(TimelineRowState.quote(for: msg("r2", replyTo: "gone"), in: [:])?.jumpID, nil)
        XCTAssertNil(TimelineRowState.quote(for: msg("plain"), in: [:]))
    }

    func testExtraRevisionTracksRowState() {
        let base = MessageRowData.extraRevision(send: .none, receipt: .none, translation: nil, pinned: false, saved: false)
        XCTAssertEqual(base, MessageRowData.extraRevision(send: .none, receipt: .none, translation: nil,
                                                          pinned: false, saved: false))
        XCTAssertNotEqual(base, MessageRowData.extraRevision(send: .sending, receipt: .none, translation: nil,
                                                             pinned: false, saved: false))
        XCTAssertNotEqual(base, MessageRowData.extraRevision(send: .none, receipt: .seen, translation: nil,
                                                             pinned: false, saved: false))
        XCTAssertNotEqual(base, MessageRowData.extraRevision(send: .none, receipt: .none, translation: nil,
                                                             pinned: true, saved: false))
        XCTAssertNotEqual(TimelineRowState.combine(1, base), TimelineRowState.combine(2, base))
    }

    func testLinkPreviewOnlyForPlainHTTPSLinks() {
        XCTAssertEqual(LinkPreviewRules.previewURL(for: msg("l", content: "see https://example.com/deploys/42")),
                       "https://example.com/deploys/42")
        XCTAssertNil(LinkPreviewRules.previewURL(for: msg("n", content: "no link here")))
        XCTAssertNil(LinkPreviewRules.previewURL(for: msg("h", content: "see http://example.com/x")))
        XCTAssertNil(LinkPreviewRules.previewURL(for: msg("i", content: "pic https://example.com/a",
                                                         raw: #"<p>pic</p><img src="demo://photo-1">"#)))
    }

    func testBodySegmentsSplitCodeBlocksAndTintMentions() {
        let m = ChatMessage(id: "c", sender: "Tom Becker", timestamp: "2026-09-27T09:00:00Z",
                            content: "Usage: run `x` then\nlet x = render(msg)",
                            raw: "<p>Usage: run `x` then</p><pre>let x = render(msg)</pre>")
        let segs = MessageRowView.segments(MessageRender.attributedBody(for: m), scale: 1)
        XCTAssertEqual(segs.map(\.isBlock), [false, true])
        XCTAssertEqual(String(segs[1].text.characters), "let x = render(msg)")

        let mention = ChatMessage(id: "m", sender: "Megan Harper", timestamp: "2026-09-27T09:00:00Z",
                                  content: "Nice. @Me please check",
                                  raw: "<p>Nice. <at id=\"8:me\">@Me</at> please check</p>")
        let body = MessageRowView.segments(MessageRender.attributedBody(for: mention, highlighting: "Me"), scale: 1)
        // A mention naming you takes the darker own-mention ink on its wash (contrast).
        let tinted = body.flatMap { $0.text.runs.filter { $0.swiftUI.foregroundColor == Palette.ownMentionText } }
        XCTAssertFalse(tinted.isEmpty, "mention runs carry the palette tint")
        XCTAssertTrue(body.flatMap { $0.text.runs }.contains { $0.swiftUI.backgroundColor == Palette.ownMentionBackground })
    }

    func testEvidencePopoverNames() {
        XCTAssertEqual(ComposerPopover(evidenceName: "mention", lastMessageID: nil), .mention)
        XCTAssertEqual(ComposerPopover(evidenceName: "reaction", lastMessageID: "m9"), .reaction(messageID: "m9"))
        XCTAssertNil(ComposerPopover(evidenceName: "reaction", lastMessageID: nil))
        XCTAssertNil(ComposerPopover(evidenceName: "bogus", lastMessageID: "m9"))
    }
}
