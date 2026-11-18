// ChatCommands.swift — the Chat section's commands, sheets, and
// popovers (UI-SPEC §6.2, §11.3 seams). CommandCatalog aggregates this
// list; menu placement is data on each command.
import AppKit

public enum ChatCommands {
    public static let filter: CommandID = "chat.filter"
    public static let newChat: CommandID = "chat.new"
    public static let audioCall: CommandID = "chat.audioCall"
    public static let videoCall: CommandID = "chat.videoCall"
    /// Meet now (group chats): a meeting on the chat's thread, at once.
    public static let meetNow: CommandID = "chat.meetNow"
    public static let catchUp: CommandID = "chat.catchUp"
    /// The cross-conversation Catch Up in its own window (AICATCH).
    public static let catchUpWindow: CommandID = "chat.catchUpWindow"
    /// ⇧⌘U (Mail-style). Mark as Unread only: no Mark as Read here (owner).
    public static let markUnread: CommandID = "chat.markUnread"
    /// SHORTCUTS-R2: was a planned footnote (⇧⌘I, still Sign In Again);
    /// ships here on ⌃⌘I, wired to the C1 compose importance path.
    public static let markImportant: CommandID = "chat.markImportant"
    /// Teams ⇧⌘X (the compose box): focuses the open conversation's
    /// composer. Group 0 order 8 reserves 2–7 for the message-half menu.
    public static let compose: CommandID = "chat.compose"
    /// Read Aloud (C8d, MSG-13/ACC-01): Edit ▸ Speech ▸, on the
    /// keyboard-selected message.
    public static let speakStart: CommandID = "message.speakStart"
    public static let speakStop: CommandID = "message.speakStop"
    /// The message-half menu (C8c, UI-SPEC §9.1): the context menu's
    /// normal-message actions, acting on the keyboard-selected message
    /// in the open conversation. Orders 2–7, after Mark as Unread (0)
    /// and Pin Chat (1), which stay pinned.
    public static let reply: CommandID = "message.reply"
    public static let forward: CommandID = "message.forward"
    public static let react: CommandID = "message.react"
    public static let save: CommandID = "message.save"
    public static let pinMessage: CommandID = "message.pin"
    public static let translate: CommandID = "message.translate"
    public static let pin: CommandID = "chat.pin"
    /// Chat-level actions on the selected chat (same as the row menu).
    public static let mute: CommandID = "chat.mute"
    public static let snooze: CommandID = "chat.snooze"
    public static let notifications: CommandID = "chat.notifications"
    public static let moveToFolder: CommandID = "chat.moveToFolder"
    public static let hide: CommandID = "chat.hide"
    public static let leave: CommandID = "chat.leave"
    public static let block: CommandID = "chat.block"

    /// Sheet names (§9.5), declared up front so lane P2a (Conversation/)
    /// presents them without editing this folder.
    public static let newChatSheet = "newChat"
    public static let forwardSheet = "forward"
    public static let scheduledSheet = "scheduled"
    public static let snoozeCustomSheet = "snoozeCustom"
    public static let manageFoldersSheet = "manageFolders"
    /// Composer popover names (§6.2.2 `ComposerPopover`).
    public static let mentionPopover = "mention"
    public static let reactionPopover = "reaction"
    public static let gifPopover = "gif"
    public static let sendLaterPopover = "sendLater"

    @MainActor
    public static let all: [Command] = [
        Command(speakStart, "Start Speaking",
                menu: .init(.edit, group: 3, order: 0, submenu: "Speech"), owner: .chat),
        Command(speakStop, "Stop Speaking",
                menu: .init(.edit, group: 3, order: 1, submenu: "Speech"), owner: .chat),
        Command(filter, "Filter", symbol: "line.3.horizontal.decrease",
                menu: .init(.view, group: 2, order: 0), toolbar: .list, isSubmenu: true, owner: .chat),
        Command(newChat, "New Chat", symbol: "square.and.pencil", key: "n",
                menu: .init(.file, group: 0, order: 0), toolbar: .list, owner: .chat),
        Command(audioCall, "Start Audio Call", symbol: "phone",
                menu: .init(.call, group: 0, order: 0), toolbar: .detail, owner: .chat),
        Command(videoCall, "Start Video Call", symbol: "video",
                menu: .init(.call, group: 0, order: 1), toolbar: .detail, owner: .chat,
                help: "Start a video call with everyone in this conversation."),
        Command(meetNow, "Meet Now", symbol: "video.badge.plus",
                menu: .init(.call, group: 0, order: 2), toolbar: .detail, owner: .chat,
                help: "Start a meeting now and invite everyone in this group chat."),
        Command(catchUp, "Catch Up", symbol: "sparkles",
                menu: .init(.conversation, group: 2, order: 0), toolbar: .detail, owner: .chat),
        Command(catchUpWindow, "Open Catch Up in New Window", symbol: "sparkles.rectangle.stack",
                menu: .init(.window, group: 2, order: 0), owner: .chat),
        Command(markUnread, "Mark as Unread", key: "u", modifiers: [.command, .shift],
                menu: .init(.conversation, group: 0, order: 0), owner: .chat),
        Command(markImportant, "Mark as Important", alternateTitle: "Unmark as Important",
                key: "i", modifiers: [.command, .control],
                menu: .init(.conversation, group: 0, order: 9), owner: .chat),
        Command(pin, "Pin Chat", alternateTitle: "Unpin Chat",
                menu: .init(.conversation, group: 0, order: 1), owner: .chat),
        Command(compose, "Go to Compose Box", symbol: "square.and.pencil",
                key: "x", modifiers: [.command, .shift],
                menu: .init(.conversation, group: 0, order: 8), owner: .chat),
        Command(reply, "Reply", key: "r", modifiers: [.command, .option],
                menu: .init(.conversation, group: 0, order: 2), owner: .chat),
        Command(forward, "Forward…",
                menu: .init(.conversation, group: 0, order: 3), owner: .chat),
        Command(react, "React", symbol: "face.smiling",
                menu: .init(.conversation, group: 0, order: 4), isSubmenu: true, owner: .chat),
        Command(save, "Save this message", alternateTitle: "Unsave",
                menu: .init(.conversation, group: 0, order: 5), owner: .chat),
        Command(pinMessage, "Pin", alternateTitle: "Unpin",
                menu: .init(.conversation, group: 0, order: 6), owner: .chat),
        Command(translate, "Translate…",
                menu: .init(.conversation, group: 0, order: 7), owner: .chat),
        Command(mute, "Mute", alternateTitle: "Unmute",
                menu: .init(.conversation, group: 1, order: 0), owner: .chat),
        Command(snooze, "Snooze", menu: .init(.conversation, group: 1, order: 1), isSubmenu: true, owner: .chat),
        Command(notifications, "Notifications",
                menu: .init(.conversation, group: 1, order: 2), isSubmenu: true, owner: .chat),
        Command(moveToFolder, "Move to Folder",
                menu: .init(.conversation, group: 1, order: 3), isSubmenu: true, owner: .chat),
        Command(hide, "Hide Chat", alternateTitle: "Show Chat in List",
                menu: .init(.conversation, group: 1, order: 4), owner: .chat),
        Command(leave, "Leave Chat…", menu: .init(.conversation, group: 3, order: 0), owner: .chat),
        Command(block, "Block…", menu: .init(.conversation, group: 3, order: 1), owner: .chat),
    ]
}
