// CopilotViews.swift — Copilot chat pane (UI-SPEC §6.7, R18 pane
// states). Messages.app-shaped: user prompts right, assistant
// answers left with markdown text, source links and suggestion
// chips that send. The streaming bubble's text is replaced per poll
// (the hub stream is cumulative), never appended.
import OstMacCore
import SwiftUI

// MARK: states

/// What the chat pane shows. Titles state the condition (R18).
enum CopilotPaneState: Equatable {
    case loading
    case error(title: String, message: String)
    case chat

    static let notSetUpTitle = "Copilot Isn't Set Up"
    static let notSetUpMessage = "Copilot chat appears here once the app finishes signing in."
    static let errorTitle = "Couldn't Reach Copilot"

    static func resolve(forced: ForcedPaneState?) -> CopilotPaneState {
        switch forced {
        case .loading: return .loading
        case .empty: return .chat
        case .error: return .error(title: errorTitle, message: "Something went wrong.")
        case nil: return .chat
        }
    }
}

// MARK: pane

/// The one live Copilot conversation.
struct CopilotChatPane: View {
    @ObservedObject var store: CopilotStore
    var forced: ForcedPaneState? = nil
    @State private var draft = ""

    var body: some View {
        switch CopilotPaneState.resolve(forced: forced) {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let title, let message):
            EmptyPane(title, systemImage: NativeAppID.copilot.symbol, message: message)
        case .chat:
            VStack(spacing: 0) {
                licenseBanner
                errorBanner
                if store.messages.isEmpty, !store.streaming {
                    emptyChat
                } else {
                    transcript
                }
                Divider()
                inputBar
            }
        }
    }

    // MARK: banners

    @ViewBuilder
    private var licenseBanner: some View {
        switch store.license {
        case .licensed(_, let note):
            if let note, !note.isEmpty {
                banner(text: note, systemImage: "info.circle")
            }
        case .unlicensed(let reason):
            banner(text: reason, systemImage: "exclamationmark.triangle") {
                Button("Check Again") { store.recheckLicense() }
                    .buttonStyle(.link)
            }
        case .unknown, .checking:
            EmptyView()
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if case .error(let message) = store.state {
            banner(text: message, systemImage: "exclamationmark.triangle")
        }
    }

    private func banner(text: String, systemImage: String) -> some View {
        bannerRow(text: text, systemImage: systemImage) { EmptyView() }
    }

    private func banner(text: String, systemImage: String, @ViewBuilder extra: () -> some View) -> some View {
        bannerRow(text: text, systemImage: systemImage, extra: extra)
    }

    private func bannerRow(text: String, systemImage: String, @ViewBuilder extra: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                extra()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
        }
    }

    // MARK: transcript

    /// Tier-honest empty caption: only the paid seat grounds in
    /// work data (free tiers answer from the web).
    private var emptyCaption: String {
        switch store.license {
        case .licensed where store.license.workGrounded:
            "Answers from your chats, meetings and files — plus the web."
        case .unlicensed:
            "Copilot answers here once it's available for this account."
        case .licensed, .unknown, .checking:
            "Answers from the web — work grounding needs a Copilot license."
        }
    }

    private var emptyChat: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: NativeAppID.copilot.symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Ask Copilot")
                .font(.title2)
            Text(emptyCaption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.messages) { message in
                        CopilotBubble(message: message) { suggestion in
                            store.send(suggestion)
                        }
                    }
                    if store.streaming, store.messages.last?.text.isEmpty == true {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(store.progress ?? "Thinking…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.vertical, 12)
            }
            .onChange(of: store.messages.last?.text ?? "") { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: store.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask Copilot…", text: $draft, onCommit: sendDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(!store.inputEnabled)
            if store.streaming {
                Button { store.stop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .disabled(!store.inputEnabled || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        store.send(text)
    }
}

// MARK: bubbles

/// One chat bubble: user right, assistant left.
private struct CopilotBubble: View {
    let message: CopilotMessage
    let sendSuggestion: (String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 12)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: NativeAppID.copilot.symbol)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text(CopilotMarkdown.attributed(message.text.isEmpty ? " " : message.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                if !message.attributions.isEmpty {
                    sources(message.attributions)
                }
                if !message.suggestions.isEmpty, !message.isStreaming {
                    chips(message.suggestions)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sources(_ attributions: [CopilotAttribution]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Sources")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(attributions, id: \.self) { a in
                if let url = URL(string: a.url), url.scheme == "http" || url.scheme == "https" {
                    Link(a.title.isEmpty ? a.url : a.title, destination: url)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
    }

    private func chips(_ suggestions: [String]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(suggestions, id: \.self) { s in
                Button(s) { sendSuggestion(s) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
    }
}

/// Left-aligned wrapping row for suggestion chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
