// ChatRowMenu.swift — the chat row context menu (UI-SPEC §6.2) and the
// chat actions it shares with the Conversation menu: Mute, Snooze ▸,
// Notifications ▸, Move to Folder ▸, Hide, Copy Link, Leave Chat…,
// Block…, Delete…. Parity with the Teams chat menu: tmp/chatsync/
// menu-parity.md (CHATSYNC); Teams-only items show disabled with why.
// Every change applies at once; mute and hide roll back with a quiet
// note under the list if Teams refuses them (RulesStore).
import AppKit
import OstMacCore
import SwiftUI

/// Context menu items for one chat row.
struct ChatRowMenu: View {
    let id: String
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var unread: UnreadStore
    @ObservedObject var rules: RulesStore
    @ObservedObject var snooze: SnoozeStore
    @ObservedObject var folders: FolderStore
    let model: WindowModel?

    var body: some View {
        let isUnread = unread.isUnread(chatID: id)
        Button(isUnread ? "Mark as Read" : "Mark as Unread") {
            // CHATSYNC S3c: on Teams too (read position / bookmark).
            if let app = model?.app {
                app.setChatUnread(id, unread: !isUnread)
            } else if isUnread { unread.markRead(chatID: id) } else { unread.markUnread(chatID: id) }
        }
        Button(chats.isPinned(id) ? "Unpin" : "Pin") {
            if chats.isPinned(id) { chats.unpin(id) } else { chats.pin(id) }
        }
        Divider()
        Button(rules.level(chatID: id) == .muted ? "Unmute" : "Mute") {
            ChatRowActions.toggleMute(id, rules)
        }
        Menu("Snooze") {
            if snooze.isSnoozed(chatID: id) {
                Button("Turn Off Snooze") { snooze.unsnooze(chatID: id) }
                Divider()
            }
            ForEach(SnoozeDuration.allCases, id: \.rawValue) { d in
                Button(InfoPane.title(d)) { snooze.snooze(chatID: id, duration: d) }
            }
            Divider()
            Button("Custom…") { ChatRowActions.customSnooze(id, model) }
        }
        Menu("Notifications") {
            ForEach(ChatRowActions.levels, id: \.level) { item in
                Toggle(item.title, isOn: Binding(get: { rules.level(chatID: id) == item.level },
                                                 set: { if $0 { rules.setLevel(chatID: id, level: item.level) } }))
            }
        }
        Menu("Move to Folder") {
            // Teams folders (Favorites, folders made in Teams): the move
            // is saved to Teams, so it shows in Teams too.
            if folders.serverMover != nil, !folders.serverFolders.isEmpty {
                ForEach(folders.serverFolders) { f in
                    Toggle(f.name, isOn: Binding(
                        get: { folders.overrides[id] == nil && folders.serverAssignments[id] == f.id },
                        set: { on in Task { await folders.moveOnServer(chatID: id, to: on ? f.id : nil) } }))
                }
                .disabled(folders.movingIDs.contains(id))
                Divider()
            }
            ForEach(folders.folders) { f in
                Toggle(f.name, isOn: Binding(get: { folders.overrides[id] == f.id },
                                             set: { folders.assign(chatID: id, folderID: $0 ? f.id : nil) }))
            }
            if folders.overrides[id] != nil {
                Divider()
                Button("Remove from Folder") { folders.assign(chatID: id, folderID: nil) }
            }
            if !folders.folders.isEmpty || folders.overrides[id] != nil { Divider() }
            Button("New Folder…") { ChatRowActions.newFolder(id, model) }
        }
        Divider()
        Button(rules.isHidden(chatID: id) ? "Show in Chat List" : "Hide") {
            rules.setHidden(chatID: id, hidden: !rules.isHidden(chatID: id))
        }
        Button("Copy Link") { ChatRowActions.copyLink(id) }
        // Teams items this app does not offer yet: shown, disabled, why.
        Button("Pop Out Chat (not available yet)") {}.disabled(true)
        if let row = chats.chat(id: id) {
            if row.is_group {
                Button("Invite via Link (not available yet)") {}.disabled(true)
                    .help("Teams group-invite links are not in this app yet.")
                Button("Workflows (not available yet)") {}.disabled(true)
                    .help("Chat workflows (Power Automate) are not in this app yet.")
                Button("Manage Apps (not available yet)") {}.disabled(true)
                    .help("Teams apps in a chat are not in this app yet.")
            } else if !ChatListFilter.isSelfChat(id) {
                Button("Notify When Available (not available yet)") {}.disabled(true)
                    .help("Presence alerts are not in this app yet.")
            }
        }
        Divider()
        if let row = chats.chat(id: id) {
            if row.is_group {
                Button("Leave Chat…") { ChatRowActions.leave(id, chats, model) }
                    .disabled(chats.leavingIDs.contains(id))
            } else if !ChatListFilter.isSelfChat(id) {
                Button("Block…") { ChatRowActions.block(id, chats, model) }
            }
            if !ChatListFilter.isSelfChat(id) {
                Button("Delete…", role: .destructive) { ChatRowActions.delete(id, chats, model) }
                    .disabled(chats.deletingIDs.contains(id))
            }
        }
    }
}

/// The chat actions behind the row menu and the Conversation menu.
@MainActor
enum ChatRowActions {
    struct LevelItem { let title: String; let level: ChatNotifyLevel }
    static let levels = [LevelItem(title: "All Messages", level: .all),
                         LevelItem(title: "Mentions Only", level: .mentions),
                         LevelItem(title: "Off", level: .muted)]

    static let newFolderSheet = "newFolder"

    static func toggleMute(_ id: String, _ rules: RulesStore) {
        rules.setLevel(chatID: id, level: rules.level(chatID: id) == .muted ? .all : .muted)
    }

    static func customSnooze(_ id: String, _ m: WindowModel?) {
        m?.presentSheet(SheetRequest(ChatCommands.snoozeCustomSheet, in: .chat, arg: id))
    }

    static func newFolder(_ id: String, _ m: WindowModel?) {
        m?.presentSheet(SheetRequest(newFolderSheet, in: .chat, arg: id))
    }

    static func name(_ id: String, _ chats: ChatListViewModel) -> String {
        chats.chat(id: id)?.name ?? "this chat"
    }

    static func leave(_ id: String, _ chats: ChatListViewModel, _ m: WindowModel?) {
        m?.confirm(title: "Leave \(name(id, chats))?",
                   message: "You won't get new messages from this chat.",
                   action: "Leave", perform: { Task { await chats.leave(chatID: id) } })
    }

    /// Delete chat, as Teams: history cleared for you only; the row
    /// leaves once Teams accepts it (ChatListViewModel.delete).
    static func delete(_ id: String, _ chats: ChatListViewModel, _ m: WindowModel?) {
        m?.confirm(title: "Delete this chat?",
                   message: "The chat and its history will be removed from your chat list. "
                       + "Other people in the chat keep it. It comes back if someone sends a new message.",
                   action: "Delete", perform: { Task { await chats.delete(chatID: id) } })
    }

    /// Teams chat link (the /l/chat form CardActions opens).
    static func link(_ id: String) -> String {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":@"))) ?? id
        return "https://teams.microsoft.com/l/chat/\(enc)/conversations"
    }

    static func copyLink(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link(id), forType: .string)
    }

    static func block(_ id: String, _ chats: ChatListViewModel, _ m: WindowModel?) {
        m?.confirm(title: "Block \(name(id, chats))?",
                   message: "Their messages won't notify you, and the chat leaves your list. Unblock them in Settings.",
                   action: "Block", perform: { chats.block(chatID: id) })
    }
}

/// New Folder… from Move to Folder: names a folder of this app and
/// moves the chat into it.
struct NewFolderSheet: View {
    let chatID: String
    @ObservedObject var folders: FolderStore
    @State private var name = ""
    @Environment(\.windowModel) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.headline)
            TextField("Folder Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model?.dismissSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var isValid: Bool {
        ManageFoldersSheet.isValid(folders.folders.map(\.name) + [name])
    }

    private func create() {
        guard isValid, let f = folders.createFolder(name: name) else { return }
        folders.assign(chatID: chatID, folderID: f.id)
        model?.dismissSheet()
    }
}
