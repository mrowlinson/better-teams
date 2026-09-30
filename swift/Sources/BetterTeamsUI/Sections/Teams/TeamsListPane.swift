// TeamsListPane.swift — Teams list pane (UI-SPEC §6.3): outline `List`,
// Pinned channels first, then one `DisclosureGroup` per team (collapse
// state persisted). Team rows: monogram tile + name. Channel rows:
// reserved unread dot + `number` + name, bold when unread, mention
// `.badge` at increased prominence (§10: unread = weight + dot + badge,
// never color alone). Selection binds through Navigator (R3, R21).
import OstMacCore
import SwiftUI

struct TeamsListPane: View {
    @ObservedObject var teams: TeamsViewModel
    @ObservedObject var unread: UnreadStore
    @ObservedObject var mentions: MentionStore
    @ObservedObject var prefs: ChannelPrefs
    @ObservedObject var folders: FolderStore
    let state: TeamsSectionState
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            content(model)
        }
    }

    @ViewBuilder
    private func content(_ m: WindowModel) -> some View {
        let forced = m.forced(.teams)
        if forced == .loading || (teams.state == .loading && teams.teams.isEmpty) {
            LoadingPane("Loading Teams\u{2026}")
        } else if forced == .error {
            ErrorPane(title: "Couldn't Load Teams", message: "You're offline.") {}
        } else if case .error(let msg) = teams.state, teams.teams.isEmpty {
            ErrorPane(title: "Couldn't Load Teams", message: m.connection == .offline ? "You're offline." : msg) {
                teams.refresh()
            }
        } else if forced == .empty || teams.teams.isEmpty {
            EmptyPane("You're not a member of any teams", systemImage: "person.3") {
                Button("Join a Team…") {
                    m.presentSheet(SheetRequest(TeamsCommands.joinTeamSheet, in: .teams))
                }
                .disabled(m.connection == .offline)
            }
        } else {
            // R12: a refresh runs behind the rows on screen.
            list(m)
                .refreshStatus(teams.state == .loading, failure: Self.failure(teams.state),
                               label: "Updating Teams", retry: { teams.refresh() })
                .safeAreaInset(edge: .bottom, spacing: 0) { actionError }
        }
    }

    /// Quiet note when Teams refused a channel/team action (the change
    /// was undone); dismissible, no alert. Same shape as the chat list.
    @ViewBuilder
    private var actionError: some View {
        if let text = teams.actionError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                Text("Couldn't complete that: \(text)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    teams.clearActionError()
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// A failed refresh behind the rows on screen (quiet notice).
    static func failure(_ state: TeamsState) -> String? {
        if case .error(let message) = state { message } else { nil }
    }

    private func list(_ m: WindowModel) -> some View {
        let all = teams.teams
        let pinned = prefs.pinned.compactMap { id in
            Self.locate(id, in: all).map { PinnedChannel(team: $0.0, channel: $0.1) }
        }
        // Channels moved into a section (a folder) list under its name,
        // after Pinned; pinned wins when both apply.
        let sections: [(ChatFolder, [PinnedChannel])] = folders.folders.compactMap { f in
            let rows = all.flatMap { team in
                team.channels
                    .filter { folders.overrides[$0.channelId] == f.id && !prefs.isPinned($0.channelId) && !prefs.isHidden($0.channelId) }
                    .map { PinnedChannel(team: team, channel: $0) }
            }
            return rows.isEmpty ? nil : (f, rows)
        }
        let pinnedIDs = Set(pinned.map(\.id)).union(sections.flatMap { $0.1.map(\.id) })
        let selection = Binding<String?>(
            get: { TeamsSelection(m.nav.selection(in: .teams))?.rowTag },
            set: { tag in select(tag, m) })
        return List(selection: selection) {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { p in
                        channelRow(p.channel, team: p.team, showsTeam: true, m)
                    }
                }
            }
            ForEach(sections, id: \.0.id) { folder, rows in
                Section(folder.name) {
                    ForEach(rows) { p in
                        channelRow(p.channel, team: p.team, showsTeam: true, m)
                    }
                }
            }
            Section("Your Teams") {
                ForEach(all.filter { !prefs.isHidden($0.teamId) }) { team in
                    DisclosureGroup(isExpanded: Binding(get: { state.isExpanded(team.teamId) },
                                                        set: { state.setExpanded(team.teamId, $0) })) {
                        let visible = team.channels.filter { !pinnedIDs.contains($0.channelId) }
                        ForEach(visible.filter { !prefs.isHidden($0.channelId) }) { ch in
                            channelRow(ch, team: team, showsTeam: false, m)
                        }
                        let hidden = visible.filter { prefs.isHidden($0.channelId) }
                        if !hidden.isEmpty {
                            HiddenChannelsRow(count: hidden.count, reveal: state.revealHidden.contains(team.teamId)) {
                                state.toggleReveal(team.teamId)
                            }
                            if state.revealHidden.contains(team.teamId) {
                                ForEach(hidden) { ch in
                                    channelRow(ch, team: team, showsTeam: false, m)
                                }
                            }
                        }
                    } label: {
                        TeamRow(name: team.name,
                                unread: !state.isExpanded(team.teamId)
                                    && team.channels.contains { unread.isUnread(chatID: $0.channelId) })
                            .tag("team:\(team.teamId)")
                    }
                }
            }
            let hiddenTeams = all.filter { prefs.isHidden($0.teamId) }
            if !hiddenTeams.isEmpty {
                Section("Hidden Teams") {
                    ForEach(hiddenTeams) { team in
                        TeamRow(name: team.name, unread: false)
                            .foregroundStyle(.secondary)
                            .tag("team:\(team.teamId)")
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { tags in
            if let tag = tags.first {
                if tag.hasPrefix("chan:") {
                    channelMenu(String(tag.dropFirst(5)), m)
                } else if tag.hasPrefix("team:"), let team = teams.teams.first(where: { "team:\($0.teamId)" == tag }) {
                    teamMenu(team, m)
                }
            }
        } primaryAction: { tags in
            Self.primaryAction(tags, m) { select($0, m) }
        }
    }

    private func channelRow(_ ch: TeamChannel, team: TeamItem, showsTeam: Bool, _ m: WindowModel) -> some View {
        ChannelRow(name: ch.name, teamName: showsTeam ? team.name : nil,
                   unread: unread.isUnread(chatID: ch.channelId),
                   mentioned: mentions.contains(chatID: ch.channelId),
                   hidden: prefs.isHidden(ch.channelId),
                   muted: prefs.level(ch.channelId) == .muted)
            .tag("chan:\(ch.channelId)")
    }

    // MARK: context menus (§6.3; ≤3 groups, one submenu level)

    @ViewBuilder
    private func teamMenu(_ team: TeamItem, _ m: WindowModel) -> some View {
        Button(prefs.isHidden(team.teamId) ? "Show" : "Hide") { run(TeamsCommands.hideTeam, team.teamId, m) }
        Button("Manage Team…") { run(TeamsCommands.manageMembers, team.teamId, m) }
        Button("Add Channel…") { run(TeamsCommands.createChannel, team.teamId, m) }
        Button("Get Link to Team") { run(TeamsCommands.teamLink, team.teamId, m) }
        Button("Mark All as Read") { run(TeamsCommands.markTeamRead, team.teamId, m) }
        Divider()
        Button("Leave Team…", role: .destructive) { run(TeamsCommands.leaveTeam, team.teamId, m) }
            .disabled(m.connection == .offline)
    }

    /// Channel menu, in Teams' order: window, notification/section/hide
    /// group, edit/manage/link/email/workflows group, Delete last after a
    /// separator. Every item works or is disabled with its reason.
    @ViewBuilder
    private func channelMenu(_ id: String, _ m: WindowModel) -> some View {
        let located = Self.locate(id, in: teams.teams)
        let offline = m.connection == .offline
        Button("Open in New Window") { run(TeamsCommands.openChannelWindow, id, m) }
        Divider()
        Button("Mark as Read") { run(TeamsCommands.markChannelRead, id, m) }
        Menu("Channel Notifications") {
            ForEach(ChatNotifyLevel.allCases, id: \.rawValue) { l in
                Toggle(TeamsSection.levelTitle(l), isOn: Binding(
                    get: { prefs.level(id) == l },
                    set: { if $0 { run(TeamsCommands.notifications, "\(l.rawValue)|\(id)", m) } }))
            }
        }
        Menu("Move to Section") {
            if folders.folders.isEmpty {
                Button("No Sections Yet") {}.disabled(true)
            }
            ForEach(folders.folders) { f in
                Toggle(f.name, isOn: Binding(
                    get: { folders.overrides[id] == f.id },
                    set: { run(TeamsCommands.moveChannelToSection, "\($0 ? f.id : "none")|\(id)", m) }))
            }
            if folders.overrides[id] != nil {
                Divider()
                Button("Remove from Section") { run(TeamsCommands.moveChannelToSection, "none|\(id)", m) }
            }
        }
        Button(prefs.isPinned(id) ? "Unpin" : "Pin") { run(TeamsCommands.pinChannel, id, m) }
        Button(prefs.isHidden(id) ? "Show" : "Hide") { run(TeamsCommands.hideChannel, id, m) }
        Divider()
        let edit = located.map { teams.permission(.edit, teamID: $0.0.teamId, channelID: id) }
            ?? .denied("This channel is no longer available.")
        Button("Edit Channel\u{2026}") { run(TeamsCommands.editChannel, id, m) }
            .disabled(offline || !edit.isAllowed)
            .help(edit.reason ?? "")
        Button("Manage Channel\u{2026}") { run(TeamsCommands.manageChannel, id, m) }
        Button("Get Link to Channel") { run(TeamsCommands.copyLink, id, m) }
        Button("Get Email Address") { run(TeamsCommands.channelEmail, id, m) }
            .disabled((located?.1.email ?? "").isEmpty)
            .help((located?.1.email ?? "").isEmpty ? "This channel has no email address." : "")
        Button("Workflows\u{2026}") { run(TeamsCommands.channelWorkflows, id, m) }
            .disabled(m.options.demo)
            .help(m.options.demo ? "Workflows open in Power Automate, which the demo doesn't reach." : "")
        Divider()
        let del = located.map { teams.permission(.delete, teamID: $0.0.teamId, channelID: id) }
            ?? .denied("This channel is no longer available.")
        Button("Delete Channel\u{2026}") { run(TeamsCommands.deleteChannel, id, m) }
            .disabled(offline || !del.isAllowed)
            .help(del.reason ?? "")
        if let why = del.reason {
            Text(why)
        }
    }

    private func run(_ c: CommandID, _ arg: String, _ m: WindowModel) {
        _ = m.provider(.teams).perform(c, arg: arg, m)
    }

    // MARK: selection

    /// Double-click / Return on a row: select it; a channel also pops out
    /// (a team just selects). The list's `primaryAction` calls exactly this.
    static func primaryAction(_ tags: Set<String>, _ m: WindowModel, select: (String) -> Void) {
        guard let tag = tags.first else { return }
        select(tag)
        if let channel = doubleClickChannelID(tag) {
            _ = m.provider(.teams).perform(TeamsCommands.openChannelWindow, arg: channel, m)
        }
    }

    /// The channel a double-clicked row pops out (a team row does not).
    static func doubleClickChannelID(_ tag: String) -> String? {
        tag.hasPrefix("chan:") ? String(tag.dropFirst(5)) : nil
    }

    private func select(_ tag: String?, _ m: WindowModel) {
        guard let tag else {
            m.navigator?.select(nil, in: .teams)
            return
        }
        let current = TeamsSelection(m.nav.selection(in: .teams))
        guard current?.rowTag != tag else { return }
        if tag.hasPrefix("team:") {
            m.navigator?.select(TeamsSelection(teamID: String(tag.dropFirst(5))).selection, in: .teams)
        } else if tag.hasPrefix("chan:"), let (team, ch) = Self.locate(String(tag.dropFirst(5)), in: teams.teams) {
            m.navigator?.select(TeamsSelection(teamID: team.teamId, channelID: ch.channelId).selection, in: .teams)
        }
    }

    static func locate(_ channelID: String, in teams: [TeamItem]) -> (TeamItem, TeamChannel)? {
        for t in teams {
            if let ch = t.channels.first(where: { $0.channelId == channelID }) { return (t, ch) }
        }
        return nil
    }
}

// MARK: rows

struct PinnedChannel: Identifiable {
    let team: TeamItem
    let channel: TeamChannel
    var id: String { channel.channelId }
}

/// Rounded-square monogram tile (teams; avatars are circles, §6).
struct TeamTile: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Palette.avatarFill(for: name))
            .overlay {
                Text(Avatar.initials(name))
                    .font(AppFont.monogram(size))
                    .foregroundStyle(Palette.avatarText)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct TeamRow: View {
    let name: String
    let unread: Bool
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            TeamTile(name: name)
            Text(name)
                .font(unread ? AppFont.headline(scale) : AppFont.bodyEmphasized(scale))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unread ? "\(name), unread" : name)
    }
}

struct ChannelRow: View {
    let name: String
    let teamName: String?
    let unread: Bool
    let mentioned: Bool
    let hidden: Bool
    let muted: Bool
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            // Reserved slot: toggling unread never shifts the name (R13).
            Circle()
                .fill(.tint)
                .frame(width: 7, height: 7)
                .opacity(unread ? 1 : 0)
                .accessibilityHidden(true)
            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(unread ? AppFont.headline(scale) : AppFont.body(scale))
                    .foregroundStyle(hidden ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let teamName {
                    Text(teamName)
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if muted || hidden {
                Image(systemName: hidden ? "eye.slash" : "bell.slash")
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
            }
        }
        .badge(mentioned ? Text("@") : nil)
        .badgeProminence(.increased)
        .help(teamName.map { "\(name) — \($0)" } ?? name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        var parts = [name]
        if let teamName { parts.append(teamName) }
        if unread { parts.append("unread") }
        if mentioned { parts.append("mentioned") }
        if hidden { parts.append("hidden") }
        if muted { parts.append("notifications off") }
        return parts.joined(separator: ", ")
    }
}

/// "N hidden channels" toggle row at the end of a team's channels.
struct HiddenChannelsRow: View {
    let count: Int
    let reveal: Bool
    let toggle: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 7, height: 7) // channel rows' unread slot
                // The row stands for hidden channels, shown or not.
                Image(systemName: "eye.slash")
                    .frame(width: 16)
                Text(reveal ? "Hide Hidden Channels" : (count == 1 ? "1 hidden channel" : "\(count) hidden channels"))
                    .font(AppFont.subheadline(scale))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .selectionDisabled()
    }
}
