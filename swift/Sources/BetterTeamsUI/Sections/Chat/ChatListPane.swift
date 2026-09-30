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
    /// Filter look-back (inline indicator + its terminal state).
    @ObservedObject var pager: ChatFilterPager
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
        let rows = forced == .empty ? [] : filterRules.apply(state.filter, to: chats.displayChats)
        if forced == .loading || (chats.state == .loading && chats.chats.isEmpty) {
            LoadingPane("Loading Chats\u{2026}")
        } else if forced == .error {
            // Evidence stands in for a failed load while offline; the
            // toolbar's Offline item reads the same `m.connection`.
            ErrorPane(title: "Couldn't Load Chats", message: errorMessage(nil, m)) {}
        } else if case .error(let msg) = chats.state, chats.chats.isEmpty {
            ErrorPane(title: "Couldn't Load Chats", message: errorMessage(msg, m)) { chats.refresh() }
        } else if rows.isEmpty && (state.filter == .all || forced == .empty) {
            EmptyPane("No Chats", systemImage: "bubble.left.and.bubble.right",
                      message: "Chats you start or join appear here.") {
                Button("New Chat…") {
                    m.presentSheet(SheetRequest(ChatCommands.newChatSheet, in: .chat))
                }
            }
        } else {
            // R12: a refresh runs behind the rows on screen. One list for
            // the full and filtered rows (a filter never remounts it), so
            // clearing the filter returns without a flash.
            list(rows, m)
                .overlay {
                    if rows.isEmpty { filterEmpty }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if state.filter != .all { filterBar(count: rows.count) }
                }
                .onExitCommand { if state.filter != .all { state.clear() } }
                .refreshStatus(chats.state == .loading, failure: Self.failure(chats.state),
                               label: "Updating Chats", retry: { chats.refresh() })
        }
    }

    private var filterRules: ChatFilterRules {
        ChatFilterRules(unread: unread, mentions: mentions, rules: rules, snooze: snooze,
                        folders: chats.folders)
    }

    private var folderName: String? {
        if case .folder(let id) = state.filter { return chats.folders.name(for: id) }
        return nil
    }

    /// Active filter: a secondary "Filtered by" label with a small native
    /// Clear button (also Esc) that returns to the full list.
    private func filterBar(count: Int) -> some View {
        HStack(spacing: 8) {
            Label("Filtered by \(folderName ?? state.filter.title)", systemImage: "line.3.horizontal.decrease")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Clear") { state.clear() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show All Chats (Esc)")
                .accessibilityLabel("Clear \(folderName ?? state.filter.title) filter")
                .accessibilityHint("Clears the filter and shows all chats")
            Spacer(minLength: 4)
            Text(count == 1 ? "1 chat" : "\(count) chats")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// No row matches the filter: a themed empty state with the way
    /// back, plus the bounded look-back's indicator (it ends).
    private var filterEmpty: some View {
        EmptyPane(state.filter.emptyTitle(folderName: folderName), systemImage: "line.3.horizontal.decrease",
                  message: state.filter.emptyMessage) {
            Button("Show All Chats") { state.clear() }
            filterSearchStatus
        }
    }

    /// Inline look-back state: a small spinner while it runs; after it
    /// ends, a link for another bounded look when older chats remain.
    @ViewBuilder
    private var filterSearchStatus: some View {
        switch pager.phase {
        case .searching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking older chats\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .finished where chats.hasMore:
            Button("Check Older Chats") { state.searchOlder(list: chats, rules: filterRules) }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(chats.isLoadingMore)
        case .idle, .finished:
            EmptyView()
        }
    }

    /// End of the loaded rows while Teams has older chats: a small
    /// spinner while the next page loads. On screen it keeps paging (the
    /// task re-runs per new page link) until the rows fill the pane.
    private var pageFooter: some View {
        HStack {
            Spacer()
            if chats.loadMoreFailed {
                // FIXPACK F9: a timed-out / failed older-page read says so.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text("Couldn\u{2019}t load older chats.").font(.caption).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await chats.retryLoadMore() } }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .accessibilityElement(children: .combine)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .opacity(chats.isLoadingMore ? 1 : 0)
                    .accessibilityLabel("Loading More Chats")
                    .accessibilityHidden(!chats.isLoadingMore)
            }
            Spacer()
        }
        .frame(height: 24)
        .selectionDisabled()
        .task(id: chats.nextPageLink) { await chats.loadMore() }
    }

    /// A failed refresh behind the rows on screen (quiet notice).
    /// Double-click (or Return) on a row pops the chat out into its own
    /// window (81b718a); a single click only selects.
    static func doubleClick(_ ids: Set<String>, _ m: WindowModel) {
        if let id = ids.first { ChatWindowController.show(m, chatID: id) }
    }

    static func failure(_ state: ChatListState) -> String? {
        if case .error(let message) = state { message } else { nil }
    }

    private func list(_ rows: [ChatItem], _ m: WindowModel) -> some View {
        let pinnedIDs = Set(chats.pins.orderedIDs)
        let pinned = rows.filter { pinnedIDs.contains($0.id) }
        // Teams Favorites folder, as in Teams: its own section above
        // the rest (a chat pinned here stays under Pinned).
        let favIDs = Set(chats.folders.favoriteIDs).subtracting(pinnedIDs)
        let favorites = rows.filter { favIDs.contains($0.id) }
        let recent = rows.filter { !pinnedIDs.contains($0.id) && !favIDs.contains($0.id) }
        let now = RelativeClock.shared.now
        let shownIDs = Set(rows.map(\.id))
        let selection = Binding<String?>(
            get: { m.nav.selection(in: .chat)?.id },
            set: { id in
                // A filter hiding the open chat is not a deselect: it
                // stays open and selected when the filter clears.
                if id == nil, state.filter != .all,
                   let open = m.nav.selection(in: .chat)?.id, !shownIDs.contains(open) { return }
                m.navigator?.select(id.map { SectionSelection(id: $0) }, in: .chat)
            })
        return ScrollViewReader { proxy in
        List(selection: selection) {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { c in row(c, pinned: true, now: now) }
                }
            }
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { c in row(c, pinned: false, now: now) }
                }
            }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { c in
                        row(c, pinned: false, now: now)
                            .onAppear {
                                // Unfiltered only: a filter's look-back is
                                // the bounded pager, never scroll paging.
                                if state.filter == .all { chats.loadMoreIfNeeded(currentID: c.id, in: recent) }
                            }
                    }
                }
            }
            if state.filter == .all {
                if chats.hasMore { pageFooter }
            } else if !rows.isEmpty, pager.phase == .searching || chats.hasMore {
                HStack {
                    Spacer()
                    filterSearchStatus
                    Spacer()
                }
                .frame(height: 24)
                .selectionDisabled()
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                ChatRowMenu(id: id, chats: chats, unread: unread, rules: rules, snooze: snooze,
                            folders: chats.folders, model: m)
            }
        } primaryAction: { ids in
            Self.doubleClick(ids, m)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionError }
        .onChange(of: state.filter) { _, now in
            // Back on the full list: return to the rows on screen when
            // the filter was entered.
            if now == .all, let anchor = state.returnAnchor { proxy.scrollTo(anchor, anchor: .top) }
        }
        }
    }

    /// Quiet note when Teams refused a chat action (the change was
    /// undone); dismissible, no alert.
    @ViewBuilder
    private var actionError: some View {
        if let text = rules.syncError
            ?? chats.folders.serverSyncError.map({ "Couldn't move the chat: \($0)" })
            ?? chats.leaveError.map({ "Couldn't leave the chat: \($0)" })
            ?? chats.deleteError.map({ "Couldn't delete the chat: \($0)" })
            ?? chats.readStateError
        {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    rules.clearSyncError()
                    chats.folders.clearServerSyncError()
                    chats.clearLeaveError()
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
            .onAppear { if state.filter == .all { state.visibleIDs.insert(c.id) } }
            .onDisappear { if state.filter == .all { state.visibleIDs.remove(c.id) } }
    }
}
