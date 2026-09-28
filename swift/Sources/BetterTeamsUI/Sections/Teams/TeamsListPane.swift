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
            LoadingPane()
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
            list(m)
        }
    }

    private func list(_ m: WindowModel) -> some View {
        let all = teams.teams
        let pinned = prefs.pinned.compactMap { id in
            Self.locate(id, in: all).map { PinnedChannel(team: $0.0, channel: $0.1) }
        }
        let pinnedIDs = Set(pinned.map(\.id))
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
            Section("Your Teams") {
                ForEach(all) { team in
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
            if let tag = tags.first { select(tag, m) }
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
        Button("Create Channel…") { run(TeamsCommands.createChannel, team.teamId, m) }
        Button("Manage Members…") { run(TeamsCommands.manageMembers, team.teamId, m) }
        Divider()
        Button("Mark All as Read") { run(TeamsCommands.markTeamRead, team.teamId, m) }
    }

    @ViewBuilder
    private func channelMenu(_ id: String, _ m: WindowModel) -> some View {
        Button("Mark as Read") { run(TeamsCommands.markChannelRead, id, m) }
        Menu("Notifications") {
            ForEach(ChatNotifyLevel.allCases, id: \.rawValue) { l in
                Toggle(TeamsSection.levelTitle(l), isOn: Binding(
                    get: { prefs.level(id) == l },
                    set: { if $0 { run(TeamsCommands.notifications, "\(l.rawValue)|\(id)", m) } }))
            }
        }
        Button("Copy Link") { run(TeamsCommands.copyLink, id, m) }
        Divider()
        Button(prefs.isPinned(id) ? "Unpin" : "Pin") { run(TeamsCommands.pinChannel, id, m) }
        Button(prefs.isHidden(id) ? "Show" : "Hide") { run(TeamsCommands.hideChannel, id, m) }
    }

    private func run(_ c: CommandID, _ arg: String, _ m: WindowModel) {
        _ = m.provider(.teams).perform(c, arg: arg, m)
    }

    // MARK: selection

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
