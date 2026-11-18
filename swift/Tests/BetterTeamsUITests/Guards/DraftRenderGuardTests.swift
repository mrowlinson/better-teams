// Guard: DRAFTS — unsent draft bodies render WYSIWYG through the
// message-list pipeline, never raw markers and never a forked renderer.
//
// Surfaces: the conversation scheduled queue (`DraftBodyText`) and the
// Settings ▸ Chats scheduled list (`DraftBody.styled`). Both delegate to
// `MessageRender.attributedBody` + `MessageRowView.styled`. The composer
// field itself stays plain text (ComposerOptionsGuardTests pins that).
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class DraftRenderGuardTests: XCTestCase {
    private var uiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: uiDir.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The scheduled queue renders drafts through the shared seam, not a
    /// bare Text (raw `**` markers must never show).
    func testScheduledQueueUsesDraftBody() throws {
        let sheets = try source("Conversation/ConversationSheets.swift")
        XCTAssertTrue(sheets.contains("DraftBodyText(text: item.text)"), "queue uses DraftBodyText")
        XCTAssertFalse(sheets.contains("Text(item.text)"), "no raw draft text in queue")
    }

    /// Settings ▸ Chats renders scheduled drafts through the same seam.
    func testChatsPaneUsesDraftBody() throws {
        let pane = try source("Settings/ChatsPane.swift")
        XCTAssertTrue(pane.contains("DraftBody.styled(item.text"), "pane uses DraftBody.styled")
        XCTAssertFalse(pane.contains("\\(item.text)"), "no raw draft interpolation in pane")
    }

    /// The seam delegates to the message renderer (reuse, not a fork).
    func testDraftBodyDelegatesToMessageRenderer() throws {
        let seam = try source("Timeline/DraftBodyText.swift")
        XCTAssertTrue(seam.contains("MessageRender.attributedBody(text: text, raw: nil)"),
                      "drafts go through attributedBody with raw nil")
        XCTAssertTrue(seam.contains("MessageRowView.styled"), "same SwiftUI font mapping as bubbles")
    }

    /// Bold/italic markers vanish and tag emphasis (message parity).
    func testDraftBodyStripsEmphasisMarkers() {
        let body = DraftBody.styled("**Budget** approved, *see notes*", scale: 1.0)
        let plain = String(body.characters)
        XCTAssertEqual(plain, "Budget approved, see notes")
        var kinds: [EmphKind] = []
        for run in body.runs {
            if let k = run[MessageTextAttributes.EmphAttribute.self] { kinds.append(k) }
        }
        XCTAssertEqual(kinds, [.bold, .italic])
    }

    /// Bare URLs linkify in drafts exactly as in bubbles.
    func testDraftBodyLinkifiesURLs() {
        let body = DraftBody.styled("see https://x.example/list now", scale: 1.0)
        var linked = 0
        for run in body.runs {
            if run.link != nil { linked += 1 }
        }
        XCTAssertEqual(linked, 1)
    }

    /// Inline code keeps mono tagging without backticks.
    func testDraftBodyTagsInlineCode() {
        let body = DraftBody.styled("run `deploy.sh` at 10", scale: 1.0)
        XCTAssertEqual(String(body.characters), "run deploy.sh at 10")
        var coded = 0
        for run in body.runs {
            if run[MessageTextAttributes.CodeRoleAttribute.self] == .inline { coded += 1 }
        }
        XCTAssertEqual(coded, 1)
    }

    /// The evidence seed is demo-gated twice (harness runs demo-only;
    /// seed writes the demo store), route-gated (`drafts=1`), and opens
    /// the sheet only for `sheet=scheduled` — never a live behavior.
    func testEvidenceSeedStaysDemoGated() throws {
        let harness = try source("Evidence/EvidenceHarness.swift")
        XCTAssertTrue(harness.contains("if query?[\"drafts\"] == \"1\" { seedDrafts(wc) }"),
                      "seed runs only for drafts=1 routes")
        XCTAssertTrue(harness.contains("guard services.isDemo"), "seed requires demo services")
        XCTAssertFalse(harness.contains("showScheduledSheet"),
                      "sheet opens via the generic ?sheet= route, never a duplicate presenter")
        XCTAssertTrue(harness.contains("**Budget**"), "seed carries markers (WYSIWYG proof)")
    }

    /// List prefixes pass through literally — pinned parity with bubbles
    /// (the message renderer never reflows lists; drafts must not fork one).
    func testDraftBodyKeepsListParity() {
        let draft = DraftBody.styled("- alpha\n- beta", scale: 1.0)
        let bubble = MessageRowView.styled(
            MessageRender.attributedBody(text: "- alpha\n- beta", raw: nil), scale: 1.0)
        XCTAssertEqual(String(draft.characters), String(bubble.characters))
        XCTAssertTrue(String(draft.characters).hasPrefix("- alpha"))
    }
}
