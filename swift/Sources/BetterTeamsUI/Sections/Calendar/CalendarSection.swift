// CalendarSection.swift — Calendar section provider (UI-SPEC §6.4).
//
// Agenda (list | detail): the week's meetings by day | the meeting.
// Week (`.full`): the week grid, the selected meeting in the inspector
// (the only Calendar view with an inspector, §5.3). The view and the
// meeting are the section's selection (`CalendarSelection`), so a view
// switch goes through `Navigator` and swaps layout in one call stack
// (R21). Data: `CalendarWeekStore` (week window, schedule, cancel) and
// `MeetingsViewModel` (join flow). Joins start a call in the chosen
// presentation (§8, DL1).
import AppKit
import OstMacCore
import SwiftUI

@MainActor
final class CalendarSection: SectionProvider, InspectorCapable {
    let section: SectionID = .calendar
    let title = "Calendar"

    var hasInspector: Bool { true }

    func hasInspector(for sel: SectionSelection?) -> Bool {
        CalendarSelection(sel).view == .week
    }

    func subtitle(_ m: WindowModel) -> String {
        guard let week = m.app?.calWeek else { return "" }
        return CalendarFormat.weekRange(week.weekStart)
    }

    func layout(_ sel: SectionSelection?) -> SectionLayout {
        CalendarSelection(sel).view == .week ? .full : .listDetail
    }

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
        [CalendarCommands.previousWeek, CalendarCommands.today, CalendarCommands.nextWeek,
         CalendarCommands.viewMode, CalendarCommands.newMeeting, CalendarCommands.joinWithLink]
    }

    /// `calendar`, `calendar?view=week`, `calendar/<id>`,
    /// `calendar/demo-meeting?view=week` (§11.3).
    func selection(for route: Route) -> SectionSelection? {
        var id = route.tail.first
        if id == CalendarSelection.demoMeetingAlias { id = CalendarSelection.demoMeetingID }
        let view = CalendarSelection.View(rawValue: route.query["view"] ?? "") ?? .agenda
        if id == nil, view == .agenda { return nil }
        return CalendarSelection(view: view, meetingID: id).selection
    }

    /// The core loads the week only on demand, so the first Calendar
    /// visit starts it (R24: loads start here, never in a view); later
    /// visits reuse the loaded week (week paging and Try Again reload).
    private var loadStarted = false

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard !loadStarted, m.forced(.calendar) == nil, let week = m.app?.calWeek else { return }
        loadStarted = true
        week.refresh()
    }

    // MARK: shared helpers

    static func current(_ m: WindowModel) -> CalendarSelection {
        CalendarSelection(m.nav.selection(in: .calendar))
    }

    /// The selected meeting, when it is in the loaded week.
    static func selectedMeeting(_ m: WindowModel) -> MeetingItem? {
        guard let id = current(m).meetingID else { return nil }
        return m.app?.calWeek.meetings.first { $0.id == id }
    }

    static func select(_ id: String?, _ m: WindowModel) {
        var s = current(m)
        guard s.meetingID != id else { return }
        s.meetingID = id
        m.navigator?.select(s.selection, in: .calendar)
        // Week: the selected meeting shows in the inspector (§6.4).
        if s.view == .week, id != nil, !m.nav.isInspectorVisible(.calendar) {
            m.navigator?.setInspector(true)
        }
    }

    static func setView(_ v: CalendarSelection.View, _ m: WindowModel) {
        var s = current(m)
        guard s.view != v else { return }
        s.view = v
        m.navigator?.select(s.selection, in: .calendar)
    }

    /// Graph `isOrganizer` (core-c): only the organizer can cancel.
    /// Gates Cancel Meeting… (hidden in context menus and the detail
    /// pane, disabled in the menu bar).
    static func isOrganizer(_ meeting: MeetingItem, _ m: WindowModel) -> Bool {
        meeting.isOrganizer
    }

    /// Join (§6.4, §8): opens the call pre-join in the chosen presentation.
    static func join(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let app = m.app, meeting.joinURL?.isEmpty == false else { return }
        guard m.beginCall(.meeting(id: meeting.id, subject: meeting.subject)) != nil else { return }
        app.meetings.joinMeeting(meeting)
    }

    static func copyJoinLink(_ meeting: MeetingItem) {
        guard let url = meeting.joinURL, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    static func confirmCancel(_ meeting: MeetingItem, _ m: WindowModel) {
        guard let week = m.app?.calWeek else { return }
        m.confirm(title: "Cancel \u{201C}\(meeting.subject)\u{201D}?",
                  message: "The meeting is removed from everyone\u{2019}s calendar.",
                  action: "Cancel Meeting") { week.cancel(eventID: meeting.id) }
    }

    // MARK: commands

    private func here(_ m: WindowModel) -> Bool {
        m.nav.section == .calendar && m.nav.search == nil && m.app != nil
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let week = m.app?.calWeek else { return false }
        switch c {
        case CalendarCommands.newMeeting:
            if m.nav.section != .calendar { m.navigator?.select(section: .calendar) }
            m.presentSheet(SheetRequest(CalendarCommands.newMeetingSheet, in: .calendar))
        case CalendarCommands.joinWithLink:
            if m.nav.section != .calendar { m.navigator?.select(section: .calendar) }
            m.presentSheet(SheetRequest(CalendarCommands.joinSheet, in: .calendar))
        case CalendarCommands.previousWeek, CalendarCommands.nextWeek, CalendarCommands.today:
            switch c {
            case CalendarCommands.previousWeek: week.prevWeek()
            case CalendarCommands.nextWeek: week.nextWeek()
            default: week.showWeek(containing: RelativeClock.shared.now)
            }
            m.navigator?.refreshTitle() // subtitle = the week shown
        case CalendarCommands.viewMode:
            Self.setView(CalendarSelection.View(rawValue: arg ?? "") ?? .agenda, m)
        case CalendarCommands.join:
            guard let meeting = Self.selectedMeeting(m) else { return false }
            Self.join(meeting, m)
        case CalendarCommands.copyJoinLink:
            guard let meeting = Self.selectedMeeting(m) else { return false }
            Self.copyJoinLink(meeting)
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
        case CalendarCommands.newMeeting, CalendarCommands.joinWithLink:
            return .enabled
        case CalendarCommands.previousWeek, CalendarCommands.nextWeek, CalendarCommands.viewMode:
            return CommandValidation(enabled: here(m))
        case CalendarCommands.today:
            guard here(m), let week = m.app?.calWeek else { return .disabled }
            let thisWeek = CalWeek.startOfWeek(containing: RelativeClock.shared.now)
            return CommandValidation(enabled: Calendar.current.startOfDay(for: thisWeek) != week.weekStart)
        case CalendarCommands.join:
            guard here(m), let meeting = Self.selectedMeeting(m) else { return .disabled }
            return CommandValidation(enabled: meeting.joinURL?.isEmpty == false)
        case CalendarCommands.copyJoinLink:
            guard here(m), let meeting = Self.selectedMeeting(m) else { return .disabled }
            return CommandValidation(enabled: meeting.joinURL?.isEmpty == false)
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
        return [
            SubmenuItem("Agenda", arg: CalendarSelection.View.agenda.rawValue, checked: v == .agenda, enabled: enabled),
            SubmenuItem("Week", arg: CalendarSelection.View.week.rawValue, checked: v == .week, enabled: enabled),
        ]
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        switch r.name {
        case CalendarCommands.newMeetingSheet: return AnyView(NewMeetingSheet(week: app.calWeek))
        case CalendarCommands.joinSheet: return AnyView(JoinMeetingSheet(meetings: app.meetings))
        default: return nil
        }
    }
}
