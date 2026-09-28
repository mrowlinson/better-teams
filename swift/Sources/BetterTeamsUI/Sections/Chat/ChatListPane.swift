// ChatListPane.swift — Chat list pane (UI-SPEC §6.2): Pinned, then
// Recent; filter narrows. Selection binds through Navigator (R3, R21).
import OstMacCore
import SwiftUI

struct ChatListPane: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    @ObservedObject var mentions: MentionStore
    @ObservedObject var rules: RulesStore
    @ObservedObject var snooze: SnoozeStore
    @ObservedObject var failures: SendFailures
    /// 1:1 rows badge the other person's status (§6.2, §10).
    @ObservedObject var presence: PresenceStore
    let state: ChatSectionState
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            content(model)
        }
    }

    @ViewBuilder
    private func content(_ m: WindowModel) -> some View {
        let forced = m.forced(.chat)
        let rows = forced == .empty ? [] : filtered(chats.displayChats)
        if forced == .loading || (chats.state == .loading && chats.chats.isEmpty) {
            LoadingPane("Loading Chats\u{2026}")
        } else if forced == .error {
            // Evidence stands in for a failed load while offline; the
            // toolbar's Offline item reads the same `m.connection`.
            ErrorPane(title: "Couldn't Load Chats", message: errorMessage(nil, m)) {}
        } else if case .error(let msg) = chats.state, chats.chats.isEmpty {
            ErrorPane(title: "Couldn't Load Chats", message: errorMessage(msg, m)) { chats.refresh() }
        } else if rows.isEmpty {
            if state.filter == .all || forced == .empty {
                EmptyPane("No Chats", systemImage: "bubble.left.and.bubble.right",
                          message: "Chats you start or join appear here.") {
                    Button("New Chat…") {
                        m.presentSheet(SheetRequest(ChatCommands.newChatSheet, in: .chat))
                    }
                }
            } else {
                EmptyPane("No \(state.filter.title) Chats", systemImage: "line.3.horizontal.decrease") {
                    Button("Show All Chats") { state.filter = .all }
                }
            }
        } else {
            // R12: a refresh runs behind the rows on screen.
            list(rows, m)
                .refreshStatus(chats.state == .loading, failure: Self.failure(chats.state),
                               label: "Updating Chats", retry: { chats.refresh() })
        }
    }

    /// A failed refresh behind the rows on screen (quiet notice).
    static func failure(_ state: ChatListState) -> String? {
        if case .error(let message) = state { message } else { nil }
    }

    private func list(_ rows: [ChatItem], _ m: WindowModel) -> some View {
        let pinnedIDs = Set(chats.pins.orderedIDs)
        let pinned = rows.filter { pinnedIDs.contains($0.id) }
        let recent = rows.filter { !pinnedIDs.contains($0.id) }
        let now = RelativeClock.shared.now
        let selection = Binding<String?>(
            get: { m.nav.selection(in: .chat)?.id },
            set: { id in m.navigator?.select(id.map { SectionSelection(id: $0) }, in: .chat) })
        return List(selection: selection) {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { c in row(c, pinned: true, now: now) }
                }
            }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { c in row(c, pinned: false, now: now) }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                let isUnread = unread.isUnread(chatID: id)
                Button(isUnread ? "Mark as Read" : "Mark as Unread") {
                    if isUnread { unread.markRead(chatID: id) } else { unread.markUnread(chatID: id) }
                }
                Button(chats.isPinned(id) ? "Unpin" : "Pin") {
                    if chats.isPinned(id) { chats.unpin(id) } else { chats.pin(id) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { m.navigator?.select(SectionSelection(id: id), in: .chat) }
        }
    }

    /// §6 pane states: worded "You're offline" when offline (§5.7).
    private func errorMessage(_ msg: String?, _ m: WindowModel) -> String {
        m.connection == .offline || msg == nil ? "You're offline." : msg ?? ""
    }

    private func row(_ c: ChatItem, pinned: Bool, now: Date) -> some View {
        ChatRow(chat: c, unread: unread.isUnread(chatID: c.id), pinned: pinned,
                mentioned: mentions.contains(chatID: c.id),
                muted: rules.level(chatID: c.id) == .muted, snoozed: snooze.isSnoozed(chatID: c.id, now: now),
                notSent: failures.chatIDs.contains(c.id),
                presence: c.is_group ? nil
                    : presence.availabilityForChat(c.id).flatMap(PresenceStatus.from(availability:)),
                conv: model?.graph.conv, now: now)
            .tag(c.id)
    }

    /// Hidden chats leave every view but Hidden (§6.2 Filter menu).
    private func filtered(_ list: [ChatItem]) -> [ChatItem] {
        if state.filter == .hidden { return list.filter { rules.isHidden(chatID: $0.id) } }
        let shown = list.filter { !rules.isHidden(chatID: $0.id) }
        switch state.filter {
        case .all, .hidden: return shown
        case .unread: return shown.filter { unread.isUnread(chatID: $0.id) }
        case .mentions: return shown.filter { mentions.contains(chatID: $0.id) }
        case .muted: return shown.filter { rules.level(chatID: $0.id) == .muted }
        case .snoozed: return shown.filter { snooze.isSnoozed(chatID: $0.id) }
        case .folder(let id): return shown.filter { chats.folders.folderID(for: $0) == id }
        }
    }
}
