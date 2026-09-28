// ChannelDetail.swift — the channel view (UI-SPEC §6.3).
//
// Header: team tile, "Team › Channel", description; tab row Posts |
// Files | Notes | ≤2 web tabs | More ▾ (from `ChannelTab.target`).
// Posts reuses the conversation timeline (Posts scope: root posts, each
// with a thread summary row) and the conversation composer; Files,
// Notes and web tabs call their owning lanes' seams (`FileTable`,
// `NotesTab`, `FrameContainer`).
import OstMacCore
import SwiftUI
import Translation

struct TeamsDetailPane: View {
    @ObservedObject var teams: TeamsViewModel
    @ObservedObject var conv: ConversationStore
    @ObservedObject var tabsStore: ChannelTabsStore
    let section: TeamsSection
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, model.forced(.teams) == nil, let sel = TeamsSelection(model.nav.selection(in: .teams)),
           let chID = sel.channelID, let (team, channel) = TeamsListPane.locate(chID, in: teams.teams),
           team.teamId == sel.teamID
        {
            ChannelDetail(team: team, channel: channel, sel: sel, conv: conv,
                          tabs: section.tabs(chID, model))
        } else if let model, model.forced(.teams) != nil || teams.teams.isEmpty {
            // Loading, error or no teams: the list pane carries the state;
            // an empty detail never repeats it or asks for a selection
            // that cannot be made yet (R18).
            Color.clear
        } else if let model, let sel = TeamsSelection(model.nav.selection(in: .teams)),
                  let team = teams.teams.first(where: { $0.teamId == sel.teamID }) {
            EmptyPane(team.name, systemImage: "person.3",
                      message: team.channels.count == 1 ? "1 channel. Choose it to see its posts."
                          : "\(team.channels.count) channels. Choose one to see its posts.")
        } else {
            NoSelectionPane("No Channel Selected")
        }
    }
}

struct ChannelDetail: View {
    let team: TeamItem
    let channel: TeamChannel
    let sel: TeamsSelection
    @ObservedObject var conv: ConversationStore
    let tabs: [ChannelTab]
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            VStack(spacing: 0) {
                ChannelHeader(team: team, channel: channel, layout: ChannelTabLayout(tabs),
                              tab: Binding(get: { sel.tab }, set: { select(tab: $0, model) }))
                Divider()
                Group {
                    switch sel.tab {
                    case .posts: posts(model)
                    case .files: FileTable(scope: .channel(team: team.teamId, channel: channel.channelId))
                    case .notes: NotesTab(scope: .channel(team: team.teamId, channel: channel.channelId))
                    case .web(let id): webTab(id, model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A web tab renders in-window through FrameHost under `tab:<id>`
    /// (§6.3, §7.3); registering its URL is idempotent.
    private func webTab(_ id: String, _ m: WindowModel) -> some View {
        if let t = tabs.first(where: { $0.id == id }), case .web(let url) = t.target {
            m.frameHost.registerTab(.tab(id), url: url, title: t.name)
        }
        return FrameContainer(key: .tab(id))
    }

    private func select(tab: ChannelTabKey, _ m: WindowModel) {
        var s = sel
        s.tab = tab
        m.navigator?.select(s.selection, in: .teams)
    }

    @ViewBuilder
    private func posts(_ m: WindowModel) -> some View {
        let services = ConversationServices.of(m)
        if conv.chatID != channel.channelId || (conv.loading && conv.messages.isEmpty) {
            LoadingPane()
        } else if let err = conv.error, conv.messages.isEmpty {
            ErrorPane(title: m.connection == .offline ? "You're Offline" : "Couldn't Load Posts",
                      message: err) { conv.retryOpen() }
        } else {
            VStack(spacing: 0) {
                if conv.jumpMissedID != nil {
                    HStack(spacing: 8) {
                        Label("Message no longer available", systemImage: "exclamationmark.bubble")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Dismiss") { conv.clearJumpMissed() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                if conv.messages.isEmpty {
                    EmptyPane("No Posts Yet", systemImage: "text.bubble",
                              message: "Start a post to get the conversation going.")
                } else {
                    TimelineRepresentable(conv: conv, scope: .posts, selectedID: sel.threadID)
                }
                Divider()
                Composer(chatID: channel.channelId, chatName: channel.name,
                         placeholder: "Start a post in #\(channel.name)", conv: conv,
                         composer: services.composer, attachments: services.attachments, services: services)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                services.attachments.stage(urls: files)
                return true
            }
            .translationTask(TranslationSession.Configuration(target: services.translation.sessionTarget)) { session in
                services.translation.attached(session)
            }
        }
    }
}

/// Channel header (content layer): tile, "Team › Channel" (tail
/// truncated), description, then the tab row. Tabs sit on their own row
/// so the title keeps the width. The row never exceeds the pane: the
/// widest fold that fits wins (`ViewThatFits`), trailing tabs fold into
/// More ▾, and the selected tab is always a visible, selected segment
/// (an overflow tab picked from More takes the last segment's place).
struct ChannelHeader: View {
    let team: TeamItem
    let channel: TeamChannel
    let layout: ChannelTabLayout
    @Binding var tab: ChannelTabKey
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TeamTile(name: team.name, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(team.name) › \(channel.name)")
                        .font(AppFont.title3(scale))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let d = channel.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                        Text(d)
                            .font(AppFont.subheadline(scale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .help("\(team.name) › \(channel.name)")
            .accessibilityElement(children: .combine)
            ViewThatFits(in: .horizontal) {
                tabRow(ChannelTabLayout.maxSegments)
                tabRow(4)
                tabRow(3)
                tabRow(2)
                tabRow(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabRow(_ segments: Int) -> some View {
        let fold = layout.fold(segments: segments, selected: tab)
        return HStack(spacing: 8) {
            Picker("View", selection: $tab) {
                ForEach(fold.segments) { e in
                    Text(e.name).tag(e.key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !fold.more.isEmpty {
                Menu {
                    ForEach(fold.more) { e in
                        Button(e.name) { tab = e.key }
                            .disabled(!e.enabled)
                    }
                } label: {
                    Text("More")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("More Tabs")
            }
        }
    }
}

/// Under each root post (§6.3): "N replies" opens the thread inspector;
/// "Reply" starts one. Aligned with the message text (16 + 28 + 10 pt).
struct ThreadSummaryRow: View {
    let rootID: String
    let replies: Int
    let lastReply: String?
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        let open = model.flatMap { TeamsSelection($0.nav.selection(in: .teams))?.threadID } == rootID
        HStack(spacing: 8) {
            Button(action: openThread) {
                Label(title, systemImage: replies == 0 ? "arrowshape.turn.up.left" : "bubble.left.and.bubble.right")
                    .font(open ? AppFont.bodyEmphasized(scale) : AppFont.body(scale))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .help(replies == 0 ? "Reply in Thread" : "Open Thread")
            if replies > 0, let lastReply {
                Text("· Last reply \(ChatListFormat.previewTime(lastReply, now: RelativeClock.shared.now))")
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 54)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        switch replies {
        case 0: "Reply"
        case 1: "1 reply"
        default: "\(replies) replies"
        }
    }

    private func openThread() {
        guard let model, var s = TeamsSelection(model.nav.selection(in: .teams)) else { return }
        s.threadID = rootID
        model.navigator?.select(s.selection, in: .teams)
        model.navigator?.setInspector(true, explicit: true)
    }
}
