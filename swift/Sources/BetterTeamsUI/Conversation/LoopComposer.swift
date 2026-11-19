// LoopComposer.swift — Loop compose popover (LOOPBUILD lane).
//
// Native popover anchored to the composer's Loop button (§6.2.2):
// component URL + message text, the live-gate status row, a gated
// Send, and the exact E1 request preview (offline, always works).
// One popover at a time (`ComposerPopover.loop`); the draft is
// untouched. No fake controls: Send stays disabled with the gate
// reason until live traffic may go out (or demo mode stages it).
import OstMacCore
import SwiftUI

/// Loop compose (existing component URL + text), pure-hosted in
/// the composer's popover slot.
struct LoopComposer: View {
    let conv: ConversationStore
    @ObservedObject var composer: ComposerModel
    @State private var componentURL: String = ""
    @State private var text: String = ""
    @State private var showPreview = false
    @Environment(\.contentTextScale) private var scale

    private var urlValid: Bool {
        guard let url = URL(string: componentURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil
        else { return false }
        return true
    }

    private var canSend: Bool {
        urlValid && (LoopGate.isLive || conv.isDemo)
    }

    private var gateLine: String {
        switch LoopGate.state {
        case .ready:
            return "Live sync ready."
        case .disabled(let reason):
            return reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loop Component")
                .font(AppFont.headline(scale))
            TextField("Component URL (https)", text: $componentURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Component URL")
            TextField("Message (optional)", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3)
                .accessibilityLabel("Message")
            Text(gateLine)
                .font(AppFont.caption(scale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Sync status")
            DisclosureGroup("Request preview", isExpanded: $showPreview) {
                ScrollView {
                    Text(previewText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .font(AppFont.body(scale))
            HStack {
                Spacer(minLength: 0)
                Button("Send Component") {
                    conv.sendLoop(componentURL: componentURL, text: text)
                    composer.popover = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canSend)
                .accessibilityLabel("Send Component")
            }
        }
        .padding(12)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop Component")
    }

    /// The exact E1 request for the current fields (pure core
    /// shapes — offline, always current). The host slot stays a
    /// placeholder: resolving it needs auth, which preview never
    /// touches.
    private var previewText: String {
        let url = componentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty,
              let shapes = try? RustCore.loopShapes(componentURL: url, text: text),
              let raw = shapes.body_string,
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let body = String(data: pretty, encoding: .utf8)
        else { return url.isEmpty ? "Enter a component URL to preview the request." : "Preview unavailable." }
        let chat = conv.chatID ?? "<chat>"
        return "POST {chatSvc}/v1/users/ME/conversations/\(chat)/messages\nContent-Type: application/json\n\n\(body)"
    }
}
