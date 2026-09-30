// ActivityCommands.swift — Activity commands (UI-SPEC §6.1, §11.3
// seam). CommandCatalog aggregates this list; menu placement is data.
public enum ActivityCommands {
    public static let filter: CommandID = "activity.filter"
    public static let markAllRead: CommandID = "activity.markAllRead"
    public static let markRead: CommandID = "activity.markRead"
    /// ⇧⌘S: Activity filtered to saved messages.
    public static let showSaved: CommandID = "activity.showSaved"

    @MainActor
    public static let all: [Command] = [
        Command(filter, "Filter Activity", symbol: "line.3.horizontal.decrease",
                menu: .init(.view, group: 2, order: 1), toolbar: .list, isSubmenu: true, owner: .activity),
        Command(markAllRead, "Mark All Activity as Read", symbol: "checkmark.circle",
                menu: .init(.conversation, group: 3, order: 0), toolbar: .list, owner: .activity),
        Command(markRead, "Mark Item as Read", alternateTitle: "Mark Item as Unread",
                menu: .init(.conversation, group: 3, order: 1), owner: .activity),
        Command(showSaved, "Saved Messages", symbol: "bookmark", key: "s", modifiers: [.command, .shift],
                menu: .init(.go, group: 1, order: 3), owner: .activity),
    ]
}
