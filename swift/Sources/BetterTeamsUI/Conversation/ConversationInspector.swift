// ConversationInspector.swift — trailing inspector for a conversation
// (UI-SPEC §5.6, §6.2): Info (members with presence, notification
// level, Snooze, pin, read state, Hide, Leave) ·
// Catch Up (summary, action items, provider state, Retry) · Pinned
// (pinned messages; click to jump).
import OstMacCore
import SwiftUI

enum InspectorSegment: String, CaseIterable {
    case info, catchup, pinned

    var title: String {
        switch self {
        case .info: "Info"
        case .catchup: "Catch Up"
        case .pinned: "Pinned"
        }
    }
}

struct ConversationInspector: View {
    let ref: ConversationRef?
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let seg = model.inspectorSegment.flatMap(InspectorSegment.init(rawValue:)) ?? .info
            VStack(spacing: 0) {
                Picker("Inspector", selection: Binding(get: { seg },
                                                       set: { model.setInspectorSegment($0.rawValue) })) {
                    ForEach(InspectorSegment.allCases, id: \.rawValue) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                // Same height as the conversation header, so the two
                // hairlines meet in one line across the window.
                .frame(maxWidth: .infinity, minHeight: ConversationHeader.minHeight)
                Divider()
                Group {
                    if let ref {
                        switch seg {
                        case .info:
                            let services = ConversationServices.of(model)
                            InfoPane(ref: ref, chats: chats, unread: unread, conv: model.graph.conv,
                                     rules: services.rules(model), snooze: services.snooze(model),
                                     presence: model.app?.presence)
                        case .catchup:
                            if let app = model.app {
                                CatchUpPane(store: app.catchUp, items: app.actionItems, conv: model.graph.conv,
                                            chatID: ref)
                            } else {
                                EmptyPane("Catch Up Unavailable", systemImage: "sparkles",
                                          message: "Catch Up runs in the active account's window.")
                            }
                        case .pinned:
                            PinnedPane(store: model.graph.pinnedMessages, conv: model.graph.conv, chatID: ref)
                        }
                    } else {
                        NoSelectionPane("No Chat Selected")
                    }
                }
                // Fills the pane: the segmented header stays at the top.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

}

/// Info (§6.2): who is here (with presence where core knows it), how
/// this chat notifies you, and the chat-level actions.
struct InfoPane: View {
    let ref: ConversationRef
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    @ObservedObject var conv: ConversationStore
    @ObservedObject var rules: RulesStore
    @ObservedObject var snooze: SnoozeStore
    let presence: PresenceStore?
    @Environment(\.windowModel) private var model

    var body: some View {
        let row = chats.chat(id: ref)
        let name = row?.name ?? DemoData.name(for: ref) ?? conv.headerTitle
        let isGroup = row?.is_group ?? false
        let messages = conv.chatID == ref ? conv.messages : []
        Form {
            Section {
                VStack(spacing: 8) {
                    Avatar(name: name, isGroup: isGroup, diameter: 56)
                    Text(name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    RosterBound(chatID: ref, roster: model?.app?.chatRoster) { count in
                        let sub = ConversationDetail.subtitle(isGroup: isGroup, messages: messages, rosterCount: count)
                        if !sub.isEmpty { Text(sub).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section("Notifications") {
                Picker("Notify Me", selection: Binding(get: { rules.level(chatID: ref) },
                                                       set: { rules.setLevel(chatID: ref, level: $0) })) {
                    Text("All Messages").tag(ChatNotifyLevel.all)
                    Text("Mentions Only").tag(ChatNotifyLevel.mentions)
                    Text("Off").tag(ChatNotifyLevel.muted)
                }
                // A pop-up like Notify Me (both pick one state and show
                // it): Off, the live expiry, the presets, Custom… (sheet).
                Picker("Snooze", selection: Binding(get: { SnoozeChoice.current(snooze, ref) },
                                                    set: { choose($0) })) {
                    Text("Off").tag(SnoozeChoice.off)
                    if let until = snooze.expiry(for: ref) {
                        Text("Until \(SnoozeStore.timeLabel(for: until))").tag(SnoozeChoice.active)
                    }
                    Divider()
                    ForEach(SnoozeDuration.allCases, id: \.rawValue) { d in
                        Text(Self.title(d)).tag(SnoozeChoice.preset(d))
                    }
                    Divider()
                    Text("Custom…").tag(SnoozeChoice.custom)
                }
            }
            Section {
                Toggle("Pin to Top of List", isOn: Binding(get: { chats.isPinned(ref) },
                                                          set: { $0 ? chats.pin(ref) : chats.unpin(ref) }))
                Button(unread.isUnread(chatID: ref) ? "Mark as Read" : "Mark as Unread") {
                    if unread.isUnread(chatID: ref) { unread.markRead(chatID: ref) } else { unread.markUnread(chatID: ref) }
                }
            }
            Section("People in This Conversation") {
                if let app = model?.app {
                    RosterPeople(chatID: ref, roster: app.chatRoster, presence: app.presence, isGroup: isGroup) {
                        senderPeople(isGroup: isGroup, messages: messages)
                    }
                } else {
                    senderPeople(isGroup: isGroup, messages: messages)
                }
            }
            Section {
                let hidden = rules.isHidden(chatID: ref)
                Button(hidden ? "Show Chat in List" : "Hide Chat") {
                    rules.setHidden(chatID: ref, hidden: !hidden)
                }
                // A standard push button: the destructive step is the
                // NSAlert it opens (§9.5), which carries the red role.
                if isGroup {
                    Button("Leave Chat…") {
                        model?.confirm(title: "Leave \(name)?",
                                       message: "You won't get new messages from this chat.",
                                       action: "Leave", perform: {
                                           Task { await chats.leave(chatID: ref) }
                                       })
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Until the chat roster loads (or without one): the people in the
    /// loaded history.
    @ViewBuilder
    private func senderPeople(isGroup: Bool, messages: [ChatMessage]) -> some View {
        let people = MentionCompose.roster(from: messages)
        if people.isEmpty {
            Text("No messages yet").foregroundStyle(.secondary)
        } else {
            ForEach(Indexed.wrap(people)) { p in
                let you = messages.contains { $0.isOwn && $0.sender == p.value }
                MemberRow(name: you ? (model?.ownDisplayName ?? p.value) : p.value, isYou: you,
                          status: status(for: p.value, isGroup: isGroup, messages: messages))
            }
        }
    }

    /// Presence core can attribute from history alone: yours, and the
    /// other person's in a 1:1 chat.
    private func status(for name: String, isGroup: Bool, messages: [ChatMessage]) -> PresenceStatus? {
        guard let presence else { return nil }
        if messages.contains(where: { $0.isOwn && $0.sender == name }) {
            return presence.own.flatMap { PresenceStatus.from(availability: $0.availability) }
        }
        guard !isGroup else { return nil }
        return presence.availabilityForChat(ref).flatMap(PresenceStatus.from(availability:))
    }

    private func choose(_ c: SnoozeChoice) {
        switch c {
        case .off: snooze.unsnooze(chatID: ref)
        case .active: break
        case .preset(let d): snooze.snooze(chatID: ref, duration: d)
        case .custom:
            model?.presentSheet(SheetRequest(ChatCommands.snoozeCustomSheet, in: .chat, arg: ref))
        }
    }

    static func title(_ d: SnoozeDuration) -> String {
        switch d {
        case .oneHour: "1 Hour"
        case .fourHours: "4 Hours"
        case .untilMorning: "Until 8 AM"
        case .tomorrowMorning: "Until Tomorrow at 8 AM"
        }
    }
}

/// The Snooze pop-up's items: Off, the live snooze, a preset, Custom….
enum SnoozeChoice: Hashable {
    case off, active, custom
    case preset(SnoozeDuration)

    @MainActor
    static func current(_ store: SnoozeStore, _ chatID: String) -> SnoozeChoice {
        store.isSnoozed(chatID: chatID) ? .active : .off
    }
}

/// The chat roster (core-a): every member with presence and the owner
/// role; own row by id ("You", initials from the owner's name).
/// Presence is fetched once per roster. Falls back to `fallback` until
/// this chat's roster loads.
private struct RosterPeople<Fallback: View>: View {
    let chatID: String
    @ObservedObject var roster: ChatRosterStore
    @ObservedObject var presence: PresenceStore
    /// A 1:1 chat has no owner role to show.
    let isGroup: Bool
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.windowModel) private var model

    var body: some View {
        if roster.chatID == chatID, roster.state == .loaded, !roster.members.isEmpty {
            Group {
                ForEach(roster.members) { m in
                    let you = model?.isOwnID(m.presenceID) == true || model?.isOwnID(m.mri) == true
                    MemberRow(name: you ? (model?.ownDisplayName ?? m.displayName) : Self.name(m), isYou: you,
                              status: status(m, you: you), isOwner: isGroup && m.isOwner)
                }
            }
            .task(id: roster.members.map(\.mri)) {
                // One Graph call per member: big groups fetch the first 20.
                if roster.members.count <= Self.presenceCap {
                    await roster.refreshPresence(into: presence)
                } else {
                    await presence.refreshPeers(ids: Array(roster.presenceIDs.prefix(Self.presenceCap)))
                }
            }
        } else {
            fallback()
        }
    }

    private static var presenceCap: Int { 20 }

    /// Chat-service rosters may carry no name: email, else "Unknown".
    private static func name(_ m: ChatMember) -> String {
        if !m.displayName.isEmpty { return m.displayName }
        if let e = m.email, !e.isEmpty { return e }
        return "Unknown"
    }

    private func status(_ m: ChatMember, you: Bool) -> PresenceStatus? {
        if you { return presence.own.flatMap { PresenceStatus.from(availability: $0.availability) } }
        guard let key = OwnIdentity.key(m.presenceID) else { return nil }
        let hit = presence.peers[m.presenceID ?? ""] ?? presence.peers.first { OwnIdentity.key($0.key) == key }?.value
        return hit.flatMap { PresenceStatus.from(availability: $0.availability) }
    }
}

/// One person: avatar with presence badge (shape + color), name (+
/// "Owner"), and the status in words.
private struct MemberRow: View {
    let name: String
    let isYou: Bool
    let status: PresenceStatus?
    var isOwner = false

    var body: some View {
        HStack(spacing: 8) {
            Avatar(name: name, diameter: 22)
                .overlay(alignment: .bottomTrailing) {
                    if let status { PresenceBadge(status: status, size: 9).offset(x: 2, y: 2) }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(isYou ? "You" : name).lineLimit(1)
                if isOwner {
                    Text("Owner").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let status {
                Text(status.availabilityTitle).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension PresenceStatus {
    /// Status as people read it ("Available", "Away"), not the picker's
    /// "Appear away" wording.
    var availabilityTitle: String {
        switch self {
        case .available: "Available"
        case .busy: "Busy"
        case .dnd: "Do Not Disturb"
        case .brb: "Be Right Back"
        case .away: "Away"
        case .offline: "Offline"
        }
    }
}

/// Catch Up: runs on request (toolbar Catch Up or the button), never on
/// appear (R24). Every failure shows its reason and Try Again.
struct CatchUpPane: View {
    @ObservedObject var store: CatchUpStore
    @ObservedObject var items: ActionItemsStore
    let conv: ConversationStore
    let chatID: String

    var body: some View {
        switch store.state {
        case .idle:
            // Idle names what will run (§6.2 provider state); nothing to
            // summarize = nothing to run.
            EmptyPane("Catch Up", systemImage: "sparkles", message: idleMessage) {
                Button("Catch Up") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasMessages)
            }
        case .loading:
            ProgressView("Summarizing…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyPane(store.lastError == .off ? "Catch Up Is Off" : "Couldn't Catch Up",
                      systemImage: store.lastError == .off ? "sparkles" : "exclamationmark.triangle",
                      message: store.lastError == .off
                          ? "Turn on Catch Up and choose a provider in Settings ▸ AI." : message) {
                Button("Try Again") { run() }
            }
        case .loaded(let summary):
            Form {
                Section("Summary") {
                    Text(summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Section("Action Items") { actionItems }
                Section {
                    Text("Provider: \(store.config.provider.title)").foregroundStyle(.secondary)
                    Button("Summarize Again") { run() }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        switch items.state {
        case .idle:
            Button("Find Action Items") {
                let msgs = conv.messages
                Task { await items.extractFromMessages(msgs, chatID: chatID) }
            }
        case .loading:
            ProgressView().controlSize(.small)
        case .loaded(let list):
            ForEach(list) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                    Text(item.owner).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .empty(let copy):
            Text(copy).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        }
    }

    private func run() {
        CatchUpRunner.run(store: store, items: items, conv: conv, chatID: chatID)
    }

    private var hasMessages: Bool {
        conv.chatID == chatID && !conv.messages.isEmpty
    }

    private var idleMessage: String {
        guard hasMessages else { return "There are no messages to summarize yet." }
        guard store.config.enabled else { return "Catch Up is off. Turn it on and choose a provider in Settings ▸ AI." }
        return "Summarize this conversation and list its action items with \(store.config.provider.title)."
    }
}

@MainActor
enum CatchUpRunner {
    /// Starts a summary of the open conversation (toolbar Catch Up).
    static func run(store: CatchUpStore, items: ActionItemsStore, conv: ConversationStore, chatID: String) {
        guard conv.chatID == chatID else { return }
        let msgs = conv.messages
        items.reset()
        Task { await store.summarize(messages: msgs, chatID: chatID) }
    }

    static func run(_ m: WindowModel, chatID: String) {
        guard let app = m.app else { return }
        run(store: app.catchUp, items: app.actionItems, conv: m.graph.conv, chatID: chatID)
    }
}

/// Pinned messages for this chat, newest pin first; click jumps.
struct PinnedPane: View {
    @ObservedObject var store: PinnedMessageStore
    @ObservedObject var conv: ConversationStore
    let chatID: String
    @Environment(\.windowModel) private var model

    var body: some View {
        let rows = store.rows(for: chatID, messages: conv.chatID == chatID ? conv.messages : [])
        if rows.isEmpty {
            EmptyPane("No Pinned Messages", systemImage: "pin",
                      message: "Pin a message from its context menu to keep it here.")
        } else {
            List {
                ForEach(rows) { r in
                    let own = !r.sender.isEmpty && r.sender == conv.ownDisplayName
                    Button { if r.isAvailable { conv.seek(messageID: r.messageID) } } label: {
                        // Sender avatar, name and time over the pinned text.
                        HStack(alignment: .top, spacing: 8) {
                            Avatar(name: own ? (model?.ownDisplayName ?? r.sender) : r.sender, diameter: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(own ? "You" : r.sender).font(.headline).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(Self.when(r.timestamp)).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                                Text(r.preview).foregroundStyle(.secondary).lineLimit(2)
                                if !r.isAvailable {
                                    Text("Not in loaded history").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Unpin") { store.unpin(chatID: chatID, messageID: r.messageID) }
                    }
                    .help(r.isAvailable ? "Show in Conversation" : "Not in loaded history")
                    .accessibilityHint("Shows the message in the conversation")
                }
            }
            .listStyle(.inset)
        }
    }

    /// Day + time, the day as the timeline's day separators say it
    /// ("Yesterday", "Sep 22, 2026"); today is the time alone.
    static func when(_ iso: String, now: Date = Date()) -> String {
        guard let d = TeamsTime.parseISO(iso) else { return "" }
        let time = TeamsTime.clock(d)
        guard !Calendar.current.isDate(d, inSameDayAs: now) else { return time }
        return "\(MessageRender.dayLabel(MessageRender.dayKey(iso))) \(time)"
    }
}
