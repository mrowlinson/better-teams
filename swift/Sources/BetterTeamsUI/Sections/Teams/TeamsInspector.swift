// TeamsInspector.swift — Teams inspector (UI-SPEC §6.3, §5.6): the
// thread (root + replies, reply composer) when a post's thread is open,
// else the team (roster, owners first; owners get Add Member…, Remove).
// The thread reuses the conversation timeline in its Thread scope.
import OstMacCore
import SwiftUI

struct TeamsInspectorPane: View {
    @ObservedObject var teams: TeamsViewModel
    @ObservedObject var conv: ConversationStore
    let section: TeamsSection
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let sel = model.forced(.teams) == nil ? TeamsSelection(model.nav.selection(in: .teams)) : nil
            let team = sel.flatMap { s in teams.teams.first { $0.teamId == s.teamID } }
            if let sel, let team, let ch = sel.channelID, let root = sel.threadID {
                ThreadInspector(team: team, channelID: ch, rootID: root, sel: sel, conv: conv,
                                state: section.state(model))
            } else if let team {
                TeamInspector(team: team, roster: section.roster(team.teamId, model), conv: conv)
            } else {
                EmptyPane("No Team Selected", systemImage: "person.3")
            }
        }
    }
}

// MARK: thread

struct ThreadInspector: View {
    let team: TeamItem
    let channelID: String
    let rootID: String
    let sel: TeamsSelection
    @ObservedObject var conv: ConversationStore
    let state: TeamsSectionState
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        let loaded = conv.chatID == channelID && !(conv.loading && conv.messages.isEmpty)
        let threads = ChannelThreads(loaded ? conv.messages : [])
        let root = threads.roots.first { $0.id == rootID }
        let replies = threads.replies[rootID]?.count ?? 0
        let channel = team.channels.first { $0.channelId == channelID }?.name ?? "Channel"
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Thread").font(AppFont.headline(scale))
                    Text("#\(channel) · \(replies == 1 ? "1 reply" : "\(replies) replies")")
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            if !loaded {
                LoadingPane()
            } else if root == nil {
                EmptyPane("Post No Longer Available", systemImage: "exclamationmark.bubble",
                          message: "It may have been deleted, or it's older than the loaded history.")
            } else {
                TimelineRepresentable(conv: conv, scope: .thread(rootID: rootID))
                Divider()
                ThreadReplyComposer(rootID: rootID, conv: conv, state: state)
            }
        }
        // No close button of its own: the toolbar toggle / ⌥⌘I hides the
        // inspector (HIG). Esc deselects the post (Team inspector again).
        .onExitCommand {
            var s = sel
            s.threadID = nil
            model?.navigator?.select(s.selection, in: .teams)
        }
    }
}

/// Reply composer for one thread: the conversation composer's text view
/// (IME-safe Return, ⇧Return newline) + Send. Posts through the store's
/// reply path with the thread root armed, then restores any reply the
/// main composer had armed.
struct ThreadReplyComposer: View {
    let rootID: String
    @ObservedObject var conv: ConversationStore
    let state: TeamsSectionState
    @State private var fieldHeight: CGFloat = 18
    @Environment(\.contentTextScale) private var scale

    private var draft: Binding<String> {
        Binding(get: { state.replyDrafts[rootID] ?? "" }, set: { state.replyDrafts[rootID] = $0 })
    }

    private var canSend: Bool {
        !(state.replyDrafts[rootID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(text: draft, height: $fieldHeight, focusRequest: 0, scale: scale,
                             onSubmit: send, onCommand: { _ in false }, onPasteFiles: { _ in })
                .frame(height: fieldHeight)
                .overlay(alignment: .topLeading) {
                    if (state.replyDrafts[rootID] ?? "").isEmpty {
                        Text("Reply")
                            .font(AppFont.body(scale))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 1)
                }
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .disabled(!canSend)
            .help("Send Reply")
            .accessibilityLabel("Send Reply")
            .padding(.bottom, 6)
        }
        .padding(12)
    }

    private func send() {
        let text = state.replyDrafts[rootID] ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let root = conv.messages.first(where: { $0.id == rootID }) else { return }
        let prior = conv.replyTarget
        conv.beginReply(to: root)
        conv.send(text: text)
        if let prior { conv.beginReply(to: prior) }
        state.replyDrafts[rootID] = ""
    }
}

// MARK: team

struct TeamInspector: View {
    let team: TeamItem
    @ObservedObject var roster: TeamRosterViewModel
    @ObservedObject var conv: ConversationStore
    @Environment(\.windowModel) private var model

    /// Owners manage the roster: matched by user id (core-a
    /// `RosterOwnership`), never by display name.
    private var canManage: Bool {
        RosterOwnership.isOwner(roster.members, ownUserID: model?.app?.ownUserID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TeamTile(name: team.name, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(team.name).font(.headline).lineLimit(1)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var summary: String {
        let c = team.channels.count == 1 ? "1 channel" : "\(team.channels.count) channels"
        guard roster.state == .loaded else { return c }
        let n = roster.members.count
        return "\(c) · \(n == 1 ? "1 member" : "\(n) members")"
    }

    @ViewBuilder
    private var content: some View {
        switch roster.state {
        case .loading where roster.members.isEmpty:
            LoadingPane()
        case .error(let msg) where roster.members.isEmpty:
            ErrorPane(title: "Couldn't Load Members",
                      message: model?.connection == .offline ? "You're offline." : msg) { roster.refresh() }
        default:
            let sorted = TeamRosterViewModel.sorted(roster.members, names: roster.names)
            let owners = TeamRosterViewModel.owners(of: sorted)
            let members = TeamRosterViewModel.nonOwners(of: sorted)
            Form {
                if !owners.isEmpty {
                    Section("Owners (\(owners.count))") {
                        ForEach(owners) { memberRow($0) }
                    }
                }
                Section(members.isEmpty ? "Members" : "Members (\(members.count))") {
                    if members.isEmpty {
                        Text("No other members").foregroundStyle(.secondary)
                    } else {
                        ForEach(members) { memberRow($0) }
                    }
                }
                Section {
                    if canManage {
                        Button("Add Member…") {
                            model?.presentSheet(SheetRequest(TeamsCommands.addMemberSheet, in: .teams, arg: team.teamId))
                        }
                    }
                    Button("Create Channel…") {
                        model?.presentSheet(SheetRequest(TeamsCommands.createChannelSheet, in: .teams, arg: team.teamId))
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func memberRow(_ m: TeamMember) -> some View {
        let name = TeamRosterViewModel.displayName(for: m, names: roster.names)
        let you = model?.isOwnID(m.userId) == true || model?.isOwnID(m.id) == true
        let shown = you ? "You" : name
        return HStack(spacing: 8) {
            Avatar(name: you ? (model?.ownDisplayName ?? name) : name, diameter: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(shown).lineLimit(1)
                if let email = m.email, !email.isEmpty {
                    Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if canManage, !m.isOwner {
                Button {
                    model?.confirm(title: "Remove \(shown) from \(team.name)?",
                                   message: "They'll lose access to the team's channels and files.",
                                   action: "Remove") {
                        Task { await roster.remove(memberID: m.id) }
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(shown)")
                .accessibilityLabel("Remove \(shown)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
