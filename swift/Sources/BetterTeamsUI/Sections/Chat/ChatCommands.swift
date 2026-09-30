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
        Command(pin, "Pin Chat", alternateTitle: "Unpin Chat",
                menu: .init(.conversation, group: 0, order: 1), owner: .chat),
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
