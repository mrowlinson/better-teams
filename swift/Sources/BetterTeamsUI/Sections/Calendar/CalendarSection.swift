// CalendarSection.swift — Calendar section provider (UI-SPEC §6.4).
//
// One `.full` pane for every view: a header bar (Today, ‹ ›, the range,
// a date picker, Day | Work week | Week | Month | List, Meet now, New
// meeting) always on screen over the chosen view, and the selected
// meeting in the inspector (expandable to the details popup). The view
// and the meeting are the section's selection (`CalendarSelection`),
// the view also remembered across launches. Data: `CalendarWeekStore`
// (weeks, month, details, RSVP, edit, Meet now) and `MeetingsViewModel`
// (join flow). Joins start a call in the chosen presentation (§8, DL1).
import AppKit
import OstMacCore
import SwiftUI

@MainActor
final class CalendarSection: SectionProvider, InspectorCapable {
    let section: SectionID = .calendar
    let title = "Calendar"

    var hasInspector: Bool { true }

    func hasInspector(for sel: SectionSelection?) -> Bool { true }

    func subtitle(_ m: WindowModel) -> String {
        guard let week = m.app?.calWeek else { return "" }
        return Self.rangeTitle(Self.current(m).view, week)
    }

    func layout(_ sel: SectionSelection?) -> SectionLayout { .full }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(CalendarEmptyPane()) }
        return AnyView(CalendarAgendaPane(week: app.calWeek))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane("No Meeting Selected")) }
        return AnyView(CalendarDetailPane(week: app.calWeek, conv: m.graph.conv))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        return AnyView(CalendarInspectorPane(week: app.calWeek, conv: m.graph.conv))
    }

    var allToolbarItems: [CommandID] {
        [CalendarCommands.meetNow, CalendarCommands.newMeeting, CalendarCommands.joinWithLink]
    }

    /// `calendar`, `calendar?view=month`, `calendar/<id>`,
    /// `calendar/demo-meeting?view=week` (§11.3).
    func selection(for route: Route) -> SectionSelection? {
        var id = route.tail.first
        if id == CalendarSelection.demoMeetingAlias { id = CalendarSelection.demoMeetingID }
        let view = route.query["view"].flatMap(CalendarSelection.View.init(route:))
        if id == nil, view == nil { return nil }
        return CalendarSelection(view: view ?? .remembered, meetingID: id).selection
    }

    /// The core loads the week only on demand, so the first Calendar
    /// visit starts it (R24: loads start here, never in a view); later
    /// visits reuse the loaded week (paging and Try Again reload).
    private var loadStarted = false

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.forced(.calendar) == nil, let week = m.app?.calWeek else { return }
        if !loadStarted {
            loadStarted = true
            week.refresh()
        }
        if CalendarSelection(sel).view == .month, !week.monthLoaded {
            week.showMonth(containing: week.focusDay)
        }
    }

    // MARK: shared helpers

    static func current(_ m: WindowModel) -> CalendarSelection {
        CalendarSelection(m.nav.selection(in: .calendar))
    }

    /// The selected meeting, wherever it is shown (week, month, details).
    static func selectedMeeting(_ m: WindowModel) -> MeetingItem? {
        guard let id = current(m).meetingID else { return nil }
        return m.app?.calWeek.row(id: id)
    }

    /// The meeting a command acts on: the row named by `arg` (context
    /// menu), else the selection when the Calendar is showing.
    static func target(_ arg: String?, _ m: WindowModel) -> MeetingItem? {
        if let arg, !arg.isEmpty { return m.app?.calWeek.row(id: arg) }
        guard m.nav.section == .calendar else { return nil }
        return selectedMeeting(m)
    }

    static func select(_ id: String?, _ m: WindowModel) {
        var s = current(m)
        guard s.meetingID != id else { return }
        s.meetingID = id
        m.navigator?.select(s.selection, in: .calendar)
        // The selected meeting shows in the inspector (§6.4).
        if id != nil, !m.nav.isInspectorVisible(.calendar) {
            m.navigator?.setInspector(true)
        }
    }

    static func setView(_ v: CalendarSelection.View, _ m: WindowModel) {
        var s = current(m)
        CalendarSelection.View.remember(v)
        guard s.view != v else { return }
        s.view = v
        m.navigator?.select(s.selection, in: .calendar)
        if let week = m.app?.calWeek {
            week.jump(to: week.focusDay, span: v.span)
        }
        m.navigator?.refreshTitle()
    }

    /// Month cell / day header: that day in the Day view.
    static func openDay(_ key: String, _ m: WindowModel) {
        guard let week = m.app?.calWeek, let d = week.date(forKey: key) else { return }
        week.jump(to: d, span: .day)
        setView(.day, m)
        m.navigator?.refreshTitle()
    }

    static func step(_ n: Int, _ m: WindowModel) {
        guard let week = m.app?.calWeek else { return }
        week.step(current(m).view.span, by: n)
        m.navigator?.refreshTitle()
    }

    static func jump(to date: Date, _ m: WindowModel) {
        guard let week = m.app?.calWeek else { return }
        week.jump(to: date, span: current(m).view.span)
        m.navigator?.refreshTitle()
    }

    /// Header / subtitle: "Monday, September 28, 2026", "Sep 28 – Oct 2,
    /// 2026", "September 2026".
    static func rangeTitle(_ v: CalendarSelection.View, _ week: CalendarWeekStore) -> String {
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
        switch v {
        case .day:
            let d = week.date(forKey: week.dayViewKey) ?? week.focusDay
            return d.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .month:
            return week.monthStart.formatted(.dateTime.month(.wide).year())
        case .workWeek, .week, .list:
            let keys = v == .workWeek ? workWeekKeys(week) : week.dayKeys
            guard let a = keys.first.flatMap(week.date(forKey:)), let b = keys.last.flatMap(week.date(forKey:))
            else { return "" }
            return "\(a.formatted(f)) \u{2013} \(b.formatted(f)), \(b.formatted(.dateTime.year()))"
        }
    }

    /// Monday–Friday of the week shown.
    static func workWeekKeys(_ week: CalendarWeekStore) -> [String] {
        week.dayKeys.filter { key in
            guard let d = week.date(forKey: key) else { return false }
            let wd = week.calendar.component(.weekday, from: d)
            return wd != 1 && wd != 7
        }
    }

    /// Graph `isOrganizer` (core-c): only the organizer can cancel or
    /// edit. Gates Cancel Meeting… and Edit.
    static func isOrganizer(_ meeting: MeetingItem, _ m: WindowModel) -> Bool {
        meeting.isOrganizer
    }

    /// Join (§6.4, §8): opens the call pre-join in the chosen presentation.
    static func join(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let app = m.app, meeting.joinURL?.isEmpty == false else { return }
        guard m.beginCall(.meeting(id: meeting.id, subject: meeting.subject)) != nil else { return }
        app.meetings.joinMeeting(meeting)
    }

    /// The meeting's chat (thread read from the join link) in Chat.
    static func openChat(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let thread = meeting.chatThreadID, let nav = m.navigator else { return }
        m.dismissSheet()
        m.graph.openChat(id: thread, name: meeting.subject)
        nav.select(SectionSelection(id: thread), in: .chat)
        nav.select(section: .chat)
    }

    /// RECAP2: a meeting that has ended and has a chat shows Recap.
    static func hasRecap(_ meeting: MeetingItem, now: Date = DemoClock.now) -> Bool {
        guard meeting.chatThreadID != nil, let end = CalendarFormat.date(meeting.end) else { return false }
        return end <= now
    }

    /// RECAP2: the meeting's Recap (the chat's Recap tab: the unified
    /// recap viewer).
    static func openRecap(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let thread = meeting.chatThreadID, let nav = m.navigator else { return }
        nav.setDetailTab(.recap, for: thread)
        openChat(meeting, m)
    }

    static func copyJoinLink(_ meeting: MeetingItem) {
        guard let url = meeting.joinURL, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    static func confirmCancel(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let week = m.app?.calWeek else { return }
        m.dismissSheet()
        m.confirm(title: "Cancel \u{201C}\(meeting.subject)\u{201D}?",
                  message: "The meeting is removed from everyone\u{2019}s calendar.",
                  action: "Cancel Meeting") { week.cancel(eventID: meeting.id) }
    }

    static func showDetails(_ meeting: MeetingItem, _ m: WindowModel) {
        m.app?.calWeek.loadDetail(id: meeting.id)
        m.presentSheet(SheetRequest(CalendarCommands.detailsSheet, in: .calendar, arg: meeting.id))
    }

    static func edit(_ meeting: MeetingItem, _ m: WindowModel) {
        m.dismissSheet()
        m.presentSheet(SheetRequest(CalendarCommands.editSheet, in: .calendar, arg: meeting.id))
    }

    /// Duplicate: the new-event sheet prefilled with this event (time,
    /// people, rooms, location, body, personal fields).
    static func duplicate(_ meeting: MeetingItem, _ m: WindowModel) {
        m.dismissSheet()
        m.presentSheet(SheetRequest(CalendarCommands.duplicateSheet, in: .calendar, arg: meeting.id))
    }

    /// View series: the series master's details.
    static func viewSeries(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let id = CalendarWeekStore.seriesID(of: meeting) else { return }
        m.dismissSheet()
        showDetails(MeetingItem(meetingId: id, subject: meeting.subject), m)
    }

    /// Show all instances of the recurring event.
    static func showInstances(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let id = CalendarWeekStore.seriesID(of: meeting) else { return }
        m.dismissSheet()
        m.presentSheet(SheetRequest(CalendarCommands.instancesSheet, in: .calendar, arg: id))
    }

    /// Scheduling assistant for this event's people.
    static func openScheduler(_ meeting: MeetingItem, _ m: WindowModel) {
        m.dismissSheet()
        m.presentSheet(SheetRequest(CalendarCommands.schedulerSheet, in: .calendar, arg: meeting.id))
    }

    // MARK: commands

    private func here(_ m: WindowModel) -> Bool {
        m.nav.section == .calendar && m.nav.search == nil && m.app != nil
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard m.app?.calWeek != nil else { return false }
        switch c {
        case CalendarCommands.newMeeting, CalendarCommands.meetNow, CalendarCommands.joinWithLink:
            if m.nav.section != .calendar { m.navigator?.select(section: .calendar) }
            let sheet = c == CalendarCommands.newMeeting ? CalendarCommands.newMeetingSheet
                : c == CalendarCommands.meetNow ? CalendarCommands.meetNowSheet : CalendarCommands.joinSheet
            m.presentSheet(SheetRequest(sheet, in: .calendar))
        case CalendarCommands.previousWeek:
            Self.step(-1, m)
        case CalendarCommands.nextWeek:
            Self.step(1, m)
        case CalendarCommands.today:
            Self.jump(to: RelativeClock.shared.now, m)
        case CalendarCommands.viewMode:
            Self.setView(CalendarSelection.View(route: arg ?? "") ?? .week, m)
        case CalendarCommands.join:
            // ⌘J: the selected meeting when it has a link, else the
            // Join with ID or Link sheet (old app: Join Meeting…).
            if here(m), let meeting = Self.selectedMeeting(m), meeting.joinURL?.isEmpty == false {
                Self.join(meeting, m)
            } else {
                if m.nav.section != .calendar { m.navigator?.select(section: .calendar) }
                m.presentSheet(SheetRequest(CalendarCommands.joinSheet, in: .calendar))
            }
        case CalendarCommands.openWindow:
            guard let meeting = Self.target(arg, m) else { return false }
            MeetingWindowController.show(m, meeting: meeting)
        case CalendarCommands.copyJoinLink:
            guard let meeting = Self.selectedMeeting(m) else { return false }
            Self.copyJoinLink(meeting)
        case CalendarCommands.showDetails:
            guard let meeting = Self.selectedMeeting(m) else { return false }
            Self.showDetails(meeting, m)
        case CalendarCommands.cancelMeeting:
            guard let meeting = Self.selectedMeeting(m), Self.isOrganizer(meeting, m) else { return false }
            Self.confirmCancel(meeting, m)
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard m.app != nil else { return .disabled }
        switch c {
        case CalendarCommands.newMeeting, CalendarCommands.joinWithLink, CalendarCommands.meetNow:
            return .enabled
        case CalendarCommands.previousWeek, CalendarCommands.nextWeek, CalendarCommands.viewMode:
            return CommandValidation(enabled: here(m))
        case CalendarCommands.today:
            guard here(m), let week = m.app?.calWeek else { return .disabled }
            let now = RelativeClock.shared.now
            switch Self.current(m).view {
            case .day: return CommandValidation(enabled: week.dayViewKey != week.dayKey(now))
            case .month: return CommandValidation(enabled: !week.calendar.isDate(week.monthStart, equalTo: now, toGranularity: .month))
            default: return CommandValidation(enabled: !week.dayKeys.contains(week.dayKey(now)))
            }
        case CalendarCommands.join:
            return .enabled
        case CalendarCommands.copyJoinLink:
            guard here(m), let meeting = Self.selectedMeeting(m) else { return .disabled }
            return CommandValidation(enabled: meeting.joinURL?.isEmpty == false)
        case CalendarCommands.showDetails:
            return CommandValidation(enabled: here(m) && Self.selectedMeeting(m) != nil)
        case CalendarCommands.openWindow:
            return CommandValidation(enabled: Self.target(arg, m) != nil)
        case CalendarCommands.cancelMeeting:
            guard here(m), let meeting = Self.selectedMeeting(m) else { return .disabled }
            return CommandValidation(enabled: Self.isOrganizer(meeting, m))
        default:
            return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        guard c == CalendarCommands.viewMode else { return [] }
        let v = Self.current(m).view
        let enabled = here(m)
        return CalendarSelection.View.allCases.map {
            SubmenuItem($0.title, arg: $0.rawValue, checked: v == $0, enabled: enabled)
        }
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        switch r.name {
        case CalendarCommands.newMeetingSheet: return AnyView(NewMeetingSheet(week: app.calWeek))
        case CalendarCommands.joinSheet: return AnyView(JoinMeetingSheet(meetings: app.meetings))
        case CalendarCommands.meetNowSheet: return AnyView(MeetNowSheet(week: app.calWeek))
        case CalendarCommands.detailsSheet:
            // Evidence routes open the popup with no arg: the selection.
            guard let id = r.arg ?? Self.current(m).meetingID else { return nil }
            app.calWeek.loadDetail(id: id)
            return AnyView(EventDetailsSheet(week: app.calWeek, eventID: id))
        case CalendarCommands.editSheet:
            guard let id = r.arg ?? Self.current(m).meetingID, let row = app.calWeek.row(id: id) else { return nil }
            return AnyView(EditEventSheet(week: app.calWeek, meeting: row))
        case CalendarCommands.duplicateSheet:
            guard let id = r.arg ?? Self.current(m).meetingID else { return nil }
            let week = app.calWeek
            return AnyView(CalendarRowSheet(week: week, eventID: id, content: { row in
                DuplicateEventSheet(week: week, draft: CalendarEventDraft.duplicate(
                    of: row!, detail: week.details[id], calendar: week.calendar, now: RelativeClock.shared.now))
            }, needsRow: true))
        case CalendarCommands.schedulerSheet:
            let week = app.calWeek
            return AnyView(CalendarRowSheet(week: week, eventID: r.arg ?? Self.current(m).meetingID) { row in
                SchedulingAssistantSheet(week: week, meeting: row)
            })
        case CalendarCommands.instancesSheet:
            guard let id = r.arg else { return nil }
            let title = app.calWeek.seriesInstances[id]?.first?.subject
                ?? app.calWeek.meetings.first { $0.info?.seriesMasterID == id }?.subject ?? "Recurring event"
            return AnyView(EventInstancesSheet(week: app.calWeek, seriesID: id, title: title,
                                               openedFrom: Self.current(m).meetingID))
        case CalendarCommands.webinarSheet:
            return AnyView(NewWebinarSheet(week: app.calWeek))
        default: return nil
        }
    }
}
