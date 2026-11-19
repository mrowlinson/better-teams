// TeamsSheets.swift — Create Team, Join a Team, Create Channel, Add
// Member (UI-SPEC §6.3, §9.5). Presented by SheetPresenter as window
// sheets; Cancel + a default action, never a lone Done. Work runs in
// the core view models (demo: in-memory fetchers).
import AppKit
import OstMacCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared sheet frame: title, content, error line, Cancel + action.
private struct TeamsSheetFrame<Content: View>: View {
    let title: String
    let action: String
    let enabled: Bool
    let busy: String?
    let error: String?
    let perform: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.windowModel) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
            // Status (progress or error, never both) shares the button
            // row, leading, as in stock dialogs: no reserved empty line
            // above the buttons, and nothing moves when it appears.
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    if let busy {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary)
                    } else if let error {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                        Text(error).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                // A real spacer: the status stack is empty when idle, and a
                // frame on empty content does not render, which pinned the
                // buttons leading. Buttons trail (HIG).
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button(action, action: perform)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled || busy != nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Field prompt in the system placeholder color, so a prompt never
/// reads as a typed value in dark sheets (§10).
private func prompt(_ s: String) -> Text {
    Text(s).foregroundStyle(Color(nsColor: .placeholderTextColor))
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

struct CreateTeamSheet: View {
    @ObservedObject var teams: TeamsViewModel
    @State private var name = ""
    @State private var about = ""
    @State private var submitted = false
    @Environment(\.windowModel) private var model

    var body: some View {
        TeamsSheetFrame(title: "Create Team", action: "Create", enabled: !trimmed(name).isEmpty,
                        busy: teams.teamCreating ? "Creating team… This can take up to two minutes." : nil,
                        error: submitted ? teams.teamCreateError : nil, perform: create) {
            Form {
                TextField("Name", text: $name, prompt: prompt("Team name"))
                TextField("Description", text: $about, prompt: prompt("Optional"), axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                InfoButton(subject: "the new team",
                           text: "A standard team with a General channel. You\u{2019}re its owner.")
            }
        }
    }

    private func create() {
        let n = trimmed(name)
        let d = trimmed(about)
        submitted = true
        Task { @MainActor in
            await teams.createTeam(name: n, description: d.isEmpty ? nil : d)
            guard teams.teamCreateError == nil, let team = teams.teams.last(where: { $0.name == n }) else { return }
            model?.dismissSheet()
            model?.navigator?.select(section: .teams)
            model?.navigator?.select(TeamsSelection(teamID: team.teamId).selection, in: .teams)
        }
    }
}

/// Join a Team (§6.3): search public teams by name (core-b
/// `TeamsViewModel.searchPublic`), or join with a code or team ID.
struct JoinTeamSheet: View {
    /// The results list's pane state (pure; unit-tested).
    enum SearchState: Equatable {
        case prompt, loading, results, empty, error(String)
    }

    @ObservedObject var teams: TeamsViewModel
    /// Evidence only (demo routes, `search=loading|error`).
    let forced: ForcedPaneState?
    @State private var query: String
    @State private var picked: String?
    @State private var code = ""
    @State private var submitted = false
    @State private var debounce = Debounce(milliseconds: 250)
    @Environment(\.windowModel) private var model

    init(teams: TeamsViewModel, query: String = "", forced: ForcedPaneState? = nil) {
        self.teams = teams
        self.forced = forced
        _query = State(initialValue: query)
    }

    static let errorTitle = "Couldn't Search Teams"
    static let forcedErrorMessage = "The server didn't respond. Check your connection and try again."

    static func state(_ teams: TeamsViewModel, forced: ForcedPaneState? = nil) -> SearchState {
        switch forced {
        case .loading: return .loading
        case .error: return .error(forcedErrorMessage)
        default: break
        }
        if !teams.publicResults.isEmpty { return .results }
        if teams.publicSearching { return .loading }
        if let e = teams.publicSearchError { return .error(e) }
        return teams.publicQuery.isEmpty ? .prompt : .empty
    }

    private var pickedTeam: PublicTeam? { picked.flatMap { id in teams.publicResults.first { $0.id == id } } }
    private var target: String { picked ?? trimmed(code) }
    private var canJoin: Bool { !target.isEmpty && !(pickedTeam.map(teams.isMember) ?? false) }

    var body: some View {
        TeamsSheetFrame(title: "Join a Team", action: "Join", enabled: canJoin,
                        busy: teams.joiningIDs.isEmpty ? nil : "Joining…",
                        error: submitted ? teams.joinError : nil, perform: join) {
            SearchField(text: $query, placeholder: "Search Public Teams", onSubmit: searchNow)
                .frame(height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text("Public Teams")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                List(selection: $picked) {
                    if forced == nil {
                        ForEach(teams.publicResults) { t in row(t).tag(t.id) }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 200)
                .overlay { overlay }
            }
            Form {
                TextField("Code or ID", text: $code, prompt: prompt("Team code or ID"))
                    .onChange(of: code) { _, v in if !trimmed(v).isEmpty { picked = nil } }
            }
            .formStyle(.columns)
        }
        .onAppear {
            teams.clearPublicSearch()
            if !trimmed(query).isEmpty { searchNow() }
        }
        .onDisappear {
            debounce.cancel()
            teams.clearPublicSearch()
        }
        .onChange(of: query) { _, q in
            picked = nil
            debounce.schedule { Task { await teams.searchPublic(query: q) } }
        }
        .onChange(of: picked) { _, v in if v != nil { code = "" } }
    }

    private func row(_ t: PublicTeam) -> some View {
        HStack(spacing: 8) {
            TeamTile(name: t.name)
            VStack(alignment: .leading, spacing: 0) {
                Text(t.name)
                if let d = t.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if teams.isMember(t) {
                Text("Joined").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var overlay: some View {
        switch Self.state(teams, forced: forced) {
        case .results: EmptyView()
        case .loading: LoadingPane("Searching Teams\u{2026}")
        case .error(let message): ErrorPane(title: Self.errorTitle, message: message, retry: searchNow)
        case .empty:
            EmptyPane("No Teams Found", systemImage: "magnifyingglass",
                      message: "Check the spelling, or join with a code or team ID below.")
        case .prompt:
            EmptyPane("Search Public Teams", systemImage: "person.3",
                      message: "Find a team by name, or join with a code or team ID below.")
        }
    }

    private func searchNow() {
        debounce.cancel()
        let q = query
        Task { await teams.searchPublic(query: q) }
    }

    private func join() {
        let id = target
        let hit = pickedTeam
        submitted = true
        Task { @MainActor in
            if let hit { await teams.join(publicTeam: hit) } else { await teams.join(teamID: id) }
            guard teams.joinError == nil else { return }
            model?.dismissSheet()
            if teams.teams.contains(where: { $0.teamId == id }) {
                model?.navigator?.select(section: .teams)
                model?.navigator?.select(TeamsSelection(teamID: id).selection, in: .teams)
            }
        }
    }
}

struct CreateChannelSheet: View {
    @ObservedObject var teams: TeamsViewModel
    @State var teamID: String
    @State private var name = ""
    @State private var about = ""
    @State private var kind = ChannelKind.standard
    @State private var creating = false
    @State private var submitted = false
    @Environment(\.windowModel) private var model

    /// Channel membership type for the create sheet (native segmented
    /// picker; private/shared make the caller the owner).
    enum ChannelKind: String, CaseIterable, Identifiable {
        case standard = "Standard", privateChannel = "Private", shared = "Shared"
        var id: String { rawValue }
        /// Graph `membershipType` (nil = standard default).
        var membershipType: String? {
            switch self {
            case .standard: return nil
            case .privateChannel: return "private"
            case .shared: return "shared"
            }
        }
    }

    init(teams: TeamsViewModel, teamID: String) {
        self.teams = teams
        _teamID = State(initialValue: teamID)
    }

    var body: some View {
        TeamsSheetFrame(title: "Create Channel", action: "Create",
                        enabled: !trimmed(name).isEmpty && teams.teams.contains { $0.teamId == teamID },
                        busy: creating ? "Creating channel…" : nil,
                        error: submitted ? teams.createError : nil, perform: create) {
            Form {
                Picker("Team", selection: $teamID) {
                    ForEach(teams.teams) { t in Text(t.name).tag(t.teamId) }
                }
                TextField("Name", text: $name, prompt: prompt("Channel name"))
                TextField("Description", text: $about, prompt: prompt("Optional"), axis: .vertical)
                    .lineLimit(2...4)
                Picker("Type", selection: $kind) {
                    ForEach(ChannelKind.allCases) { k in Text(k.rawValue).tag(k) }
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.columns)
            if kind != .standard {
                HStack {
                    Spacer()
                    InfoButton(subject: "a \(kind.rawValue.lowercased()) channel",
                               text: "Only its members can see it. You become its owner.")
                }
            }
        }
    }

    private func create() {
        let n = trimmed(name)
        let d = trimmed(about)
        let team = teamID
        let kind = kind
        submitted = true
        creating = true
        Task { @MainActor in
            await teams.createChannel(teamID: team, name: n, description: d.isEmpty ? nil : d,
                                      membershipType: kind.membershipType)
            creating = false
            guard teams.createError == nil,
                  let ch = teams.teams.first(where: { $0.teamId == team })?.channels.last(where: { $0.name == n })
            else { return }
            model?.dismissSheet()
            model?.navigator?.select(section: .teams)
            model?.navigator?.select(TeamsSelection(teamID: team, channelID: ch.channelId).selection, in: .teams)
        }
    }
}

/// Edit channel (TEAMSYNC + TEAMMOD moderation): rename and re-describe
/// one channel, plus who can post/reply. The row changes at once; a
/// failed save rolls back and shows the error.
struct EditChannelSheet: View {
    @ObservedObject var teams: TeamsViewModel
    let channelID: String
    let roster: (String) -> TeamRosterViewModel

    var body: some View {
        // The sheet can open before the list loads (launch routes): the
        // form appears once the channel resolves, seeded from it.
        if let (team, ch) = TeamsListPane.locate(channelID, in: teams.teams) {
            EditChannelForm(teams: teams, roster: roster(team.teamId), teamID: team.teamId, channel: ch)
        } else {
            TeamsSheetFrame(title: "Edit Channel", action: "Save", enabled: false,
                            busy: teams.state == .loading ? "Loading…" : nil,
                            error: teams.state == .loading ? nil : "This channel is no longer available.",
                            perform: {}) {
                // Same fields, disabled, so the sheet keeps its size.
                Form {
                    TextField("Name", text: .constant(""), prompt: prompt("Channel name"))
                    TextField("Description", text: .constant(""), prompt: prompt("Optional"), axis: .vertical)
                        .lineLimit(2...4)
                }
                .formStyle(.columns)
                .disabled(true)
            }
        }
    }
}

private struct EditChannelForm: View {
    @ObservedObject var teams: TeamsViewModel
    @ObservedObject var roster: TeamRosterViewModel
    let teamID: String
    let channel: TeamChannel
    /// Moderation the pickers were seeded from (pre-fetch snapshot).
    private let seeded: ChannelModeration
    @State private var name: String
    @State private var about: String
    @State private var posts: WhoCanPost
    @State private var replies: WhoCanReply
    @State private var saving = false
    @State private var submitted = false
    @Environment(\.windowModel) private var model

    init(teams: TeamsViewModel, roster: TeamRosterViewModel, teamID: String, channel: TeamChannel) {
        self.teams = teams
        self.roster = roster
        self.teamID = teamID
        self.channel = channel
        _name = State(initialValue: channel.name)
        _about = State(initialValue: channel.description ?? "")
        let key = TeamsViewModel.moderationKey(teamID: teamID, channelID: channel.channelId)
        let current = teams.moderation[key] ?? ChannelModeration()
        seeded = current
        _posts = State(initialValue: current.posts)
        _replies = State(initialValue: current.replies)
    }

    private var changed: Bool {
        (trimmed(name) != channel.name && !trimmed(name).isEmpty)
            || trimmed(about) != (channel.description ?? "")
            || moderationChanged
    }

    private var moderationKey: String {
        TeamsViewModel.moderationKey(teamID: teamID, channelID: channel.channelId)
    }

    private var moderationChanged: Bool {
        let current = teams.moderation[moderationKey] ?? ChannelModeration()
        return posts != current.posts || replies != current.replies
    }

    private var canModerate: Bool { teams.canEditModeration(teamID: teamID) }

    var body: some View {
        TeamsSheetFrame(title: "Edit Channel", action: "Save",
                        enabled: changed && !trimmed(name).isEmpty && model?.connection != .offline,
                        busy: saving ? "Saving…" : nil,
                        error: submitted ? teams.actionError : nil, perform: save) {
            Form {
                TextField("Name", text: $name, prompt: prompt("Channel name"))
                TextField("Description", text: $about, prompt: prompt("Optional"), axis: .vertical)
                    .lineLimit(2...4)
                Section("Moderation") {
                    if canModerate {
                        Picker("Who can post", selection: $posts) {
                            ForEach(WhoCanPost.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Who can post")
                        Picker("Who can reply", selection: $replies) {
                            ForEach(WhoCanReply.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Who can reply")
                        if posts == .moderators {
                            moderatorList
                        }
                    } else {
                        Text("Only team owners can change moderation settings.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.columns)
        }
        .task {
            await teams.refreshModeration(teamID: teamID, channelID: channel.channelId)
            // The pickers seed before the read lands: adopt the read
            // unless the user already touched a picker.
            let fresh = teams.moderation[moderationKey] ?? ChannelModeration()
            if posts == seeded.posts && replies == seeded.replies {
                posts = fresh.posts
                replies = fresh.replies
            }
        }
        .onAppear {
            if roster.members.isEmpty { roster.refresh() }
        }
    }

    /// The mod list: team owners (implicit moderators) from the roster.
    @ViewBuilder
    private var moderatorList: some View {
        let owners = TeamRosterViewModel.owners(of: roster.members)
        if owners.isEmpty {
            Text("Loading moderators…").foregroundStyle(.secondary)
        } else {
            ForEach(owners) { m in
                Text(TeamRosterViewModel.displayName(for: m, names: roster.names))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let n = trimmed(name)
        let d = trimmed(about)
        let newName = n == channel.name ? nil : n
        let newAbout = d == (channel.description ?? "") ? nil : d
        let id = channel.channelId
        let current = teams.moderation[moderationKey] ?? ChannelModeration()
        let newPosts: WhoCanPost? = (canModerate && posts != current.posts) ? posts : nil
        let newReplies: WhoCanReply? = (canModerate && replies != current.replies) ? replies : nil
        submitted = true
        saving = true
        Task { @MainActor in
            var ok = await teams.updateChannel(teamID: teamID, channelID: id, name: newName, description: newAbout)
            if newPosts != nil || newReplies != nil {
                ok = await teams.updateModeration(teamID: teamID, channelID: id,
                                                  posts: newPosts, replies: newReplies) && ok
            }
            saving = false
            if ok { model?.dismissSheet() }
        }
    }
}

/// Edit team (TEAM-ADMIN): rename, re-describe and change the picture
/// of one team. The row changes at once; a failed save rolls back and
/// shows the error. Owner-only: anyone else sees the reason, never the
/// controls.
struct EditTeamSheet: View {
    @ObservedObject var teams: TeamsViewModel
    let teamID: String

    var body: some View {
        // The sheet can open before the list loads (launch routes): the
        // form appears once the team resolves, seeded from it.
        if let team = teams.teams.first(where: { $0.teamId == teamID }) {
            EditTeamForm(teams: teams, team: team)
        } else {
            TeamsSheetFrame(title: "Edit Team", action: "Save", enabled: false,
                            busy: teams.state == .loading ? "Loading…" : nil,
                            error: teams.state == .loading ? nil : "This team is no longer available.",
                            perform: {}) {
                // Same fields, disabled, so the sheet keeps its size.
                Form {
                    TextField("Name", text: .constant(""), prompt: prompt("Team name"))
                    TextField("Description", text: .constant(""), prompt: prompt("Optional"), axis: .vertical)
                        .lineLimit(2...4)
                }
                .formStyle(.columns)
                .disabled(true)
            }
        }
    }
}

private struct EditTeamForm: View {
    @ObservedObject var teams: TeamsViewModel
    let team: TeamItem
    @State private var name: String
    @State private var about: String
    @State private var photoData: Data?
    @State private var photoName: String?
    @State private var pickingPhoto = false
    @State private var saving = false
    @State private var submitted = false
    @Environment(\.windowModel) private var model

    init(teams: TeamsViewModel, team: TeamItem) {
        self.teams = teams
        self.team = team
        _name = State(initialValue: team.name)
        _about = State(initialValue: team.description ?? "")
    }

    /// Graph photo cap (4 MB); the picker rejects bigger files up front.
    private static let maxPhotoBytes = 4 * 1024 * 1024

    private var changed: Bool {
        (trimmed(name) != team.name && !trimmed(name).isEmpty)
            || trimmed(about) != (team.description ?? "")
            || photoData != nil
    }

    private var canAdmin: Bool { teams.canAdminTeam(teamID: team.teamId) }

    var body: some View {
        TeamsSheetFrame(title: "Edit Team", action: "Save",
                        enabled: canAdmin && changed && !trimmed(name).isEmpty && model?.connection != .offline,
                        busy: saving ? "Saving…" : nil,
                        error: submitted ? teams.actionError : nil, perform: save) {
            Form {
                TextField("Name", text: $name, prompt: prompt("Team name"))
                TextField("Description", text: $about, prompt: prompt("Optional"), axis: .vertical)
                    .lineLimit(2...4)
                Section("Picture") {
                    if canAdmin {
                        HStack(spacing: 8) {
                            TeamTile(name: trimmed(name).isEmpty ? team.name : trimmed(name), size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                if let photoName {
                                    Text(photoName).lineLimit(1)
                                } else {
                                    Text("No new picture chosen").foregroundStyle(.secondary)
                                }
                                Text("Shows in official clients; this app's tile keeps initials.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Choose…") { pickingPhoto = true }
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Text("Only team owners can edit the team.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.columns)
        }
        .fileImporter(isPresented: $pickingPhoto, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                guard let data = try? Data(contentsOf: url),
                      !data.isEmpty, data.count <= Self.maxPhotoBytes,
                      NSImage(data: data) != nil else {
                    teams.clearActionError()
                    return
                }
                photoData = data
                photoName = url.lastPathComponent
            case .failure:
                break
            }
        }
    }

    private func save() {
        let n = trimmed(name)
        let d = trimmed(about)
        let newName = n == team.name ? nil : n
        let newAbout = d == (team.description ?? "") ? nil : d
        let photo = photoData
        let id = team.teamId
        submitted = true
        saving = true
        Task { @MainActor in
            var ok = true
            if newName != nil || newAbout != nil {
                ok = await teams.updateTeam(teamID: id, name: newName, description: newAbout) && ok
            }
            if let photo, ok {
                ok = await teams.setTeamPhoto(teamID: id, base64: photo.base64EncodedString()) && ok
                if ok { photoData = nil }
            }
            saving = false
            if ok { model?.dismissSheet() }
        }
    }
}

struct AddMemberSheet: View {
    @ObservedObject var roster: TeamRosterViewModel
    @State private var user = ""
    @State private var owner = false
    @State private var adding = false
    @Environment(\.windowModel) private var model

    var body: some View {
        TeamsSheetFrame(title: "Add Member", action: "Add", enabled: !trimmed(user).isEmpty,
                        busy: adding ? "Adding…" : nil, error: errorText, perform: add) {
            Form {
                TextField("Person", text: $user, prompt: prompt("Email or user ID"))
                Toggle("Make owner", isOn: $owner)
            }
            .formStyle(.columns)
        }
    }

    private var errorText: String? {
        if case .error(let msg) = roster.state, !adding { return msg }
        return nil
    }

    private func add() {
        let u = trimmed(user)
        adding = true
        Task { @MainActor in
            await roster.add(user: u, owner: owner)
            adding = false
            if case .error = roster.state { return }
            model?.dismissSheet()
        }
    }
}

/// Manage a private/shared channel: its own roster with Add/Remove.
/// Standard channels share the team roster (Manage Members… instead).
struct ChannelMembersSheet: View {
    @ObservedObject var roster: ChannelMembersViewModel
    @State private var user = ""
    @State private var owner = false
    @State private var adding = false

    var body: some View {
        TeamsSheetFrame(title: "Manage Channel", action: "Add", enabled: !trimmed(user).isEmpty,
                        busy: adding ? "Adding…" : nil, error: errorText, perform: add) {
            Form {
                TextField("Person", text: $user, prompt: prompt("Email or user ID"))
                Toggle("Make owner", isOn: $owner)
            }
            .formStyle(.columns)
            rosterList
        }
        .task { await roster.load() }
    }

    @ViewBuilder
    private var rosterList: some View {
        switch roster.state {
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading members…").foregroundStyle(.secondary) }
                .font(.caption)
        case .empty:
            Text("No other members yet.").foregroundStyle(.secondary).font(.caption)
        case .error(let msg):
            Text(msg).foregroundStyle(.secondary).font(.caption)
        case .loaded:
            let rows = ChannelMembersViewModel.sorted(roster.members)
            let owners = rows.filter(\.isOwner)
            let members = rows.filter { !$0.isOwner }
            VStack(alignment: .leading, spacing: 4) {
                if !owners.isEmpty {
                    Text("Owners (\(owners.count))").font(.caption).foregroundStyle(.secondary)
                    ForEach(owners) { memberRow($0) }
                }
                if !members.isEmpty {
                    Text("Members (\(members.count))").font(.caption).foregroundStyle(.secondary)
                    ForEach(members) { memberRow($0) }
                }
            }
        }
    }

    private func memberRow(_ m: ChannelMember) -> some View {
        HStack {
            Text(ChannelMembersViewModel.displayName(for: m)).lineLimit(1)
            Spacer()
            Button("Remove") {
                Task { @MainActor in await roster.remove(memberID: m.id) }
            }
            .buttonStyle(.link)
            .accessibilityLabel("Remove \(ChannelMembersViewModel.displayName(for: m))")
        }
        .font(.caption)
    }

    private var errorText: String? {
        if case .error(let msg) = roster.state, !adding { return msg }
        return nil
    }

    private func add() {
        let u = trimmed(user)
        let makeOwner = owner
        adding = true
        Task { @MainActor in
            await roster.add(user: u, owner: makeOwner)
            adding = false
            if case .error = roster.state { return }
            user = ""
            owner = false
        }
    }
}
