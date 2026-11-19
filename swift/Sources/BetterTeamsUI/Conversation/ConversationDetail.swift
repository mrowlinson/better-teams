// ConversationDetail.swift — the conversation view shared by Chat,
// Activity, Search, and Teams posts (UI-SPEC §6.2).
//
// Header + tab shell (Chat | Files | Notes). Chat = timeline + composer;
// Files and Notes call their owning lanes' seams (`FileTable`,
// `NotesTab`), whose bodies those lanes replace.
import OstMacCore
import SwiftUI
import Translation

struct ConversationDetail: View {
    let ref: ConversationRef
    @ObservedObject var conv: ConversationStore
    @ObservedObject var chats: ChatListViewModel
    @Environment(\.windowModel) private var model
    var body: some View {
        if let model {
            let row = chats.chat(id: ref)
            let name = row?.name ?? (conv.chatID == ref ? conv.headerTitle : DemoFixture.name(for: ref, demo: model.options.demo) ?? "Conversation")
            let isGroup = row?.is_group ?? false
            // Pinned tabs ride the app-owned store, loaded from the
            // selection funnel (R24) — the view only reads.
            let pinned = model.app?.chatTabs.tabs(for: ref) ?? []
            let selected = ChatTabLayout(kind: ChatKind.of(chatID: ref, isGroup: isGroup), tabs: pinned)
                .resolve(builtin: model.nav.tab(for: ref), pinned: model.nav.detailAppTab[ref])
            VStack(spacing: 0) {
                RosterBound(chatID: ref, roster: model.app?.chatRoster) { count in
                    ManagedConversationHeader(
                        chatID: ref,
                        name: name, isGroup: isGroup,
                        subtitle: isGroup ? Self.subtitle(isGroup: true, messages: conv.chatID == ref ? conv.messages : [],
                                                          rosterCount: count)
                            : PresenceLine(presence: model.app?.presence, chatID: ref).text,
                        tabStore: model.app?.chatTabs,
                        demo: model.options.demo)
                }
                Divider()
                // The tab body fills the pane, so the header stays pinned
                // to the top whatever the tab shows.
                ChatTabBody(selected: selected, chatID: ref, name: name, pinned: pinned, app: model.app) {
                    chatTab(name: name, services: ConversationServices.of(model))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Group chats show their member count (§6.2 header: "presence or
    /// member count"): the chat roster's size once it loads (core-a
    /// `ChatRosterStore.peopleCount`); until then, the people in the
    /// loaded history plus you. 1:1 chats show presence (header) or
    /// nothing (never a placeholder word).
    static func subtitle(isGroup: Bool, messages: [ChatMessage], rosterCount: Int? = nil) -> String {
        guard isGroup else { return "" }
        if let n = rosterCount, n > 0 { return n == 1 ? "1 person" : "\(n) people" }
        guard !messages.isEmpty else { return "Group chat" }
        let n = MentionCompose.roster(from: messages).count + (messages.contains(where: \.isOwn) ? 0 : 1)
        return n == 1 ? "1 person" : "\(n) people"
    }

    @ViewBuilder
    private func chatTab(name: String, services: ConversationServices) -> some View {
        if conv.chatID != ref || (conv.loading && conv.messages.isEmpty) {
            LoadingPane("Loading Messages\u{2026}")
        } else if let err = conv.error, conv.messages.isEmpty {
            ErrorPane(title: model?.connection == .offline ? "You're Offline" : "Couldn't Load Messages",
                      message: err) { conv.retryOpen() }
        } else {
            VStack(spacing: 0) {
                // A jump (Activity, Search, message link) whose message is
                // gone says so instead of silently opening at the end (§6.1).
                if conv.jumpMissedID != nil {
                    HStack(spacing: 8) {
                        Label("Message no longer available", systemImage: "exclamationmark.bubble")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Dismiss") { conv.clearJumpMissed() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                // FIXPACK3 R3: the newest pinned message above the timeline.
                if let pins = model?.graph.pinnedMessages {
                    PinnedMessageBar(store: pins, conv: conv, chatID: ref)
                }
                if conv.messages.isEmpty {
                    EmptyPane("No Messages Yet", systemImage: "bubble.left",
                              message: "Send a message to start the conversation.")
                } else {
                    // R12: a resync refresh merges in behind the bubbles.
                    TimelineRepresentable(conv: conv)
                        .refreshStatus(conv.refreshing, failure: conv.refreshError,
                                       label: "Updating Messages", retry: { conv.refresh() })
                        // histload: small top spinner while an older page loads.
                        .refreshStatus(conv.loadingMore, label: "Loading Earlier Messages", alignment: .top)
                }
                Divider()
                Composer(chatID: ref, chatName: name, placeholder: "Message \(name)", conv: conv,
                         composer: services.composer, attachments: services.attachments, services: services)
            }
            // Files dropped onto the conversation attach to the draft.
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                services.attachments.stage(urls: files)
                return true
            }
            // The Translate action needs a live session (TranslationStore
            // fails fast with `.sessionNotAttached` otherwise).
            .translationTask(TranslationSession.Configuration(target: services.translation.sessionTarget)) { session in
                services.translation.attached(session)
            }
        }
    }
}

/// TABS-MGMT host: the conversation header tab row plus add/rename/
/// remove sheets. Observes the app-owned ChatTabsStore so the row
/// recomputes after a mutation (the detail snapshot alone would go
/// stale). Selection/navigation behavior matches the direct
/// ConversationHeader wiring it replaces.
struct ManagedConversationHeader: View {
    let chatID: String
    let name: String
    let isGroup: Bool
    let subtitle: String
    /// One sheet slot: two `.sheet` modifiers on one view present
    /// unreliably, so add/rename share an item-based sheet.
    private enum ManageSheet: Identifiable {
        case add, rename
        var id: String {
            switch self {
            case .add: "add"
            case .rename: "rename"
            }
        }
    }
    var tabStore: ChatTabsStore? = nil
    var demo = false
    /// Observes the same instance as `tabStore` so the row recomputes
    /// after a mutation (a plain var would leave it stale).
    @ObservedObject private var observed: ChatTabsStore
    @Environment(\.windowModel) private var model

    init(chatID: String, name: String, isGroup: Bool, subtitle: String,
         tabStore: ChatTabsStore? = nil, demo: Bool = false) {
        self.chatID = chatID
        self.name = name
        self.isGroup = isGroup
        self.subtitle = subtitle
        self.tabStore = tabStore
        self.demo = demo
        self._observed = ObservedObject(wrappedValue: tabStore ?? ChatTabsStore())
    }
    @State private var manageSheet: ManageSheet?
    @State private var confirmingRemove = false
    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var manageFailed: String?

    private var pinned: [ChannelTab] { tabStore?.tabs(for: chatID) ?? [] }

    private var canManage: Bool {
        !demo && tabStore != nil && ChatTabsStore.hasTabs(chatID)
    }

    var body: some View {
        // Keep the row live: any store mutation re-resolves the row.
        let _ = observed.tabs(for: chatID)
        if let model {
            let layout = ChatTabLayout(kind: ChatKind.of(chatID: chatID, isGroup: isGroup), tabs: pinned)
            let selected = layout.resolve(builtin: model.nav.tab(for: chatID), pinned: model.nav.detailAppTab[chatID])
            let selectedName: String? = {
                if case .pinned(let id) = selected { return pinned.first { $0.id == id }?.name }
                return nil
            }()
            ConversationHeader(
                name: name, isGroup: isGroup, subtitle: subtitle, layout: layout,
                tab: Binding(get: { selected }, set: { key in
                    switch key {
                    case .builtin(let t): model.navigator?.setDetailTab(t, for: chatID)
                    case .pinned(let id): model.navigator?.setDetailAppTab(id, for: chatID)
                    }
                }),
                opened: model.nav.detailOpenedTab[chatID].map(ChatTabKey.pinned),
                open: { key in
                    if case .pinned(let id) = key { model.navigator?.openDetailAppTab(id, for: chatID) }
                },
                close: { model.navigator?.closeOpenedTab(for: chatID) },
                canManageTabs: canManage,
                selectedPinnedName: selectedName,
                onAddTab: { draftName = ""; draftURL = ""; manageSheet = .add },
                onRenameTab: { draftName = selectedName ?? ""; manageSheet = .rename },
                onRemoveTab: { confirmingRemove = true })
            .sheet(item: $manageSheet) { sheet in
                switch sheet {
                case .add:
                    ChannelTabAddSheet(name: $draftName, url: $draftURL) {
                        Task {
                            await tabStore?.add(
                                chatID: chatID, name: draftName,
                                url: Self.blankToNil(draftURL))
                            if let e = tabStore?.manageError[chatID] {
                                manageFailed = e
                                tabStore?.clearManageError(chatID: chatID)
                            } else if let added = pinned.first(where: { $0.name == draftName }) {
                                model.navigator?.setDetailAppTab(added.id, for: chatID)
                            }
                            manageSheet = nil
                        }
                    }
                case .rename:
                    ChannelTabRenameSheet(name: $draftName) {
                        guard case .pinned(let id) = selected else { return }
                        Task {
                            await tabStore?.rename(chatID: chatID, tabID: id, name: draftName)
                            if let e = tabStore?.manageError[chatID] {
                                manageFailed = e
                                tabStore?.clearManageError(chatID: chatID)
                            }
                            manageSheet = nil
                        }
                    }
                }
            }
            .confirmationDialog("Remove Tab", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove Tab", role: .destructive) {
                    guard case .pinned(let id) = selected else { return }
                    Task {
                        await tabStore?.remove(chatID: chatID, tabID: id)
                        if let e = tabStore?.manageError[chatID] {
                            manageFailed = e
                            tabStore?.clearManageError(chatID: chatID)
                        } else {
                            model.navigator?.setDetailTab(.chat, for: chatID)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove “\(selectedName ?? "this tab")” from this chat?")
            }
            .alert("Couldn't Update Tab", isPresented: Binding(
                get: { manageFailed != nil },
                set: { if !$0 { manageFailed = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(manageFailed ?? "")
            }
        }
    }

    private static func blankToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : s
    }
}

/// A 1:1 chat's header subtitle: the other person's status in words,
/// when core knows it.
@MainActor
struct PresenceLine {
    let presence: PresenceStore?
    let chatID: String

    var text: String {
        presence?.availabilityForChat(chatID).flatMap(PresenceStatus.from(availability:))?.availabilityTitle ?? ""
    }
}

/// Hands `content` the chat roster's people count for `chatID` (nil
/// until that chat's roster loads), re-rendering when the roster
/// changes. `loads` = this view loads the roster when the chat changes
/// (the conversation header does; the inspector only observes).
/// R24: the roster loads from the selection funnel
/// (`AppState.open(chatID:)` / `openPopout`), never here — this view
/// only reads the store's current state for its chat.
struct RosterBound<Content: View>: View {
    let chatID: String
    let roster: ChatRosterStore?
    @ViewBuilder let content: (Int?) -> Content

    var body: some View {
        if let roster {
            Observed(chatID: chatID, roster: roster, content: content)
        } else {
            content(nil)
        }
    }

    private struct Observed: View {
        let chatID: String
        @ObservedObject var roster: ChatRosterStore
        let content: (Int?) -> Content

        var body: some View {
            content(roster.chatID == chatID ? roster.peopleCount : nil)
        }
    }
}

/// One chat tab's body (Chat, Shared, Notes, Recap, a pinned tab): the
/// main window's conversation and a popped-out chat show the same tabs
/// (CHATSYNC3 R2). `chat` is the host's Chat tab (timeline + composer).
struct ChatTabBody<Chat: View>: View {
    let selected: ChatTabKey
    let chatID: String
    let name: String
    let pinned: [ChannelTab]
    let app: AppState?
    @ViewBuilder let chat: () -> Chat

    var body: some View {
        switch selected {
        case .builtin(.chat): chat()
        case .builtin(.files): FileTable(scope: .conversation(chatID))
        case .builtin(.notes): NotesTab(scope: .conversation(chatID))
        case .builtin(.recap):
            if let app {
                ChatRecapTab(chatID: chatID, chatName: name, store: app.meetingRecaps,
                             recordings: app.recordings,
                             transcripts: app.transcripts)
            } else {
                ChatTabPlaceholder(title: "Recap", symbol: ChatTabLayout.symbol(.recap),
                                   message: "Meeting recordings, transcripts and notes show here once the meeting has them.")
            }
        case .pinned(let id):
            if let t = pinned.first(where: { $0.id == id }) {
                ChatPinnedTabPane(tab: t, chatID: chatID)
            }
        }
    }
}
