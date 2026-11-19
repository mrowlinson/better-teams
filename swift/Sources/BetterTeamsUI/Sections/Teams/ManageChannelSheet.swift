// ManageChannelSheet.swift — Manage Channel (FIXPACK-UI R2): one native
// grouped form with the channel's details, your notification level and
// list placement, and what you may do to it. Explanations live in (i)
// popovers only. Every control works or is absent; nothing is faked.
import OstMacCore
import SwiftUI

/// Pure wording for the sheet (tested).
enum ManageChannelInfo {
    /// Channel type row from Graph's `membershipType`.
    static func typeTitle(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "private": "Private"
        case "shared": "Shared"
        default: "Standard"
        }
    }

    /// Who is in the channel, from its type.
    static func audience(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "private": "Selected team members"
        case "shared": "Selected people and teams"
        default: "All team members"
        }
    }

    /// Moderation editor state: nil = editable, else the disabled
    /// reason to show. General first: the service forbids it even
    /// for owners.
    static func moderationReason(isGeneral: Bool, canEdit: Bool) -> String? {
        if isGeneral {
            return "The General channel's moderation can't be changed (Teams allows it only on standard channels)."
        }
        if !canEdit {
            return "Only team owners can change moderation settings."
        }
        return nil
    }
}

struct ManageChannelSheet: View {
    @ObservedObject var teams: TeamsViewModel
    @ObservedObject var prefs: ChannelPrefs
    @ObservedObject var folders: FolderStore
    let channelID: String
    @Environment(\.windowModel) private var model
    @State private var posts = WhoCanPost.everyone
    @State private var replies = WhoCanReply.everyone
    @State private var modTouched = false
    @State private var modError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let (team, ch) = TeamsListPane.locate(channelID, in: teams.teams) {
                header(team: team, channel: ch)
                Divider()
                ScrollViewReader { proxy in
                    form(team: team, channel: ch)
                        .onAppear {
                            // Evidence-only (?scroll=moderation): captures
                            // need the section on screen; demo never
                            // scrolls otherwise.
                            if model?.options.demo == true, model?.options.evidence == true,
                               model?.options.route.flatMap(Route.init(string:))?.query["scroll"] == "moderation" {
                                DispatchQueue.main.async {
                                    proxy.scrollTo("moderation", anchor: .top)
                                }
                            }
                        }
                }
            } else {
                ContentUnavailableView("Channel Not Available", systemImage: "number",
                                       description: Text(teams.state == .loading ? "Loading\u{2026}" : "This channel is no longer available."))
                    .frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model?.dismissSheet() }
                    .keyboardShortcut(.defaultAction)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
        .task { await teams.refreshOwnership() }
        .task(id: channelID) { await seedModeration() }
    }

    /// Seed the moderation pickers from the read (unless the user
    /// already touched one).
    private func seedModeration() async {
        guard let (team, _) = TeamsListPane.locate(channelID, in: teams.teams) else { return }
        await teams.refreshModeration(teamID: team.teamId, channelID: channelID)
        guard !modTouched else { return }
        let fresh = teams.moderation[TeamsViewModel.moderationKey(teamID: team.teamId, channelID: channelID)]
            ?? ChannelModeration()
        posts = fresh.posts
        replies = fresh.replies
    }

    private func header(team: TeamItem, channel: TeamChannel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Manage Channel").font(.headline)
            Text("\(channel.name) \u{2022} \(team.name)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func form(team: TeamItem, channel: TeamChannel) -> some View {
        Form {
            Section("Channel") {
                LabeledContent("Name", value: channel.name)
                if let about = channel.description, !about.isEmpty {
                    LabeledContent("Description", value: about)
                }
                LabeledContent("Type") {
                    HStack(spacing: 6) {
                        Text(ManageChannelInfo.typeTitle(channel.membershipType))
                        InfoButton(subject: "Channel Type",
                                   text: "Standard channels are open to the whole team. Private and shared channels have their own members.")
                    }
                }
                LabeledContent("Members", value: ManageChannelInfo.audience(channel.membershipType))
                if let email = channel.email, !email.isEmpty {
                    LabeledContent("Email Address") {
                        HStack(spacing: 8) {
                            Text(email).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Button("Copy") { run(TeamsCommands.channelEmail) }
                        }
                    }
                }
                if channel.webUrl != nil {
                    LabeledContent("Link") {
                        Button("Copy Link") { run(TeamsCommands.copyLink) }
                    }
                }
            }
            Section("Notifications") {
                Picker("Notify me", selection: Binding(get: { prefs.level(channelID) },
                                                       set: { prefs.setLevel(channelID, $0) })) {
                    ForEach(ChatNotifyLevel.allCases, id: \.rawValue) { l in
                        Text(TeamsSection.levelTitle(l)).tag(l)
                    }
                }
                Button("Mark Channel as Read") { run(TeamsCommands.markChannelRead) }
            }
            Section("In Your List") {
                Toggle("Pin to the Top", isOn: Binding(get: { prefs.isPinned(channelID) },
                                                        set: { prefs.setPinned(channelID, $0) }))
                Toggle("Hide Channel", isOn: Binding(get: { prefs.isHidden(channelID) },
                                                      set: { prefs.setHidden(channelID, $0) }))
                Picker("Section", selection: Binding(get: { folders.overrides[channelID].flatMap { id in folders.folders.contains { $0.id == id } ? id : nil } ?? "" },
                                                     set: { folders.assign(chatID: channelID, folderID: $0.isEmpty ? nil : $0) })) {
                    Text("None").tag("")
                    ForEach(folders.folders) { f in Text(f.name).tag(f.id) }
                }
            }
            Section("Permissions") {
                permissionRow("Edit Channel", .edit, team: team)
                permissionRow("Delete Channel", .delete, team: team)
            }
            Section("Moderation") {
                moderationRows(team: team, channel: channel)
            }
            .id("moderation")
            Section("Manage") {
                HStack(spacing: 10) {
                    Button("Edit\u{2026}") { after(TeamsCommands.editChannel) }
                        .disabled(!teams.permission(.edit, teamID: team.teamId, channelID: channelID).isAllowed)
                    Button("Workflows\u{2026}") { after(TeamsCommands.channelWorkflows) }
                    Button("Team Members\u{2026}") { after(TeamsCommands.manageMembers, arg: team.teamId) }
                    Spacer()
                    Button("Delete\u{2026}", role: .destructive) { after(TeamsCommands.deleteChannel) }
                        .disabled(!teams.permission(.delete, teamID: team.teamId, channelID: channelID).isAllowed)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Who can post/reply: immediate-apply pickers for owners of a
    /// standard channel; everyone else sees the read values disabled
    /// with the reason.
    private func moderationRows(team: TeamItem, channel: TeamChannel) -> some View {
        let reason = ManageChannelInfo.moderationReason(
            isGeneral: teams.isGeneral(teamID: team.teamId, channelID: channel.channelId),
            canEdit: teams.canEditModeration(teamID: team.teamId))
        return Group {
            Picker("Who can post", selection: Binding(get: { posts }, set: {
                posts = $0
                modTouched = true
                applyModeration(team: team, channel: channel)
            })) {
                ForEach(WhoCanPost.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(reason != nil)
            .accessibilityLabel("Who can post")
            Picker("Who can reply", selection: Binding(get: { replies }, set: {
                replies = $0
                modTouched = true
                applyModeration(team: team, channel: channel)
            })) {
                ForEach(WhoCanReply.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .disabled(reason != nil)
            .accessibilityLabel("Who can reply")
            if let reason {
                Text(reason).foregroundStyle(.secondary)
            }
            if let modError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                    Text(modError).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// This sheet has no Save: a picker change writes through the
    /// view model at once (which reverts its row on failure); the
    /// pickers revert here to match.
    private func applyModeration(team: TeamItem, channel: TeamChannel) {
        let key = TeamsViewModel.moderationKey(teamID: team.teamId, channelID: channel.channelId)
        let current = teams.moderation[key] ?? ChannelModeration()
        let newPosts: WhoCanPost? = posts != current.posts ? posts : nil
        let newReplies: WhoCanReply? = replies != current.replies ? replies : nil
        guard newPosts != nil || newReplies != nil else { modError = nil; return }
        modError = nil
        Task { @MainActor in
            let ok = await teams.updateModeration(teamID: team.teamId, channelID: channel.channelId,
                                                  posts: newPosts, replies: newReplies)
            if !ok {
                modError = teams.actionError ?? "Couldn't save moderation settings."
                let reverted = teams.moderation[key] ?? ChannelModeration()
                posts = reverted.posts
                replies = reverted.replies
            }
        }
    }

    private func permissionRow(_ title: String, _ action: ChannelAction, team: TeamItem) -> some View {
        let p = teams.permission(action, teamID: team.teamId, channelID: channelID)
        return LabeledContent(title) {
            HStack(spacing: 6) {
                Text(p.isAllowed ? "Allowed" : "Not Allowed").foregroundStyle(p.isAllowed ? .primary : .secondary)
                if let why = p.reason { InfoButton(subject: title, text: why) }
            }
        }
    }

    private func run(_ c: CommandID, arg: String? = nil) {
        guard let model else { return }
        _ = model.provider(.teams).perform(c, arg: arg ?? channelID, model)
    }

    /// Actions that open their own sheet or pane: close this one first.
    private func after(_ c: CommandID, arg: String? = nil) {
        guard let model else { return }
        let target = arg ?? channelID
        model.dismissSheet()
        DispatchQueue.main.async { _ = model.provider(.teams).perform(c, arg: target, model) }
    }
}
