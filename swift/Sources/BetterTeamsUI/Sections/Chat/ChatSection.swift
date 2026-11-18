// ChatSection.swift — Chat section provider (UI-SPEC §6.2).
//
// List = chats (Pinned, then Recent); detail = the conversation;
// inspector = Info | Catch Up | Pinned. Loads start in
// `selectionDidChange` (R24), never in a view.
import Combine
import Observation
import OstMacCore
import SwiftUI

/// UI-only chat list filter (§6.2 Filter menu).
enum ChatFilter: Equatable {
    case all, unread, mentions, muted, snoozed, hidden
    case folder(String)

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .mentions: "Mentions"
        case .muted: "Muted"
        case .snoozed: "Snoozed"
        case .hidden: "Hidden"
        case .folder: "Folder"
        }
    }

    var arg: String {
        switch self {
        case .all: "all"
        case .unread: "unread"
        case .mentions: "mentions"
        case .muted: "muted"
        case .snoozed: "snoozed"
        case .hidden: "hidden"
        case .folder(let id): "folder:\(id)"
        }
    }

    init(arg: String) {
        switch arg {
        case "unread": self = .unread
        case "mentions": self = .mentions
        case "muted": self = .muted
        case "snoozed": self = .snoozed
        case "hidden": self = .hidden
        case _ where arg.hasPrefix("folder:"): self = .folder(String(arg.dropFirst(7)))
        default: self = .all
        }
    }
}

extension ChatFilter {
    /// Empty-state wording per filter (Teams: "No unread chats" etc.).
    func emptyTitle(folderName: String?) -> String {
        switch self {
        case .all: "No Chats"
        case .folder: "No Chats in \(folderName ?? "This Folder")"
        default: "No \(title) Chats"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Chats you start or join appear here."
        case .unread: "You're all caught up."
        case .mentions: "Chats where someone @mentions you appear here."
        case .muted: "Chats you mute appear here."
        case .snoozed: "Chats you snooze appear here."
        case .hidden: "Chats you hide appear here."
        case .folder: "Chats you move to this folder appear here."
        }
    }
}

/// The stores a chat list filter reads (one rule set for the pane's
/// rows and the pager's match count).
@MainActor
struct ChatFilterRules {
    let unread: UnreadStore
    let mentions: MentionStore
    let rules: RulesStore
    let snooze: SnoozeStore
    let folders: FolderStore

    /// Hidden chats leave every view but Hidden (§6.2 Filter menu).
    func apply(_ filter: ChatFilter, to list: [ChatItem]) -> [ChatItem] {
        if filter == .hidden { return list.filter { rules.isHidden(chatID: $0.id) } }
        let shown = list.filter { !rules.isHidden(chatID: $0.id) }
        switch filter {
        case .all, .hidden: return shown
        case .unread: return shown.filter { unread.isUnread(chatID: $0.id) }
        case .mentions: return shown.filter { mentions.contains(chatID: $0.id) }
        case .muted: return shown.filter { rules.level(chatID: $0.id) == .muted }
        case .snoozed: return shown.filter { snooze.isSnoozed(chatID: $0.id) }
        case .folder(let id): return shown.filter { folders.folderID(for: $0) == id }
        }
    }
}

@Observable
@MainActor
final class ChatSectionState {
    /// Set through `select`/`toggle`/`clear` (they drive the pager).
    private(set) var filter: ChatFilter = .all
    /// Bounded look through older pages for more matches (never the
    /// whole history); always ends in `.finished`.
    @ObservationIgnored let pager: ChatFilterPager
    /// Full-list rows on screen (row appear/disappear), for the scroll
    /// position the list returns to when a filter clears.
    @ObservationIgnored var visibleIDs: Set<String> = []
    /// Top full-list row when the filter was entered.
    @ObservationIgnored private(set) var returnAnchor: String?

    init(pager: ChatFilterPager? = nil) {
        self.pager = pager ?? ChatFilterPager()
    }

    /// Apply `f` to the rows already loaded (at once); with few matches,
    /// look a bounded way further back.
    func select(_ f: ChatFilter, list: ChatListViewModel, rules: ChatFilterRules) {
        guard f != .all else { return clear() }
        if filter == .all {
            returnAnchor = list.displayChats.first { visibleIDs.contains($0.id) }?.id
        }
        filter = f
        pager.start(list) { rules.apply(f, to: list.displayChats).count }
    }

    /// Menu/filter-bar click: the active filter again turns it off
    /// (as in Teams), any other one switches to it.
    func toggle(_ f: ChatFilter, list: ChatListViewModel, rules: ChatFilterRules) {
        if f == filter { clear() } else { select(f, list: list, rules: rules) }
    }

    /// A filter from a route: the rows already loaded, no look-back.
    func show(_ f: ChatFilter) {
        pager.cancel()
        filter = f
    }

    /// Back to the full list (filter bar X, Esc, "Show All Chats").
    func clear() {
        pager.cancel()
        filter = .all
    }

    /// Another bounded look further back (the "Check Older Chats" link).
    func searchOlder(list: ChatListViewModel, rules: ChatFilterRules) {
        let f = filter
        guard f != .all else { return }
        pager.start(list) { rules.apply(f, to: list.displayChats).count }
    }
}

@MainActor
final class ChatSection: SectionProvider, InspectorCapable {
    let section: SectionID = .chat
    let title = "Chat"
    let hasInspector = true
    let state = ChatSectionState()
    /// Fallback for side-account graphs (mentions live on AppState).
    private lazy var noMentions = MentionStore()
    private lazy var noPresence = PresenceStore()

    func subtitle(_ m: WindowModel) -> String {
        let n = m.graph.unread.chatCount
        return n > 0 ? "\(n) unread" : ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        let services = ConversationServices.of(m)
        return AnyView(ChatListPane(chats: m.graph.chats, unread: m.graph.unread,
                                    mentions: m.app?.mentions ?? noMentions,
                                    rules: services.rules(m), snooze: services.snooze(m),
                                    failures: services.sendFailures,
                                    presence: m.app?.presence ?? noPresence,
                                    pager: state.pager, state: state,
                                    settings: .shared,
                                    teams: m.app?.teams,
                                    chanPrefs: (m.provider(.teams) as? TeamsSection)?.prefs(m)))
    }

    func filterRules(_ m: WindowModel) -> ChatFilterRules {
        let services = ConversationServices.of(m)
        return ChatFilterRules(unread: m.graph.unread, mentions: m.app?.mentions ?? noMentions,
                               rules: services.rules(m), snooze: services.snooze(m),
                               folders: m.graph.chats.folders)
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        AnyView(ChatDetailPane(conv: m.graph.conv, chats: m.graph.chats))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        AnyView(ChatInspectorPane(chats: m.graph.chats, unread: m.graph.unread))
    }

    var allToolbarItems: [CommandID] {
        [ChatCommands.filter, ChatCommands.newChat] + ConversationToolbar.items
    }

    func toolbarItems(_ sel: SectionSelection?) -> [CommandID] {
        sel == nil ? [ChatCommands.filter, ChatCommands.newChat] : allToolbarItems
    }

    /// `chat/<id>?message=<mid>` opens the chat landed on that message
    /// (jump API + highlight; a miss shows the notice).
    func selection(for route: Route) -> SectionSelection? {
        // `chat?filter=unread`: open Chat with that filter on (the
        // loaded rows only; no look-back from a link).
        if let f = route.query["filter"] { state.show(ChatFilter(arg: f)) }
        // Evidence only: `chat?combined=1` renders the combined
        // chats+channels view for captures. Memory defaults are the
        // demo's (AppSettings.useDemoStorage), so a real profile's
        // switch is never touched.
        if route.query["combined"] == "1", AppSettings.shared.isMemory {
            AppSettings.shared.combinedChatsChannels = true
        }
        guard let id = route.tail.first else { return nil }
        if let mid = route.query["message"], !mid.isEmpty { return SectionSelection([id, mid]) }
        return SectionSelection(id: id)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        if let sel, sel.path.count > 1, let id = sel.id, let app = m.app {
            app.jumpToMessage(SearchHit(messageID: sel.path[1], chatID: id, sender: "", timestamp: "", preview: ""))
            return
        }
        guard let id = sel?.id, m.graph.openChatID != id else { return }
        m.graph.openChat(id: id, name: m.graph.chats.chat(id: id)?.name)
        ConversationEvidence.seed(m, chatID: id)
    }

    func badge(_ m: WindowModel) -> Int? {
        let n = m.graph.unread.chatCount
        return n > 0 ? n : nil
    }

    func badgeChanges(_ m: WindowModel) -> [AnyPublisher<Void, Never>] {
        [m.graph.unread.objectWillChange.map { _ in () }.eraseToAnyPublisher()]
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        switch r.name {
        case ChatCommands.newChatSheet: AnyView(NewChatSheet(chats: m.graph.chats,
                                                                 contacts: NewChatSheet.directory(m.app, demo: m.options.demo),
                                                                 presence: m.app?.presence ?? noPresence))
        case ChatCommands.manageFoldersSheet: AnyView(ManageFoldersSheet(folders: m.graph.chats.folders, startOnRules: m.options.demo && r.arg == "rules"))
        case ChatManageActions.renameSheet:
            AnyView(RenameChatSheet(chatID: r.arg ?? "", chats: m.graph.chats,
                                    roster: m.app?.chatRoster, ownUserID: m.app?.ownUserID))
        case ChatManageActions.addPeopleSheet:
            AnyView(AddPeopleSheet(chatID: r.arg ?? "", chats: m.graph.chats,
                                   contacts: NewChatSheet.directory(m.app, demo: m.options.demo),
                                   roster: m.app?.chatRoster, demo: m.options.demo))
        case ChatRowActions.newFolderSheet:
            AnyView(NewFolderSheet(chatID: r.arg ?? "", folders: m.graph.chats.folders))
        case ContactActions.sheetName:
            // Full contact card (any surface presents it through Chat).
            AnyView(ContactCardSheet(initial: r.arg.flatMap(ContactRef.init(encoded:))
                ?? ContactRef(name: m.options.demo ? "Megan Harper" : (m.ownDisplayName))))
        default: ConversationSheets.view(r, m)
        }
    }

    // MARK: commands

    private func selected(_ m: WindowModel) -> String? {
        m.nav.search == nil ? m.nav.selection(in: .chat)?.id : nil
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        switch c {
        case ChatCommands.newChat:
            m.presentSheet(SheetRequest(ChatCommands.newChatSheet, in: .chat))
        case ChatCommands.filter where arg == ChatCommands.manageFoldersSheet:
            m.presentSheet(SheetRequest(ChatCommands.manageFoldersSheet, in: .chat))
        case ChatCommands.filter:
            state.toggle(ChatFilter(arg: arg ?? "all"), list: m.graph.chats, rules: filterRules(m))
        case ChatCommands.audioCall:
            return ConversationToolbar.startAudioCall(m) != nil
        case ChatCommands.videoCall:
            return ConversationToolbar.startVideoCall(m) != nil
        case ChatCommands.meetNow:
            return ConversationToolbar.meetNow(m)
        case ChatCommands.catchUp:
            guard let id = ConversationToolbar.chatID(m) else { return false }
            // The Catch Up inspector lives in Chat: other hosts (Activity,
            // Search) open the conversation there first.
            if m.nav.section != .chat || m.nav.search != nil {
                m.navigator?.endSearch()
                m.navigator?.select(section: .chat)
                m.navigator?.select(SectionSelection(id: id), in: .chat)
            }
            m.setInspectorSegment(InspectorSegment.catchup.rawValue)
            m.navigator?.setInspector(true, explicit: true)
            CatchUpRunner.run(m, chatID: id)
        case ChatCommands.catchUpWindow:
            guard m.app?.catchUp.mode ?? .off != .off else { return false }
            CatchUpWindowController.show(m)
        case ChatCommands.reply, ChatCommands.forward, ChatCommands.react,
             ChatCommands.save, ChatCommands.pinMessage, ChatCommands.translate:
            return performMessageAction(c, arg: arg, m)
        case ChatCommands.speakStart:
            guard let text = speechText(m) else { return false }
            SpeechReader.speak(text)
        case ChatCommands.speakStop:
            guard SpeechReader.speaking else { return false }
            SpeechReader.stop()
        case ChatCommands.compose:
            // Teams ⇧⌘X: the open conversation's composer takes focus.
            guard ConversationToolbar.chatID(m) != nil else { return false }
            ConversationServices.of(m).composer.focusRequest += 1
        case ChatCommands.markImportant:
            // SHORTCUTS-R2: toggle Important on the open conversation's
            // draft through the C1 compose path (the send carries it).
            guard let id = ConversationToolbar.chatID(m) else { return false }
            let composer = ConversationServices.of(m).composer
            composer.setImportance(
                composer.importance(for: id) == .important ? .normal : .important, for: id)
        case ChatCommands.markUnread:
            // Same semantics as the message menu's Mark as Unread: Teams
            // bookmarks just behind the NEWEST loaded message.
            guard let id = selected(m) else { return false }
            let conv = m.graph.conv
            let newest = conv.chatID == id ? ReadSync.latest(conv.messages) : nil
            if let app = m.app, app.chats.chat(id: id) != nil {
                app.setChatUnread(id, unread: true, newest: newest)
            } else {
                m.graph.unread.markUnread(chatID: id)
            }
        case ChatCommands.pin:
            guard let id = selected(m) else { return false }
            if m.graph.chats.isPinned(id) { m.graph.chats.unpin(id) } else { m.graph.chats.pin(id) }
        case ChatCommands.mute, ChatCommands.snooze, ChatCommands.notifications, ChatCommands.moveToFolder,
             ChatCommands.hide, ChatCommands.leave, ChatCommands.block:
            guard let id = selected(m) else { return false }
            return performChatAction(c, arg: arg, id: id, m)
        default:
            return false
        }
        return true
    }

    /// Conversation menu chat actions (the row menu's, on the selection).
    private func performChatAction(_ c: CommandID, arg: String?, id: String, _ m: WindowModel) -> Bool {
        let services = ConversationServices.of(m)
        let rules = services.rules(m), snooze = services.snooze(m)
        let chats = m.graph.chats, folders = m.graph.chats.folders
        switch c {
        case ChatCommands.mute:
            ChatRowActions.toggleMute(id, rules)
        case ChatCommands.snooze:
            switch arg {
            case "off": snooze.unsnooze(chatID: id)
            case "custom": ChatRowActions.customSnooze(id, m)
            default:
                guard let d = arg.flatMap(SnoozeDuration.init(rawValue:)) else { return false }
                snooze.snooze(chatID: id, duration: d)
            }
        case ChatCommands.notifications:
            guard let level = arg.flatMap(ChatNotifyLevel.init(rawValue:)) else { return false }
            rules.setLevel(chatID: id, level: level)
        case ChatCommands.moveToFolder:
            switch arg {
            case "new": ChatRowActions.newFolder(id, m)
            case "none": folders.assign(chatID: id, folderID: nil)
            default:
                guard let f = arg else { return false }
                if folders.isServerFolder(f) {
                    Task { await folders.moveOnServer(chatID: id, to: f) }
                } else {
                    folders.assign(chatID: id, folderID: f)
                }
            }
        case ChatCommands.hide:
            rules.setHidden(chatID: id, hidden: !rules.isHidden(chatID: id))
        case ChatCommands.leave:
            guard chats.chat(id: id)?.is_group == true else { return false }
            ChatRowActions.leave(id, chats, m)
        case ChatCommands.block:
            guard chats.chat(id: id)?.is_group == false else { return false }
            ChatRowActions.block(id, chats, m)
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        let inChat = m.nav.section == .chat && m.nav.search == nil
        switch c {
        case ChatCommands.newChat: return .enabled
        case ChatCommands.filter: return CommandValidation(enabled: inChat)
        case ChatCommands.catchUp:
            // Any host of the conversation view; nothing to summarize in
            // a chat with no messages.
            // Off hides the button (Navigator) and disables the item.
            guard let id = ConversationToolbar.chatID(m), m.app?.catchUp.mode ?? .off != .off else { return .disabled }
            return CommandValidation(enabled: m.graph.conv.chatID == id && !m.graph.conv.messages.isEmpty)
        case ChatCommands.catchUpWindow:
            return CommandValidation(enabled: m.app?.catchUp.mode ?? .off != .off)
        case ChatCommands.markUnread:
            return CommandValidation(enabled: inChat && selected(m) != nil)
        case ChatCommands.markImportant:
            // Any host showing a conversation (like Go to Compose Box);
            // the title follows the draft's current level.
            guard let id = ConversationToolbar.chatID(m) else { return .disabled }
            let level = ConversationServices.of(m).composer.importance(for: id)
            return CommandValidation(
                enabled: true,
                title: level == .important ? "Unmark as Important" : "Mark as Important")
        case ChatCommands.compose:
            // Any host showing a conversation (Chat, Activity, Search).
            return CommandValidation(enabled: ConversationToolbar.chatID(m) != nil)
        case ChatCommands.reply, ChatCommands.forward, ChatCommands.react,
             ChatCommands.save, ChatCommands.pinMessage, ChatCommands.translate:
            return validateMessageAction(c, m)
        case ChatCommands.speakStart:
            return CommandValidation(enabled: speechText(m) != nil)
        case ChatCommands.speakStop:
            return CommandValidation(enabled: SpeechReader.speaking)
        case ChatCommands.pin:
            guard inChat, let id = selected(m) else { return .disabled }
            return CommandValidation(enabled: true, title: m.graph.chats.isPinned(id) ? "Unpin Chat" : "Pin Chat")
        case ChatCommands.mute, ChatCommands.snooze, ChatCommands.notifications, ChatCommands.moveToFolder,
             ChatCommands.hide, ChatCommands.leave, ChatCommands.block:
            guard inChat, let id = selected(m) else { return .disabled }
            let rules = ConversationServices.of(m).rules(m)
            let row = m.graph.chats.chat(id: id)
            switch c {
            case ChatCommands.mute:
                return CommandValidation(enabled: true, title: rules.level(chatID: id) == .muted ? "Unmute" : "Mute")
            case ChatCommands.hide:
                return CommandValidation(enabled: true,
                                         title: rules.isHidden(chatID: id) ? "Show Chat in List" : "Hide Chat")
            case ChatCommands.leave:
                return CommandValidation(enabled: row?.is_group == true && !m.graph.chats.leavingIDs.contains(id))
            case ChatCommands.block:
                return CommandValidation(enabled: row?.is_group == false && !ChatListFilter.isSelfChat(id))
            default:
                return .enabled
            }
        case ChatCommands.audioCall:
            return CommandValidation(enabled: ConversationToolbar.canStartCall(m))
        case ChatCommands.videoCall:
            // Every conversation: 1:1 (VIDEO1), group chats and meeting
            // chats (MEETVIDEO: the meeting tile grid).
            return CommandValidation(enabled: ConversationToolbar.canStartVideoCall(m))
        case ChatCommands.meetNow:
            return CommandValidation(enabled: ConversationToolbar.canMeetNow(m))
        default:
            return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        if c != ChatCommands.filter { return chatActionItems(c, m) }
        let enabled = m.nav.section == .chat
        var out = [ChatFilter.all, .unread, .mentions, .muted, .snoozed, .hidden].map {
            SubmenuItem($0.title, arg: $0.arg, checked: state.filter == $0, enabled: enabled)
        }
        var first = true
        for f in m.graph.chats.folders.allFolders {
            let filter = ChatFilter.folder(f.id)
            out.append(SubmenuItem(f.name, arg: filter.arg, symbol: "folder", checked: state.filter == filter,
                                   enabled: enabled, separatorBefore: first))
            first = false
        }
        out.append(SubmenuItem("Manage Folders…", arg: ChatCommands.manageFoldersSheet, enabled: enabled,
                               separatorBefore: true))
        return out
    }

    /// Snooze ▸, Notifications ▸ and Move to Folder ▸ for the selection.
    private func chatActionItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        if c == ChatCommands.react { return reactItems(m) }
        guard m.nav.section == .chat, let id = selected(m) else { return [] }
        let services = ConversationServices.of(m)
        switch c {
        case ChatCommands.snooze:
            let snooze = services.snooze(m)
            var out: [SubmenuItem] = []
            if snooze.isSnoozed(chatID: id) { out.append(SubmenuItem("Turn Off Snooze", arg: "off")) }
            var first = !out.isEmpty
            for d in SnoozeDuration.allCases {
                out.append(SubmenuItem(InfoPane.title(d), arg: d.rawValue, separatorBefore: first))
                first = false
            }
            out.append(SubmenuItem("Custom…", arg: "custom", separatorBefore: true))
            return out
        case ChatCommands.notifications:
            let level = services.rules(m).level(chatID: id)
            return ChatRowActions.levels.map {
                SubmenuItem($0.title, arg: $0.level.rawValue, checked: level == $0.level)
            }
        case ChatCommands.moveToFolder:
            let folders = m.graph.chats.folders
            let current = folders.overrides[id]
            var out = folders.folders.map { SubmenuItem($0.name, arg: $0.id, symbol: "folder", checked: current == $0.id) }
            if current != nil { out.append(SubmenuItem("Remove from Folder", arg: "none", separatorBefore: true)) }
            out.append(SubmenuItem("New Folder…", arg: "new", separatorBefore: !out.isEmpty))
            return out
        default:
            return []
        }
    }

    /// The conversation whose message menu is on screen (C8c): Chat,
    /// Activity, and Search resolve through the toolbar helper; Teams
    /// channel posts read the open channel's conversation.
    static func messageChatID(_ m: WindowModel) -> String? {
        if let id = ConversationToolbar.chatID(m) { return id }
        if m.nav.section == .teams, m.nav.search == nil { return m.graph.conv.chatID }
        return nil
    }

    /// The keyboard-selected message's live row, if it is a normal
    /// message in the open conversation (failed sends and tombstones
    /// keep the context menu's own Retry/Delete items only).
    private func messageTarget(_ m: WindowModel) -> (TimelineActions, ChatMessage)? {
        guard let id = Self.messageChatID(m),
              let actions = ConversationServices.of(m).messageActions,
              let sel = actions.keyboard.selected, sel.chatID == id,
              let msg = actions.message(id: sel.messageID),
              !msg.deleted, !m.graph.conv.failedIDs.contains(msg.id),
              !m.graph.conv.deleteFailedIDs.contains(msg.id) else { return nil }
        return (actions, msg)
    }

    private func performMessageAction(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let (actions, msg) = messageTarget(m) else { return false }
        switch c {
        case ChatCommands.reply: actions.reply(msg)
        case ChatCommands.forward: actions.forward(msg)
        case ChatCommands.react:
            let emoji = arg ?? ""
            if emoji == "more" { actions.moreReactions(msg) } else { actions.react(msg, emoji) }
        case ChatCommands.save: actions.toggleSave(msg)
        case ChatCommands.pinMessage: actions.togglePin(msg)
        case ChatCommands.translate: actions.translate(msg)
        default: return false
        }
        return true
    }

    private func validateMessageAction(_ c: CommandID, _ m: WindowModel) -> CommandValidation {
        guard let (actions, msg) = messageTarget(m) else { return .disabled }
        switch c {
        case ChatCommands.save:
            let saved = m.graph.savedMessages.isSaved(chatID: Self.messageChatID(m), messageID: msg.id)
            return CommandValidation(enabled: true, title: SavedMessages.menuTitle(isSaved: saved))
        case ChatCommands.pinMessage:
            let pinned = m.graph.pinnedMessages.isPinned(chatID: Self.messageChatID(m), messageID: msg.id)
            return CommandValidation(enabled: true, title: PinnedMessages.menuTitle(isPinned: pinned))
        case ChatCommands.translate:
            return CommandValidation(enabled: MessageTranslation.isEligible(msg),
                                     title: actions.translateTitle(msg))
        default:
            return .enabled
        }
    }

    /// The selected message's plain text for Read Aloud (bubble text, as
    /// the row's VoiceOver label reads it).
    private func speechText(_ m: WindowModel) -> String? {
        guard let (_, msg) = messageTarget(m) else { return nil }
        let t = MessageRender.bubbleText(for: msg).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// React ▸ for the selection: the six quick reactions, then More….
    private func reactItems(_ m: WindowModel) -> [SubmenuItem] {
        guard messageTarget(m) != nil else { return [] }
        var out = HoverToolbarRules.quickReactions.map {
            SubmenuItem("\($0.emoji) \($0.name)", arg: $0.emoji)
        }
        out.append(SubmenuItem("More…", arg: "more", separatorBefore: true))
        return out
    }

    /// Go ▸ Next/Previous Unread Chat (⌥⌘↓/↑).
    func stepUnread(forward: Bool, _ m: WindowModel) {
        let list = m.graph.chats.displayChats
        guard !list.isEmpty else { return }
        let current = m.nav.selection(in: .chat)?.id
        let start = current.flatMap { id in list.firstIndex { $0.id == id } } ?? (forward ? -1 : list.count)
        let order = forward ? Array(list.indices.filter { $0 > start }) : Array(list.indices.filter { $0 < start }.reversed())
        guard let hit = order.first(where: { m.graph.unread.isUnread(chatID: list[$0].id) }) else { return }
        m.navigator?.select(section: .chat)
        m.navigator?.select(SectionSelection(id: list[hit].id), in: .chat)
    }
}

/// Detail pane: the selected conversation, else "No Chat Selected".
struct ChatDetailPane: View {
    @ObservedObject var conv: ConversationStore
    @ObservedObject var chats: ChatListViewModel
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let id = model.nav.selection(in: .chat)?.id, model.forced(.chat) == nil {
            ConversationDetail(ref: id, conv: conv, chats: chats)
        } else {
            NoSelectionPane("No Chat Selected")
        }
    }
}

struct ChatInspectorPane: View {
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    @Environment(\.windowModel) private var model

    var body: some View {
        ConversationInspector(ref: model?.nav.selection(in: .chat)?.id, chats: chats, unread: unread)
    }
}
