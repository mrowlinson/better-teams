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
    public static let manageChannel: CommandID = "teams.manageChannel"
    public static let channelEmail: CommandID = "teams.channelEmail"
    public static let editChannel: CommandID = "teams.editChannel"
    public static let deleteChannel: CommandID = "teams.deleteChannel"
    public static let openChannelWindow: CommandID = "teams.openChannelWindow"
    public static let moveChannelToSection: CommandID = "teams.moveChannelToSection"
    public static let channelWorkflows: CommandID = "teams.channelWorkflows"
    public static let hideTeam: CommandID = "teams.hideTeam"
    public static let teamLink: CommandID = "teams.teamLink"
    public static let leaveTeam: CommandID = "teams.leaveTeam"

    /// Submenu args for Join or Create.
    public static let joinArg = "join"
    public static let createArg = "create"

    /// Sheet and popover names (evidence routes, §12).
    public static let createTeamSheet = "createTeam"
    public static let joinTeamSheet = "joinTeam"
    public static let createChannelSheet = "createChannel"
    public static let addMemberSheet = "addMember"
    public static let editChannelSheet = "editChannel"

    @MainActor
    public static let all: [Command] = [
        Command(joinOrCreate, "Join or Create Team", symbol: "person.badge.plus",
                menu: .init(.file, group: 0, order: 2), toolbar: .list, isSubmenu: true, owner: .teams),
        Command(createChannel, "Create Channel…", menu: .init(.file, group: 0, order: 3), owner: .teams),
        Command(manageMembers, "Manage Members…", menu: .init(.conversation, group: 4, order: 0), owner: .teams),
        Command(markTeamRead, "Mark Team as Read", menu: .init(.conversation, group: 4, order: 1), owner: .teams),
        Command(openChannelWindow, "Open Channel in New Window", symbol: "macwindow.badge.plus",
                menu: .init(.conversation, group: 5, order: 0), owner: .teams),
        Command(markChannelRead, "Mark Channel as Read", menu: .init(.conversation, group: 5, order: 1),
                owner: .teams),
        Command(notifications, "Channel Notifications", menu: .init(.conversation, group: 5, order: 2),
                isSubmenu: true, owner: .teams),
        Command(moveChannelToSection, "Move Channel to Section", menu: .init(.conversation, group: 5, order: 3),
                isSubmenu: true, owner: .teams),
        Command(pinChannel, "Pin Channel", alternateTitle: "Unpin Channel",
                menu: .init(.conversation, group: 5, order: 4), owner: .teams),
        Command(hideChannel, "Hide Channel", alternateTitle: "Show Channel",
                menu: .init(.conversation, group: 5, order: 5), owner: .teams),
        Command(editChannel, "Edit Channel…", menu: .init(.conversation, group: 6, order: 0), owner: .teams),
        Command(manageChannel, "Manage Channel…", menu: .init(.conversation, group: 6, order: 1), owner: .teams),
        Command(copyLink, "Copy Channel Link", menu: .init(.conversation, group: 6, order: 2), owner: .teams),
        Command(channelEmail, "Copy Channel Email Address", menu: .init(.conversation, group: 6, order: 3),
                owner: .teams),
        Command(channelWorkflows, "Channel Workflows…", menu: .init(.conversation, group: 6, order: 4),
                owner: .teams),
        Command(deleteChannel, "Delete Channel…", menu: .init(.conversation, group: 7, order: 0), owner: .teams),
        Command(hideTeam, "Hide Team", alternateTitle: "Show Team",
                menu: .init(.conversation, group: 4, order: 2), owner: .teams),
        Command(teamLink, "Copy Team Link", menu: .init(.conversation, group: 4, order: 3), owner: .teams),
        Command(leaveTeam, "Leave Team…", menu: .init(.conversation, group: 4, order: 4), owner: .teams),
    ]
}
