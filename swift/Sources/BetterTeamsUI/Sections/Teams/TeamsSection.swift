// TeamsSection.swift — Teams section provider (UI-SPEC §6.3).
//
// List = teams › channels outline (Pinned first); detail = the channel
// (Posts | Files | Notes | web tabs | More ▾); inspector = the thread
// when a post's thread is open, else the team (roster). Loads start in
// `selectionDidChange` (R24). Demo mode uses in-memory stores only.
import AppKit
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class TeamsSection: SectionProvider, InspectorCapable {
    let section: SectionID = .teams
    let title = "Teams"
    let hasInspector = true

    private var uiState: TeamsSectionState?
    private var channelPrefs: ChannelPrefs?
    /// Live channel tabs (demo reads `DemoTeams.tabs`: demo ids are not
    /// `19:…@thread.tacv2`, which the store requires).
    let tabsStore = ChannelTabsStore()
    private var rosters: [String: TeamRosterViewModel] = [:]
    private var rosterLoaded: Set<String> = []
    private var lastThread: String?
    private var seeded = false

    // MARK: per-window state

    func state(_ m: WindowModel) -> TeamsSectionState {
        if let s = uiState { return s }
        let s = TeamsSectionState(accountKey: m.accountKey, persist: !m.options.demo)
        uiState = s
        return s
    }

    func prefs(_ m: WindowModel) -> ChannelPrefs {
        if let p = channelPrefs { return p }
        let pins = m.app.map { $0.pinnedChannelStore(accountKey: m.accountKey) }
            ?? PinnedChannelStore(accountKey: m.accountKey, defaults: m.options.demo ? nil : .standard)
        let p = ChannelPrefs(pins: pins, rules: m.app?.rules, demo: m.options.demo)
        channelPrefs = p
        return p
    }

    func roster(_ teamID: String, _ m: WindowModel) -> TeamRosterViewModel {
        if let r = rosters[teamID] { return r }
        let r: TeamRosterViewModel
        if m.options.demo {
            r = TeamRosterViewModel(
                teamID: teamID,
                listFetcher: { DemoTeams.roster(teamID: $0) },
                addFetcher: { team, user, owner in
                    TeamMemberAddResponse(ok: true, member: TeamMember(
                        id: "\(team)-\(user)", displayName: user, userId: user, email: user,
                        roles: owner ? ["owner"] : [], isOwner: owner))
                },
                removeFetcher: { TeamMemberRemoveResponse(ok: true, teamId: $0, memberId: $1) })
        } else {
            r = TeamRosterViewModel(teamID: teamID)
        }
        rosters[teamID] = r
        return r
    }

    /// Channel tabs for one channel (§6.3, from `ChannelTab.target`).
    func tabs(_ channelID: String, _ m: WindowModel) -> [ChannelTab] {
        if m.options.demo { return DemoTeams.tabs(for: channelID) }
        return tabsStore.channelID == channelID ? tabsStore.tabs : []
    }

    /// Demo: a pinned channel, a hidden one, a collapsed team, unread
    /// and mention state. In memory only; seeded once.
    private func seedDemoIfNeeded(_ m: WindowModel) {
        guard m.options.demo, !seeded, let app = m.app else { return }
        seeded = true
        prefs(m).seedDemo(pinned: ["demo-chan-crit"], hidden: ["demo-chan-mkt-launch"])
        state(m).seedCollapsed(["demo-team-design"])
        app.unread.markUnread(chatID: "demo-chan-general")
        app.unread.markUnread(chatID: "demo-chan-mkt-general")
        app.mentions.adopt(app.mentions.mentionedIDs.union(["demo-chan-mkt-general"]))
        // Notifications Off on an unread channel: the muted glyph beside
        // the unread dot and bold name.
        prefs(m).setLevel("demo-chan-general", .muted)
        // Evidence: `teams/<team>/<channel>?deleted=1` deletes the open
        // channel through the (in-memory) demo path: the deleted state.
        if m.options.route.flatMap(Route.init(string:))?.query["deleted"] == "1",
           let sel = current(m), let ch = sel.channelID {
            let teams = app.teams
            Task { @MainActor in
                // Once the list holds the team (first load), delete.
                for await rows in teams.$teams.values where rows.contains(where: { $0.teamId == sel.teamID }) {
                    await teams.deleteChannel(teamID: sel.teamID, channelID: ch)
                    break
                }
            }
        }
    }

    // MARK: panes

    /// The teams the list shows: the one source for the rail badge and
    /// the subtitle. A forced evidence state (empty, loading, error)
    /// shows no teams, so no counts.
    private func listedTeams(_ m: WindowModel) -> [TeamItem] {
        guard let app = m.app, m.forced(.teams) == nil else { return [] }
        return app.teams.teams
    }

    func subtitle(_ m: WindowModel) -> String {
        guard let app = m.app else { return "" }
        let n = Self.channelIDs(listedTeams(m)).filter { app.unread.isUnread(chatID: $0) }.count
        return n > 0 ? "\(n) unread" : ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(Self.unavailable) }
        seedDemoIfNeeded(m)
        return AnyView(TeamsListPane(teams: app.teams, unread: app.unread, mentions: app.mentions,
                                     prefs: prefs(m), folders: m.graph.chats.folders, state: state(m)))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane("No Channel Selected")) }
        return AnyView(TeamsDetailPane(teams: app.teams, conv: m.graph.conv, tabsStore: tabsStore, section: self))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return AnyView(Self.unavailable) }
        return AnyView(TeamsInspectorPane(teams: app.teams, conv: m.graph.conv, section: self))
    }

    private static var unavailable: some View {
        EmptyPane("Teams Unavailable", systemImage: "person.3",
                  message: "Teams and channels appear in the active account's window.")
    }

    var allToolbarItems: [CommandID] { [TeamsCommands.joinOrCreate] }

    // MARK: routes and loads

    /// `teams/<team>/<channel>?tab=posts|files|notes|web:<id>&thread=<mid>`.
    func selection(for route: Route) -> SectionSelection? {
        let tail = route.tail.map(TeamsDemoAliases.resolve)
        guard let team = tail.first else { return nil }
        var sel = TeamsSelection(teamID: team, channelID: tail.count > 1 ? tail[1] : nil)
        if let raw = route.query["tab"], let t = ChannelTabKey(raw: raw) { sel.tab = t }
        if let t = route.query["thread"], !t.isEmpty { sel.threadID = TeamsDemoAliases.resolve(t) }
        return TeamsSelection(sel.selection)?.selection
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard let app = m.app, let s = TeamsSelection(sel) else { lastThread = nil; return }
        if let ch = s.channelID {
            if m.graph.openChatID != ch {
                app.openChannel(channelID: ch, channelName: channelName(ch, app.teams.teams) ?? "Channel")
            }
            if !m.options.demo, tabsStore.channelID != ch { tabsStore.open(channelID: ch) }
        }
        let r = roster(s.teamID, m)
        if rosterLoaded.insert(s.teamID).inserted { Task { await r.load() } }
        // "N replies" opens the thread inspector (§6.3). Opening a thread
        // (click or `?thread=` route) is explicit intent: it opens even
        // where the inspector would otherwise yield (never dropped).
        // Also when the model already records it visible: before the
        // window is placed the split may still hold it collapsed.
        // `setInspector` acts on the section on screen, so a Teams
        // selection changed while another section shows (Navigator
        // `select(_:in:)`) must not open that section's inspector; the
        // thread stays pending until Teams is showing.
        guard m.nav.section == .teams else { return }
        if let t = s.threadID, t != lastThread {
            lastThread = t
            m.navigator?.setInspector(true, explicit: true)
        }
        lastThread = s.threadID
    }

    func badge(_ m: WindowModel) -> Int? {
        guard let app = m.app else { return nil }
        let n = Self.channelIDs(listedTeams(m)).filter { app.mentions.contains(chatID: $0) }.count
        return n > 0 ? n : nil
    }

    func badgeChanges(_ m: WindowModel) -> [AnyPublisher<Void, Never>] {
        guard let app = m.app else { return [] }
        return [app.mentions.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                app.teams.objectWillChange.map { _ in () }.eraseToAnyPublisher()]
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        switch r.name {
        case TeamsCommands.createTeamSheet: return AnyView(CreateTeamSheet(teams: app.teams))
        case TeamsCommands.joinTeamSheet:
            // Evidence (demo routes): `teams?sheet=joinTeam&q=<query>`,
            // `&search=loading|error` forces the results list's state.
            let route = m.options.demo ? m.options.route.flatMap(Route.init(string:)) : nil
            return AnyView(JoinTeamSheet(teams: app.teams, query: route?.query["q"] ?? "",
                                         forced: route?.query["search"].flatMap(ForcedPaneState.init(rawValue:))))
        case TeamsCommands.createChannelSheet:
            let team = r.arg ?? current(m)?.teamID ?? app.teams.teams.first?.teamId ?? ""
            return AnyView(CreateChannelSheet(teams: app.teams, teamID: team))
        case TeamsCommands.addMemberSheet:
            guard let team = r.arg ?? current(m)?.teamID else { return nil }
            return AnyView(AddMemberSheet(roster: roster(team, m)))
        case TeamsCommands.editChannelSheet:
            guard let id = r.arg ?? current(m)?.channelID else { return nil }
            return AnyView(EditChannelSheet(teams: app.teams, channelID: id))
        default: return nil
        }
    }

    // MARK: commands

    private func current(_ m: WindowModel) -> TeamsSelection? {
        m.nav.search == nil ? TeamsSelection(m.nav.selection(in: .teams)) : nil
    }

    /// Context menus pass the row's id; the menu bar acts on the selection.
    private func channelTarget(_ arg: String?, _ m: WindowModel) -> String? {
        if let arg, !arg.isEmpty { return arg }
        return m.nav.section == .teams ? current(m)?.channelID : nil
    }

    private func teamTarget(_ arg: String?, _ m: WindowModel) -> String? {
        if let arg, !arg.isEmpty { return arg }
        return m.nav.section == .teams ? current(m)?.teamID : nil
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let app = m.app else { return false }
        switch c {
        case TeamsCommands.joinOrCreate:
            let name = arg == TeamsCommands.createArg ? TeamsCommands.createTeamSheet : TeamsCommands.joinTeamSheet
            m.presentSheet(SheetRequest(name, in: .teams))
        case TeamsCommands.createChannel:
            m.presentSheet(SheetRequest(TeamsCommands.createChannelSheet, in: .teams, arg: teamTarget(arg, m)))
        case TeamsCommands.manageMembers:
            guard let team = teamTarget(arg, m) else { return false }
            var s = current(m).flatMap { $0.teamID == team ? $0 : nil } ?? TeamsSelection(teamID: team)
            s.threadID = nil
            m.navigator?.select(section: .teams)
            m.navigator?.select(s.selection, in: .teams)
            m.navigator?.setInspector(true, explicit: true)
        case TeamsCommands.markTeamRead:
            guard let team = teamTarget(arg, m), let t = app.teams.teams.first(where: { $0.teamId == team }) else {
                return false
            }
            for ch in t.channels {
                app.unread.markRead(chatID: ch.channelId)
                app.mentions.markRead(chatID: ch.channelId)
            }
        case TeamsCommands.markChannelRead:
            guard let ch = channelTarget(arg, m) else { return false }
            app.unread.markRead(chatID: ch)
            app.mentions.markRead(chatID: ch)
        case TeamsCommands.notifications:
            // arg = "<level>" (menu bar) or "<level>|<channel>" (row menu).
            let parts = (arg ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard let level = parts.first.flatMap(ChatNotifyLevel.init(rawValue:)),
                  let ch = channelTarget(parts.count > 1 ? parts[1] : nil, m) else { return false }
            prefs(m).setLevel(ch, level)
        case TeamsCommands.copyLink:
            guard let ch = channelTarget(arg, m), let link = Self.link(channelID: ch, teams: app.teams.teams) else {
                return false
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        case TeamsCommands.pinChannel:
            guard let ch = channelTarget(arg, m) else { return false }
            prefs(m).setPinned(ch, !prefs(m).isPinned(ch))
        case TeamsCommands.hideChannel:
            guard let ch = channelTarget(arg, m) else { return false }
            prefs(m).setHidden(ch, !prefs(m).isHidden(ch))
        case TeamsCommands.manageChannel:
            // Standard channels share the team roster: open it.
            guard let ch = channelTarget(arg, m),
                  let (team, _) = TeamsListPane.locate(ch, in: app.teams.teams) else { return false }
            return perform(TeamsCommands.manageMembers, arg: team.teamId, m)
        case TeamsCommands.channelEmail:
            guard let ch = channelTarget(arg, m),
                  let email = TeamsListPane.locate(ch, in: app.teams.teams)?.1.email, !email.isEmpty else {
                return false
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(email, forType: .string)
        case TeamsCommands.editChannel:
            guard let ch = channelTarget(arg, m),
                  let (team, _) = TeamsListPane.locate(ch, in: app.teams.teams),
                  app.teams.permission(.edit, teamID: team.teamId, channelID: ch).isAllowed else { return false }
            m.presentSheet(SheetRequest(TeamsCommands.editChannelSheet, in: .teams, arg: ch))
        case TeamsCommands.deleteChannel:
            guard let ch = channelTarget(arg, m),
                  let (team, channel) = TeamsListPane.locate(ch, in: app.teams.teams),
                  app.teams.permission(.delete, teamID: team.teamId, channelID: ch).isAllowed else { return false }
            let teams = app.teams
            m.confirm(title: "Delete \u{201C}\(channel.name)\u{201D}?",
                      message: "The channel and its conversations are deleted for everyone in \(team.name).",
                      action: "Delete",
                      perform: { Task { await teams.deleteChannel(teamID: team.teamId, channelID: ch) } })
        case TeamsCommands.openChannelWindow:
            guard let ch = channelTarget(arg, m),
                  let (team, channel) = TeamsListPane.locate(ch, in: app.teams.teams) else { return false }
            ChannelWindowController.show(m, team: team, channel: channel)
        case TeamsCommands.moveChannelToSection:
            // arg = "<sectionID|none>" (menu bar) or "<sectionID|none>|<channel>" (row menu).
            let parts = (arg ?? "").split(separator: "|", maxSplits: 1).map(String.init)
            guard let target = parts.first, !target.isEmpty,
                  let ch = channelTarget(parts.count > 1 ? parts[1] : nil, m) else { return false }
            m.graph.chats.folders.assign(chatID: ch, folderID: target == "none" ? nil : target)
        case TeamsCommands.channelWorkflows:
            guard channelTarget(arg, m) != nil else { return false }
            // Teams' Workflows are Power Automate flows; that site is the entry.
            if !m.options.demo, let url = Self.workflowsURL { NSWorkspace.shared.open(url) }
        case TeamsCommands.hideTeam:
            guard let team = teamTarget(arg, m) else { return false }
            prefs(m).setHidden(team, !prefs(m).isHidden(team))
        case TeamsCommands.teamLink:
            guard let team = teamTarget(arg, m), let link = Self.teamLink(teamID: team, teams: app.teams.teams) else {
                return false
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        case TeamsCommands.leaveTeam:
            guard let id = teamTarget(arg, m), let team = app.teams.teams.first(where: { $0.teamId == id }) else {
                return false
            }
            let teams = app.teams
            m.confirm(title: "Leave \u{201C}\(team.name)\u{201D}?",
                      message: "You'll lose access to its channels until someone adds you back.",
                      action: "Leave",
                      perform: { Task { await teams.leaveTeam(teamID: id) } })
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard m.app != nil else { return .disabled }
        let ch = channelTarget(arg, m)
        let team = teamTarget(arg, m)
        switch c {
        // Joining and creating need the service: off while offline.
        case TeamsCommands.joinOrCreate: return CommandValidation(enabled: m.connection != .offline)
        case TeamsCommands.createChannel:
            return CommandValidation(enabled: team != nil && m.connection != .offline)
        case TeamsCommands.manageMembers, TeamsCommands.markTeamRead:
            return CommandValidation(enabled: team != nil)
        case TeamsCommands.markChannelRead, TeamsCommands.notifications, TeamsCommands.copyLink:
            return CommandValidation(enabled: ch != nil)
        case TeamsCommands.pinChannel:
            guard let ch else { return .disabled }
            return CommandValidation(enabled: true, title: prefs(m).isPinned(ch) ? "Unpin Channel" : "Pin Channel")
        case TeamsCommands.hideChannel:
            guard let ch else { return .disabled }
            return CommandValidation(enabled: true, title: prefs(m).isHidden(ch) ? "Show Channel" : "Hide Channel")
        case TeamsCommands.manageChannel:
            return CommandValidation(enabled: ch != nil)
        case TeamsCommands.channelEmail:
            let email = ch.flatMap { TeamsListPane.locate($0, in: m.app?.teams.teams ?? [])?.1.email }
            return CommandValidation(enabled: !(email ?? "").isEmpty)
        case TeamsCommands.editChannel, TeamsCommands.deleteChannel:
            guard let ch, let team = TeamsListPane.locate(ch, in: m.app?.teams.teams ?? [])?.0,
                  let teams = m.app?.teams else { return .disabled }
            let allowed = teams.permission(c == TeamsCommands.editChannel ? .edit : .delete,
                                           teamID: team.teamId, channelID: ch).isAllowed
            return CommandValidation(enabled: allowed && m.connection != .offline)
        case TeamsCommands.openChannelWindow, TeamsCommands.channelWorkflows:
            return CommandValidation(enabled: ch != nil)
        case TeamsCommands.moveChannelToSection:
            return CommandValidation(enabled: ch != nil && !m.graph.chats.folders.folders.isEmpty)
        case TeamsCommands.hideTeam:
            guard let team else { return .disabled }
            return CommandValidation(enabled: true, title: prefs(m).isHidden(team) ? "Show Team" : "Hide Team")
        case TeamsCommands.teamLink:
            return CommandValidation(enabled: team != nil)
        case TeamsCommands.leaveTeam:
            return CommandValidation(enabled: team != nil && m.connection != .offline)
        default:
            return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        switch c {
        case TeamsCommands.joinOrCreate:
            return [SubmenuItem("Join a Team…", arg: TeamsCommands.joinArg, symbol: "person.badge.plus"),
                    SubmenuItem("Create Team…", arg: TeamsCommands.createArg, symbol: "plus")]
        case TeamsCommands.notifications:
            guard let ch = channelTarget(nil, m) else {
                return ChatNotifyLevel.allCases.map { SubmenuItem(Self.levelTitle($0), arg: $0.rawValue, enabled: false) }
            }
            let current = prefs(m).level(ch)
            return ChatNotifyLevel.allCases.map {
                SubmenuItem(Self.levelTitle($0), arg: $0.rawValue, checked: $0 == current)
            }
        case TeamsCommands.moveChannelToSection:
            let folders = m.graph.chats.folders
            guard let ch = channelTarget(nil, m) else {
                return folders.folders.map { SubmenuItem($0.name, arg: $0.id, symbol: "folder", enabled: false) }
            }
            let current = folders.overrides[ch]
            var out = folders.folders.map { SubmenuItem($0.name, arg: $0.id, symbol: "folder", checked: current == $0.id) }
            if current != nil { out.append(SubmenuItem("Remove from Section", arg: "none", separatorBefore: true)) }
            return out
        default:
            return []
        }
    }

    /// Power Automate: where channel workflows are made.
    static let workflowsURL = URL(string: "https://make.powerautomate.com/")

    // MARK: ⌥⌘1–3 (View ▸ Posts / Files / Notes in Teams)

    static func channelTab(for command: CommandID) -> ChannelTabKey {
        switch command {
        case ShellCommand.tabFiles: .files
        case ShellCommand.tabNotes: .notes
        default: .posts
        }
    }

    static func channelTabTitle(_ t: ChannelTabKey) -> String {
        switch t {
        case .posts: "Posts"
        case .files: "Files"
        case .notes: "Notes"
        case .web: "Web"
        }
    }

    /// The open channel's tab, nil without a channel on screen.
    func channelTab(_ m: WindowModel) -> ChannelTabKey? {
        guard m.forced(.teams) == nil, let s = current(m), s.channelID != nil else { return nil }
        return s.tab
    }

    func selectChannelTab(_ t: ChannelTabKey, _ m: WindowModel) {
        guard m.forced(.teams) == nil, var s = current(m), s.channelID != nil, s.tab != t else { return }
        s.tab = t
        m.navigator?.select(s.selection, in: .teams)
    }

    // MARK: helpers (pure)

    static func levelTitle(_ l: ChatNotifyLevel) -> String {
        switch l {
        case .all: "All Activity"
        case .mentions: "Mentions Only"
        case .muted: "Off"
        }
    }

    static func channelIDs(_ teams: [TeamItem]) -> [String] {
        teams.flatMap { $0.channels.map(\.channelId) }
    }

    func channelName(_ id: String, _ teams: [TeamItem]) -> String? {
        for t in teams {
            if let ch = t.channels.first(where: { $0.channelId == id }) {
                return TeamsViewModel.channelDisplayName(team: t.name, channel: ch.name)
            }
        }
        return nil
    }

    /// Team link: the Teams deep-link form on the team's General
    /// channel (`/l/team/<general>/conversations?groupId=<team>`).
    static func teamLink(teamID: String, teams: [TeamItem]) -> String? {
        guard let t = teams.first(where: { $0.teamId == teamID }),
              let general = t.channels.first(where: { $0.name == "General" }) ?? t.channels.first else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":@/"))
        let id = general.channelId.addingPercentEncoding(withAllowedCharacters: allowed) ?? general.channelId
        let team = t.teamId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t.teamId
        return "https://teams.microsoft.com/l/team/\(id)/conversations?groupId=\(team)"
    }

    /// Channel link: the Graph `webUrl` when present, else the Teams
    /// deep-link form (`/l/channel/<id>/<name>?groupId=<team>`).
    static func link(channelID: String, teams: [TeamItem]) -> String? {
        for t in teams {
            guard let ch = t.channels.first(where: { $0.channelId == channelID }) else { continue }
            if let url = ch.webUrl, !url.isEmpty { return url }
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":@/"))
            let id = channelID.addingPercentEncoding(withAllowedCharacters: allowed) ?? channelID
            let name = ch.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ch.name
            let team = t.teamId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t.teamId
            return "https://teams.microsoft.com/l/channel/\(id)/\(name)?groupId=\(team)"
        }
        return nil
    }
}
