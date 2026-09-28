// ChatCommands.swift — the Chat section's commands, sheets, and
// popovers (UI-SPEC §6.2, §11.3 seams). CommandCatalog aggregates this
// list; menu placement is data on each command.
import AppKit

public enum ChatCommands {
    public static let filter: CommandID = "chat.filter"
    public static let newChat: CommandID = "chat.new"
    public static let audioCall: CommandID = "chat.audioCall"
    public static let videoCall: CommandID = "chat.videoCall"
    public static let catchUp: CommandID = "chat.catchUp"
    public static let markUnread: CommandID = "chat.markUnread"
    public static let pin: CommandID = "chat.pin"

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
        Command(catchUp, "Catch Up", symbol: "sparkles",
                menu: .init(.conversation, group: 2, order: 0), toolbar: .detail, owner: .chat),
        Command(markUnread, "Mark as Unread", alternateTitle: "Mark as Read", key: "u", modifiers: [.command, .shift],
                menu: .init(.conversation, group: 0, order: 0), owner: .chat),
        Command(pin, "Pin Chat", alternateTitle: "Unpin Chat",
                menu: .init(.conversation, group: 0, order: 1), owner: .chat),
    ]
}
