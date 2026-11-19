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
                          tabs: section.tabs(chID, model), tabsStore: tabsStore)
        } else if let model, model.forced(.teams) == nil, let sel = TeamsSelection(model.nav.selection(in: .teams)),
                  let chID = sel.channelID, teams.deletedChannelIDs.contains(chID) {
            // TEAMSYNC: the open channel was deleted (here or elsewhere),
            // or its team was left: say so instead of a blank pane.
            EmptyPane("This channel was deleted", systemImage: "trash",
                      message: "It's no longer available in Teams. Choose another channel.")
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
    @ObservedObject var tabsStore: ChannelTabsStore
    @Environment(\.windowModel) private var model
    /// TABS-MGMT: add/rename/remove sheets. Built-in Posts/Files/Notes
    /// never manage (only the selected web tab renames/removes).
    /// One sheet slot (two `.sheet` modifiers on one view present
    /// unreliably, so add/rename share an item-based sheet).
    private enum ManageSheet: Identifiable {
        case add, rename
        var id: String {
            switch self {
            case .add: "add"
            case .rename: "rename"
            }
        }
    }
    @State private var manageSheet: ManageSheet?
    @State private var confirmingRemove = false
    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var manageFailed: String?

    /// The selected web tab, if the selection is one the store knows.
    private var selectedWebTab: ChannelTab? {
        if case .web(let id) = sel.tab { return tabs.first { $0.id == id } }
        return nil
    }

    /// Manage controls need the live store open on this channel (never
    /// in demo: the demo row is seeded, not fetched).
    private func canManage(_ m: WindowModel) -> Bool {
        !m.options.demo && tabsStore.channelID == channel.channelId
    }

    var body: some View {
        if let model {
            VStack(spacing: 0) {
                ChannelHeader(team: team, channel: channel, layout: ChannelTabLayout(tabs),
                              tab: Binding(get: { sel.tab }, set: { select(tab: $0, model) }),
                              canManage: canManage(model),
                              selectedWebTabName: selectedWebTab?.name,
                              onAdd: { draftName = ""; draftURL = ""; manageSheet = .add },
                              onRename: { draftName = selectedWebTab?.name ?? ""; manageSheet = .rename },
                              onRemove: { confirmingRemove = true })
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
            .sheet(item: $manageSheet) { sheet in
                switch sheet {
                case .add:
                    ChannelTabAddSheet(name: $draftName, url: $draftURL) {
                        Task {
                            await tabsStore.add(
                                name: draftName, url: Self.blankToNil(draftURL))
                            if tabsStore.manageError != nil {
                                manageFailed = tabsStore.manageError
                                tabsStore.clearManageError()
                            } else if let added = tabsStore.tabs.first(where: { $0.name == draftName }) {
                                select(tab: .web(added.id), model)
                            }
                            manageSheet = nil
                        }
                    }
                case .rename:
                    ChannelTabRenameSheet(name: $draftName) {
                        guard let id = selectedWebTab?.id else { return }
                        Task {
                            await tabsStore.rename(tabID: id, name: draftName)
                            if tabsStore.manageError != nil {
                                manageFailed = tabsStore.manageError
                                tabsStore.clearManageError()
                            }
                            manageSheet = nil
                        }
                    }
                }
            }
            .confirmationDialog(
                "Remove Tab",
                isPresented: $confirmingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove Tab", role: .destructive) {
                    guard let id = selectedWebTab?.id else { return }
                    Task {
                        await tabsStore.remove(tabID: id)
                        if tabsStore.manageError != nil {
                            manageFailed = tabsStore.manageError
                            tabsStore.clearManageError()
                        } else {
                            select(tab: .posts, model)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove “\(selectedWebTab?.name ?? "this tab")” from #\(channel.name)?")
            }
            .alert("Couldn't Update Tab", isPresented: Binding(
                get: { manageFailed != nil },
                set: { if !$0 { manageFailed = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(manageFailed ?? "")
            }
            .onAppear {
                // Evidence-only (teamadmin `teamDeleteConfirm=1` parity):
                // open a manage sheet for captures. Demo never manages
                // for real; the sheets' saves stay unpressed.
                if model.options.demo && model.options.evidence,
                   let sheet = model.options.route.flatMap(Route.init(string:))?.query["tabSheet"] {
                    switch sheet {
                    case "add": draftName = ""; draftURL = ""; manageSheet = .add
                    case "rename": draftName = selectedWebTab?.name ?? ""; manageSheet = .rename
                    case "remove": confirmingRemove = true
                    default: break
                    }
                }
            }
        }
    }

    /// A web tab renders in-window through FrameHost under `tab:<id>`
    /// (§6.3, §7.3); registering its URL is idempotent. A tab served by a
    /// catalog app is hosted natively over TeamsJS with channel context
    /// (APPHOST-B2); other tabs load their own page directly, the same
    /// route chat tabs take. Never the tab's Teams web page (APPNATIVE4).
    @ViewBuilder
    private func webTab(_ id: String, _ m: WindowModel) -> some View {
        if let t = tabs.first(where: { $0.id == id }), case .web = t.target {
            let _ = m.frameHost.library.store.ensureTeamApps(teamID: team.teamId, tabAppIDs: tabs.compactMap(\.appID))
            let l = m.frameHost.library.store.launch(forTab: t, team: team, channel: channel)
            switch ChatTabCatalog.route(for: t, hasManifest: l != nil) {
            case .hosted:
                let _ = l.map { m.frameHost.registerHostedTab(.tab(id), launch: $0, title: t.name) }
                FrameContainer(key: .tab(id))
            case .web(let url):
                let _ = m.frameHost.registerTab(.tab(id), url: url, title: t.name)
                FrameContainer(key: .tab(id))
            case .placeholder:
                ChatTabPlaceholder(
                    title: t.name, symbol: ChatTabCatalog.symbol(for: t),
                    message: ChatTabCatalog.kind(of: t) == .wiki
                        ? "Microsoft retired wiki tabs, so this tab has no pages to show."
                        : "This tab has no page of its own to show here: Teams saved no address for it.")
            }
        } else {
            FrameContainer(key: .tab(id))
        }
    }

    private func select(tab: ChannelTabKey, _ m: WindowModel) {
        var s = sel
        s.tab = tab
        m.navigator?.select(s.selection, in: .teams)
    }

    private static func blankToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : s
    }

    @ViewBuilder
    private func posts(_ m: WindowModel) -> some View {
        let services = ConversationServices.of(m)
        if conv.chatID != channel.channelId || (conv.loading && conv.messages.isEmpty) {
            LoadingPane("Loading Posts\u{2026}")
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
                        .refreshStatus(conv.refreshing, failure: conv.refreshError,
                                       label: "Updating Posts", retry: { conv.refresh() })
                        .refreshStatus(conv.loadingMore, label: "Loading Earlier Posts", alignment: .top)
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
    /// TABS-MGMT manage wiring (defaults keep previews/tests compiling).
    var canManage = false
    var selectedWebTabName: String? = nil
    var onAdd: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @Environment(\.contentTextScale) private var scale

    /// The selection is a removable/renamable web tab.
    private var managesSelection: Bool {
        canManage && selectedWebTabName != nil
    }

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
            if !fold.more.isEmpty || canManage {
                Menu {
                    ForEach(fold.more) { e in
                        Button(e.name) { tab = e.key }
                            .disabled(!e.enabled)
                    }
                    if canManage {
                        if !fold.more.isEmpty { Divider() }
                        Button("Add Tab…") { onAdd?() }
                        if managesSelection {
                            Button("Rename “\(selectedWebTabName ?? "Tab")”…") { onRename?() }
                            Button("Remove “\(selectedWebTabName ?? "Tab")”", role: .destructive) { onRemove?() }
                        }
                    }
                } label: {
                    Text("More")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("More Tabs")
            }
            if canManage {
                Button(action: { onAdd?() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Tab")
                .accessibilityLabel("Add Tab")
            }
        }
    }
}

/// TABS-MGMT add sheet: a native form for the new tab's name + page.
/// The page is a website-tab URL (the only kind creatable without a
/// catalog install); blank leaves the tab unconfigured.
struct ChannelTabAddSheet: View {
    @Binding var name: String
    @Binding var url: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Tab")
                .font(.headline)
                .padding(.top, 16)
            Form {
                TextField("Name", text: $name)
                TextField("Page URL", text: $url)
                    .textContentType(.URL)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 360)
    }
}

/// TABS-MGMT rename sheet: the tab's new display name.
struct ChannelTabRenameSheet: View {
    @Binding var name: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Rename Tab")
                .font(.headline)
                .padding(.top, 16)
            Form {
                TextField("Name", text: $name)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 360)
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
