// DraftBodyText.swift — DRAFTS: unsent draft bodies render through the
// message-list WYSIWYG pipeline, never a fork.
//
// Both draft surfaces (the conversation's scheduled queue and the Settings
// Chats pane list) used to show raw composer markers (`**bold**`). They now
// share this seam: `MessageRender.attributedBody` (raw is nil — drafts carry
// no server HTML) mapped to fonts by `MessageRowView.styled`, exactly like a
// bubble. Marker stripping, emphasis, code, links, and mentions match the
// timeline; list line-prefixes pass through literally, as in bubbles.
import OstMacCore
import SwiftUI

/// Formatted draft body as one styled string (message parity). Pure, so
/// guards pin it without hosting a window.
enum DraftBody {
    static func styled(_ text: String, scale: Double) -> AttributedString {
        MessageRowView.styled(MessageRender.attributedBody(text: text, raw: nil), scale: scale)
    }
}

/// Formatted draft body text for single-line queue rows.
struct DraftBodyText: View {
    let text: String
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        Text(DraftBody.styled(text, scale: scale))
    }
}
