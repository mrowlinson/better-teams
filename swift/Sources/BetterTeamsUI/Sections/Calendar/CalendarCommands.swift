// CalendarCommands.swift — Calendar commands, sheet and popover names
// (UI-SPEC §6.4, §9.1, §11.3 seam). CommandCatalog aggregates this
// list; menu placement is data. Navigation and the view switcher also
// sit in the pane's header bar, so they are on screen in every view.
public enum CalendarCommands {
    public static let newMeeting: CommandID = "calendar.newMeeting"
    public static let meetNow: CommandID = "calendar.meetNow"
    public static let joinWithLink: CommandID = "calendar.joinWithLink"
    /// Previous / next day, week or month (by the view shown).
    public static let previousWeek: CommandID = "calendar.previousWeek"
    public static let today: CommandID = "calendar.today"
    public static let nextWeek: CommandID = "calendar.nextWeek"
    /// Day | Work week | Week | Month | List (submenu args = view raw values).
    public static let viewMode: CommandID = "calendar.view"
    public static let join: CommandID = "calendar.join"
    public static let copyJoinLink: CommandID = "calendar.copyJoinLink"
    public static let showDetails: CommandID = "calendar.showDetails"
    public static let cancelMeeting: CommandID = "calendar.cancelMeeting"
    /// The meeting in its own window (R1).
    public static let openWindow: CommandID = "calendar.openWindow"

    /// Sheet and popover names (evidence routes, §12).
    public static let newMeetingSheet = "newMeeting"
    public static let joinSheet = "joinMeeting"
    public static let meetNowSheet = "meetNow"
    public static let detailsSheet = "eventDetails"
    public static let editSheet = "editEvent"
    /// CALDETAIL: Duplicate (new-event sheet prefilled), scheduling
    /// assistant, new webinar.
    public static let duplicateSheet = "duplicateEvent"
    public static let schedulerSheet = "schedulingAssistant"
    public static let webinarSheet = "newWebinar"
    /// Show all instances of a recurring event.
    public static let instancesSheet = "seriesInstances"

    @MainActor
    public static let all: [Command] = [
        Command(meetNow, "Meet Now…", symbol: "video",
                menu: .init(.file, group: 0, order: 6), toolbar: .detail, owner: .calendar),
        Command(newMeeting, "New Meeting…", symbol: "calendar.badge.plus",
                menu: .init(.file, group: 0, order: 4), toolbar: .detail, owner: .calendar),
        Command(joinWithLink, "Join with ID or Link…", symbol: "link",
                menu: .init(.file, group: 0, order: 5), toolbar: .detail, owner: .calendar),
        Command(previousWeek, "Previous", symbol: "chevron.left",
                menu: .init(.view, group: 3, order: 0), owner: .calendar),
        Command(today, "Today", symbol: "calendar.day.timeline.left",
                menu: .init(.view, group: 3, order: 1), owner: .calendar),
        Command(nextWeek, "Next", symbol: "chevron.right",
                menu: .init(.view, group: 3, order: 2), owner: .calendar),
        Command(viewMode, "Calendar View", symbol: "calendar",
                menu: .init(.view, group: 3, order: 3), isSubmenu: true, owner: .calendar),
        Command(join, "Join Meeting", key: "j", menu: .init(.call, group: 1, order: 0), owner: .calendar),
        Command(copyJoinLink, "Copy Join Link", menu: .init(.call, group: 1, order: 1), owner: .calendar),
        Command(showDetails, "Meeting Details…", menu: .init(.call, group: 1, order: 2), owner: .calendar),
        Command(openWindow, "Open Meeting in New Window", symbol: "macwindow.badge.plus",
                menu: .init(.call, group: 1, order: 3), owner: .calendar),
        Command(cancelMeeting, "Cancel Meeting…", menu: .init(.file, group: 1, order: 0), owner: .calendar),
    ]
}
