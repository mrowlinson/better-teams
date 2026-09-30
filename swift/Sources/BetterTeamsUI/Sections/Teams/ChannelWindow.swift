// ChannelWindow.swift — a channel's Posts in its own window (channel
// menu ▸ Open in New Window). One window per channel; it keeps its own
// timeline store (pop-out registry) so the main window's selection never
// moves, live posts reach both, and the channel being deleted or its
// team left shows the same inline state as the main window.
import AppKit
import OstMacCore
import SwiftUI
import Translation

@MainActor
final class ChannelWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: ChannelWindowController] = [:]
    private weak var app: AppState?
    private let channelID: String

    static func show(_ m: WindowModel, team: TeamItem, channel: TeamChannel) {
        guard let app = m.app else { return }
        if let c = open[channel.channelId] {
            PopOutPresenter.present(c)
            return
        }
        guard app.popOut(chatID: channel.channelId) != nil else { return }
        app.openPopout(chatID: channel.channelId)
        let c = ChannelWindowController(model: m, app: app, team: team, channel: channel)
        open[channel.channelId] = c
        if UserDefaults.standard.string(forKey: "NSWindow Frame ChannelWindow") == nil { c.window?.center() }
        PopOutPresenter.present(c)
    }

    /// The open channel window for a channel, if any (tests, evidence).
    static func window(for channelID: String) -> NSWindow? { open[channelID]?.window }

    private init(model m: WindowModel, app: AppState, team: TeamItem, channel: TeamChannel) {
        self.app = app
        channelID = channel.channelId
        let root = ChannelPopoutView(teams: app.teams, conv: app.popouts.store(for: channel.channelId),
                                     teamID: team.teamId, channelID: channel.channelId)
        let host = Hosting.controller(root, role: .pane, model: m)
        let window = NSWindow(contentViewController: host)
        window.title = "#\(channel.name) \u{2014} \(team.name)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 640))
        window.contentMinSize = NSSize(width: 360, height: 360)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ChannelWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func windowWillClose(_ notification: Notification) {
        app?.popouts.close(chatID: channelID)
        if Self.open[channelID] === self { Self.open[channelID] = nil }
    }
}

/// The window's content: header, posts, composer; or the deleted state.
struct ChannelPopoutView: View {
    @ObservedObject var teams: TeamsViewModel
    @ObservedObject var conv: ConversationStore
    let teamID: String
    let channelID: String
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            if let (team, channel) = TeamsListPane.locate(channelID, in: teams.teams), team.teamId == teamID {
                VStack(spacing: 0) {
                    header(team, channel)
                    Divider()
                    posts(team, channel, model)
                }
            } else if teams.deletedChannelIDs.contains(channelID) {
                EmptyPane("This channel was deleted", systemImage: "trash",
                          message: "It's no longer available in Teams. You can close this window.")
            } else {
                LoadingPane("Loading Posts\u{2026}")
            }
        }
    }

    private func header(_ team: TeamItem, _ channel: TeamChannel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(team.name) \u{203A} \(channel.name)").font(.headline).lineLimit(1).truncationMode(.head)
            if let d = channel.description, !d.isEmpty {
                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func posts(_ team: TeamItem, _ channel: TeamChannel, _ m: WindowModel) -> some View {
        let services = ConversationServices.of(m)
        if conv.chatID != channel.channelId || (conv.loading && conv.messages.isEmpty) {
            LoadingPane("Loading Posts\u{2026}")
        } else if let err = conv.error, conv.messages.isEmpty {
            ErrorPane(title: m.connection == .offline ? "You're Offline" : "Couldn't Load Posts",
                      message: err) { conv.retryOpen() }
        } else {
            VStack(spacing: 0) {
                if conv.messages.isEmpty {
                    EmptyPane("No Posts Yet", systemImage: "text.bubble",
                              message: "Start a post to get the conversation going.")
                } else {
                    TimelineRepresentable(conv: conv, scope: .posts, selectedID: nil)
                        .refreshStatus(conv.refreshing, failure: conv.refreshError,
                                       label: "Updating Posts", retry: { conv.refresh() })
                }
                Divider()
                Composer(chatID: channel.channelId, chatName: channel.name,
                         placeholder: "Start a post in #\(channel.name)", conv: conv,
                         composer: services.composer, attachments: services.attachments, services: services)
            }
            .translationTask(TranslationSession.Configuration(target: services.translation.sessionTarget)) { session in
                services.translation.attached(session)
            }
        }
    }
}
