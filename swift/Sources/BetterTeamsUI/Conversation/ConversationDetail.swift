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
    /// CHATTABS: the chat's pinned tabs (cached per chat, read-only).
    @StateObject private var chatTabs = ChatTabsStore()

    var body: some View {
        if let model {
            let row = chats.chat(id: ref)
            let name = row?.name ?? (conv.chatID == ref ? conv.headerTitle : DemoFixture.name(for: ref, demo: model.options.demo) ?? "Conversation")
            let isGroup = row?.is_group ?? false
            let pinned = chatTabs.tabs(for: ref)
            let layout = ChatTabLayout(kind: ChatKind.of(chatID: ref, isGroup: isGroup), tabs: pinned)
            let selected = layout.resolve(builtin: model.nav.tab(for: ref), pinned: model.nav.detailAppTab[ref])
            VStack(spacing: 0) {
                RosterBound(chatID: ref, roster: model.app?.chatRoster, loads: !ChannelTabsStore.isChannelID(ref)) { count in
                    ConversationHeader(
                        name: name, isGroup: isGroup,
                        subtitle: isGroup ? Self.subtitle(isGroup: true, messages: conv.chatID == ref ? conv.messages : [],
                                                          rosterCount: count)
                            : PresenceLine(presence: model.app?.presence, chatID: ref).text,
                        layout: layout,
                        tab: Binding(get: { selected }, set: { key in
                            switch key {
                            case .builtin(let t): model.navigator?.setDetailTab(t, for: ref)
                            case .pinned(let id): model.navigator?.setDetailAppTab(id, for: ref)
                            }
                        }),
                        opened: model.nav.detailOpenedTab[ref].map(ChatTabKey.pinned),
                        open: { key in
                            if case .pinned(let id) = key { model.navigator?.openDetailAppTab(id, for: ref) }
                        },
                        close: { model.navigator?.closeOpenedTab(for: ref) })
                }
                Divider()
                // The tab body fills the pane, so the header stays pinned
                // to the top whatever the tab shows.
                Group {
                    switch selected {
                    case .builtin(.chat): chatTab(name: name, services: ConversationServices.of(model))
                    case .builtin(.files): FileTable(scope: .conversation(ref))
                    case .builtin(.notes): NotesTab(scope: .conversation(ref))
                    case .builtin(.recap):
                        if let app = model.app {
                            ChatRecapTab(chatID: ref, chatName: name, recordings: app.recordings,
                                         transcripts: app.transcripts)
                        } else {
                            ChatTabPlaceholder(title: "Recap", symbol: ChatTabLayout.symbol(.recap),
                                               message: "Meeting recordings, transcripts and notes show here once the meeting has them.")
                        }
                    case .pinned(let id):
                        if let t = pinned.first(where: { $0.id == id }) {
                            ChatPinnedTabPane(tab: t, chatID: ref)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: ref) { await chatTabs.load(chatID: ref, demo: model.app?.isDemo ?? false) }
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
struct RosterBound<Content: View>: View {
    let chatID: String
    let roster: ChatRosterStore?
    var loads = false
    @ViewBuilder let content: (Int?) -> Content

    var body: some View {
        if let roster {
            Observed(chatID: chatID, roster: roster, loads: loads, content: content)
        } else {
            content(nil)
        }
    }

    private struct Observed: View {
        let chatID: String
        @ObservedObject var roster: ChatRosterStore
        let loads: Bool
        let content: (Int?) -> Content

        var body: some View {
            content(roster.chatID == chatID ? roster.peopleCount : nil)
                .task(id: chatID) {
                    if loads { await roster.load(chatID: chatID) }
                }
        }
    }
}
