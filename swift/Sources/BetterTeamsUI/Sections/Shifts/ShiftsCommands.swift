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
    /// Member: open the time-off request sheet.
    public static let requestTimeOff: CommandID = "shifts.requestTimeOff"
    /// Manager: open the add-shift sheet.
    public static let addShift: CommandID = "shifts.addShift"
    /// Manager: publish drafts now (no notify).
    public static let publish: CommandID = "shifts.publish"
    /// Sheet names (arg = shift id for the swap sheet).
    public static let timeOffSheet = "shifts.timeOffSheet"
    public static let addShiftSheet = "shifts.addShiftSheet"
    public static let swapSheet = "shifts.swapSheet"

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
        Command(requestTimeOff, "Request Time Off", symbol: "calendar.badge.plus",
                menu: .init(.view, group: 4, order: 4, submenu: "Shifts"),
                owner: .native(.shifts)),
        Command(addShift, "Add Shift…", symbol: "plus",
                menu: .init(.view, group: 4, order: 5, submenu: "Shifts"),
                owner: .native(.shifts)),
        Command(publish, "Publish Schedule", symbol: "tray.and.arrow.up",
                menu: .init(.view, group: 4, order: 6, submenu: "Shifts"),
                owner: .native(.shifts)),
    ]
}
