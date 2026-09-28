// TeamsCommands.swift — Teams commands, sheet and popover names
// (UI-SPEC §6.3, §11.3 seam). CommandCatalog aggregates this list;
// menu placement is data. Every context-menu item has a menu-bar twin
// here (§6 context menus: "every item also exists in the menu bar").
public enum TeamsCommands {
    /// Join or Create ▸ (Join a Team…, Create Team…), list toolbar.
    public static let joinOrCreate: CommandID = "teams.joinOrCreate"
    public static let createChannel: CommandID = "teams.createChannel"
    public static let manageMembers: CommandID = "teams.manageMembers"
    public static let markTeamRead: CommandID = "teams.markTeamRead"
    public static let markChannelRead: CommandID = "teams.markChannelRead"
    public static let notifications: CommandID = "teams.notifications"
    public static let copyLink: CommandID = "teams.copyLink"
    public static let pinChannel: CommandID = "teams.pinChannel"
    public static let hideChannel: CommandID = "teams.hideChannel"

    /// Submenu args for Join or Create.
    public static let joinArg = "join"
    public static let createArg = "create"

    /// Sheet and popover names (evidence routes, §12).
    public static let createTeamSheet = "createTeam"
    public static let joinTeamSheet = "joinTeam"
    public static let createChannelSheet = "createChannel"
    public static let addMemberSheet = "addMember"

    @MainActor
    public static let all: [Command] = [
        Command(joinOrCreate, "Join or Create Team", symbol: "person.badge.plus",
                menu: .init(.file, group: 0, order: 2), toolbar: .list, isSubmenu: true, owner: .teams),
        Command(createChannel, "Create Channel…", menu: .init(.file, group: 0, order: 3), owner: .teams),
        Command(manageMembers, "Manage Members…", menu: .init(.conversation, group: 4, order: 0), owner: .teams),
        Command(markTeamRead, "Mark Team as Read", menu: .init(.conversation, group: 4, order: 1), owner: .teams),
        Command(markChannelRead, "Mark Channel as Read", menu: .init(.conversation, group: 5, order: 0),
                owner: .teams),
        Command(notifications, "Channel Notifications", menu: .init(.conversation, group: 5, order: 1),
                isSubmenu: true, owner: .teams),
        Command(copyLink, "Copy Channel Link", menu: .init(.conversation, group: 5, order: 2), owner: .teams),
        Command(pinChannel, "Pin Channel", alternateTitle: "Unpin Channel",
                menu: .init(.conversation, group: 5, order: 3), owner: .teams),
        Command(hideChannel, "Hide Channel", alternateTitle: "Show Channel",
                menu: .init(.conversation, group: 5, order: 4), owner: .teams),
    ]
}
