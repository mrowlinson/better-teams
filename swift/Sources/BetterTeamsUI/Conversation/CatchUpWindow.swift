// CatchUpWindow.swift — Window ▸ Open Catch Up in New Window (AICATCH):
// the cross-conversation catch-up in its own window, to keep open and
// glance at. "Mentions You" first (deterministic flags), then one
// summary per conversation with new messages, newest activity first.
//
// Stable by construction: rows are keyed by conversation, a summary
// being rewritten keeps its old text with a small spinner in its
// header, and status changes only touch the bottom bar. The first-ever
// load shows the shared delayed LoadingPane.
import AppKit
import OstMacCore
import SwiftUI

@MainActor
final class CatchUpWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: CatchUpWindowController?
    /// The shell window whose account the window shows (jumps land there).
    private weak var model: WindowModel?

    static func show(_ m: WindowModel) {
        guard let app = m.app else { return }
        if let c = shared, c.model === m {
            c.showWindow(nil)
            c.window?.makeKeyAndOrderFront(nil)
            return
        }
        shared?.close()
        let c = CatchUpWindowController(model: m, app: app)
        shared = c
        // First open centers; later opens restore the saved frame.
        if UserDefaults.standard.string(forKey: "NSWindow Frame CatchUpWindow") == nil { c.window?.center() }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(model m: WindowModel, app: AppState) {
        model = m
        let root = CatchUpDigestView(digest: app.catchUpDigest, catchUp: app.catchUp,
                                     chatName: { [weak app] in app?.chatNameOrNil(for: $0) }) { [weak m] mention in
            guard let m else { return }
            CatchUpWindowController.jump(mention, in: m)
        }
        let host = Hosting.controller(root, role: .pane, model: m)
        let window = NSWindow(contentViewController: host)
        window.title = "Catch Up"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 420, height: 560))
        window.contentMinSize = NSSize(width: 340, height: 360)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("CatchUpWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) {
        if Self.shared === self { Self.shared = nil }
    }

    /// Mention click: the account window comes forward on Chat and lands
    /// on the message (the search-hit funnel: open, then seek).
    static func jump(_ mention: CatchUpMention, in m: WindowModel) {
        guard let app = m.app else { return }
        m.navigator?.endSearch()
        m.navigator?.select(section: .chat)
        m.navigator?.select(SectionSelection(id: mention.chatID), in: .chat)
        app.jumpToMessage(SearchHit(messageID: mention.messageID, chatID: mention.chatID,
                                    sender: mention.sender, timestamp: mention.timestamp,
                                    preview: mention.preview))
        if let w = NSApp.windows.first(where: { ($0.windowController as? ShellWindowController)?.model === m }) {
            w.makeKeyAndOrderFront(nil)
        }
    }
}

struct CatchUpDigestView: View {
    @ObservedObject var digest: CatchUpDigestStore
    @ObservedObject var catchUp: CatchUpStore
    /// Live conversation name: a thread ingested before the chat list
    /// loaded carries no name, and a rename shows up here.
    let chatName: (String) -> String?
    let jump: (CatchUpMention) -> Void

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if catchUp.mode != .off { statusBar }
            }
    }

    @ViewBuilder private var content: some View {
        if catchUp.mode == .off {
            EmptyPane("Catch Up Is Off", systemImage: "sparkles", message: CatchUpError.off.message)
        } else if digest.entries.isEmpty, digest.mentions.isEmpty, digest.working == nil || digest.streamingText == nil {
            if digest.working != nil, !digest.hasRunOnce {
                LoadingPane("Catching up\u{2026}", rows: false)
            } else {
                EmptyPane("You\u{2019}re All Caught Up", systemImage: "checkmark.circle",
                          message: "New messages are summarized here.")
            }
        } else {
            list
        }
    }

    private var list: some View {
        Form {
            Section("Mentions You") {
                if digest.mentions.isEmpty {
                    Text("No one has mentioned you.").foregroundStyle(.secondary)
                } else {
                    ForEach(digest.mentions) { m in
                        CatchUpMentionRow(mention: m, chatName: name(m.chatID, m.chatName)) { jump(m) }
                    }
                }
            }
            // A conversation summarized for the first time streams in.
            if let id = digest.working, let text = digest.streamingText,
               !digest.entries.contains(where: { $0.chatID == id })
            {
                Section {
                    CatchUpSummaryBody(parsed: CatchUpSummaryParser.parse(text), includeActions: true)
                } header: {
                    header(title: name(id, digest.workingName ?? ""), working: true)
                }
            }
            ForEach(digest.entries) { e in
                Section {
                    let parsed = CatchUpSummaryParser.parse(e.text)
                    if parsed.isEmpty {
                        Text(e.text).textSelection(.enabled)
                    } else {
                        CatchUpSummaryBody(parsed: parsed, includeActions: true)
                    }
                } header: {
                    header(title: name(e.chatID, e.chatName), working: digest.working == e.chatID)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func name(_ chatID: String, _ stored: String) -> String {
        chatName(chatID) ?? stored
    }

    private func header(title: String, working: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title.isEmpty ? "Conversation" : title)
            Spacer()
            ProgressView()
                .controlSize(.mini)
                .opacity(working ? 1 : 0)
                .accessibilityHidden(!working)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            statusRow
        }
        .background(.bar)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if digest.working != nil {
                ProgressView().controlSize(.small)
            }
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if catchUp.mode == .onClick || digest.pending > 0 {
                Button("Update Now") { digest.updateNow() }
                    .disabled(digest.working != nil || digest.pending == 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var status: String {
        if digest.working != nil { return "Updating\u{2026}" }
        switch digest.paused {
        case .lowPower?: return "Paused in Low Power Mode"
        case .thermal?: return "Paused while this Mac cools down"
        case nil: break
        }
        if let e = digest.lastError { return e }
        if digest.pending > 0 {
            return digest.pending == 1 ? "1 conversation has new messages"
                : "\(digest.pending) conversations have new messages"
        }
        return "Up to date"
    }
}
