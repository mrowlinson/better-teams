// CalendarCommands.swift — Calendar commands, sheet and popover names
// (UI-SPEC §6.4, §9.1, §11.3 seam). CommandCatalog aggregates this
// list; menu placement is data. Week navigation and Agenda | Week sit
// in the detail group, so they stay visible in both the Agenda
// (list | detail) and Week (`.full`) layouts without twins.
public enum CalendarCommands {
    public static let newMeeting: CommandID = "calendar.newMeeting"
    public static let joinWithLink: CommandID = "calendar.joinWithLink"
    public static let previousWeek: CommandID = "calendar.previousWeek"
    public static let today: CommandID = "calendar.today"
    public static let nextWeek: CommandID = "calendar.nextWeek"
    /// Agenda | Week (submenu args `agenda`, `week`).
    public static let viewMode: CommandID = "calendar.view"
    public static let join: CommandID = "calendar.join"
    public static let copyJoinLink: CommandID = "calendar.copyJoinLink"
    public static let cancelMeeting: CommandID = "calendar.cancelMeeting"

    /// Sheet and popover names (evidence routes, §12).
    public static let newMeetingSheet = "newMeeting"
    public static let joinSheet = "joinMeeting"

    @MainActor
    public static let all: [Command] = [
        Command(newMeeting, "New Meeting…", symbol: "calendar.badge.plus",
                menu: .init(.file, group: 0, order: 4), toolbar: .detail, owner: .calendar),
        Command(joinWithLink, "Join with ID or Link…", symbol: "link",
                menu: .init(.file, group: 0, order: 5), toolbar: .detail, owner: .calendar),
        Command(previousWeek, "Previous Week", symbol: "chevron.left",
                menu: .init(.view, group: 3, order: 0), toolbar: .detail, owner: .calendar),
        Command(today, "Today", symbol: "calendar.day.timeline.left",
                menu: .init(.view, group: 3, order: 1), toolbar: .detail, owner: .calendar),
        Command(nextWeek, "Next Week", symbol: "chevron.right",
                menu: .init(.view, group: 3, order: 2), toolbar: .detail, owner: .calendar),
        Command(viewMode, "Agenda or Week", symbol: "list.bullet.rectangle",
                menu: .init(.view, group: 3, order: 3), toolbar: .detail, isSubmenu: true, owner: .calendar),
        Command(join, "Join Meeting", menu: .init(.call, group: 1, order: 0), owner: .calendar),
        Command(copyJoinLink, "Copy Join Link", menu: .init(.call, group: 1, order: 1), owner: .calendar),
        Command(cancelMeeting, "Cancel Meeting…", menu: .init(.file, group: 1, order: 0), owner: .calendar),
    ]
}
