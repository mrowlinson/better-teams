// ShiftsCommands.swift — Shifts commands (UI-SPEC §6.7, §9.1, §11.3
// seam). CommandCatalog aggregates this list; menu placement is data.
// Toolbar: team picker + week navigation (‹ Today ›, navigational). The
// menu-bar twins sit in View ▸ Shifts so they never read as Calendar's
// week items.
public enum ShiftsCommands {
    public static let previousWeek: CommandID = "shifts.previousWeek"
    public static let today: CommandID = "shifts.today"
    public static let nextWeek: CommandID = "shifts.nextWeek"
    /// Team picker (submenu args = team ids).
    public static let team: CommandID = "shifts.team"

    @MainActor
    public static let all: [Command] = [
        Command(previousWeek, "Previous Week", symbol: "chevron.left",
                menu: .init(.view, group: 4, order: 1, submenu: "Shifts"), toolbar: .detail,
                owner: .native(.shifts)),
        Command(today, "Today", symbol: "calendar.day.timeline.left",
                menu: .init(.view, group: 4, order: 2, submenu: "Shifts"), toolbar: .detail,
                owner: .native(.shifts)),
        Command(nextWeek, "Next Week", symbol: "chevron.right",
                menu: .init(.view, group: 4, order: 3, submenu: "Shifts"), toolbar: .detail,
                owner: .native(.shifts)),
        Command(team, "Team", symbol: "person.3",
                menu: .init(.view, group: 4, order: 0, submenu: "Shifts"), toolbar: .detail,
                isSubmenu: true, owner: .native(.shifts)),
    ]
}
