// TeamsSheets.swift — Create Team, Join a Team, Create Channel, Add
// Member (UI-SPEC §6.3, §9.5). Presented by SheetPresenter as window
// sheets; Cancel + a default action, never a lone Done. Work runs in
// the core view models (demo: in-memory fetchers).
import OstMacCore
import SwiftUI

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
            Text("A standard team with a General channel. You're its owner.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    @State private var creating = false
    @State private var submitted = false
    @Environment(\.windowModel) private var model

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
            }
            .formStyle(.columns)
        }
    }

    private func create() {
        let n = trimmed(name)
        let d = trimmed(about)
        let team = teamID
        submitted = true
        creating = true
        Task { @MainActor in
            await teams.createChannel(teamID: team, name: n, description: d.isEmpty ? nil : d)
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

/// Edit channel (TEAMSYNC): rename and re-describe one channel. The
/// row changes at once; a failed save rolls back and shows the error.
struct EditChannelSheet: View {
    @ObservedObject var teams: TeamsViewModel
    let channelID: String

    var body: some View {
        // The sheet can open before the list loads (launch routes): the
        // form appears once the channel resolves, seeded from it.
        if let (team, ch) = TeamsListPane.locate(channelID, in: teams.teams) {
            EditChannelForm(teams: teams, teamID: team.teamId, channel: ch)
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
    let teamID: String
    let channel: TeamChannel
    @State private var name: String
    @State private var about: String
    @State private var saving = false
    @State private var submitted = false
    @Environment(\.windowModel) private var model

    init(teams: TeamsViewModel, teamID: String, channel: TeamChannel) {
        self.teams = teams
        self.teamID = teamID
        self.channel = channel
        _name = State(initialValue: channel.name)
        _about = State(initialValue: channel.description ?? "")
    }

    private var changed: Bool {
        (trimmed(name) != channel.name && !trimmed(name).isEmpty)
            || trimmed(about) != (channel.description ?? "")
    }

    var body: some View {
        TeamsSheetFrame(title: "Edit Channel", action: "Save",
                        enabled: changed && !trimmed(name).isEmpty,
                        busy: saving ? "Saving…" : nil,
                        error: submitted ? teams.actionError : nil, perform: save) {
            Form {
                TextField("Name", text: $name, prompt: prompt("Channel name"))
                TextField("Description", text: $about, prompt: prompt("Optional"), axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.columns)
        }
    }

    private func save() {
        let n = trimmed(name)
        let d = trimmed(about)
        let newName = n == channel.name ? nil : n
        let newAbout = d == (channel.description ?? "") ? nil : d
        let id = channel.channelId
        submitted = true
        saving = true
        Task { @MainActor in
            let ok = await teams.updateChannel(teamID: teamID, channelID: id, name: newName, description: newAbout)
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
