// ShiftsSection.swift — Shifts native app provider (UI-SPEC §6.7).
//
// `.full` layout: the week schedule `Table` (rows = people, columns =
// days; cells = time + theme label + color swatch; time off as rows).
// Toolbar: team picker + week navigation (‹ Today ›). Inspector: the
// selected row's shifts. The store seeds with the teams list at content
// open; week navigation fetches the week on screen from the server.
import OstMacCore
import SwiftUI

@MainActor
final class ShiftsSection: SectionProvider, InspectorCapable {
    let section: SectionID = .native(.shifts)
    let title = NativeAppID.shifts.title
    let hasInspector = true

    func layout(_ sel: SectionSelection?) -> SectionLayout { .full }

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil, let store = m.app?.shifts else { return "" }
        return Self.subtitle(store)
    }

    static func subtitle(_ store: ShiftsStore) -> String {
        let team = store.teams.first { $0.id == store.selectedTeamID }?.name
        guard team != nil || store.week != nil else { return "" }
        return [team, weekRange(store.weekStart)].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// "Sep 28 – Oct 4, 2026".
    static func weekRange(_ start: Date, calendar: Calendar = .current) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        return (start ..< end.addingTimeInterval(1)).formatted(.interval.month(.abbreviated).day().year())
    }

    func listPane(_ m: WindowModel) -> AnyView { AnyView(EmptyView()) }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane(ShiftsPaneState.notSetUpTitle, systemImage: NativeAppID.shifts.symbol,
                                     message: ShiftsPaneState.notSetUpMessage))
        }
        return AnyView(ShiftsWeekPane(store: app.shifts))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        return AnyView(ShiftsInspectorPane(store: app.shifts))
    }

    var allToolbarItems: [CommandID] {
        [ShiftsCommands.previousWeek, ShiftsCommands.today, ShiftsCommands.nextWeek, ShiftsCommands.team]
    }

    /// `app/shifts/<row id>` (the tail's head is the app id).
    func selection(for route: Route) -> SectionSelection? {
        guard let id = route.tail.dropFirst().first else { return nil }
        return SectionSelection(id: id)
    }

    // MARK: shared helpers

    static func selectedRowID(_ m: WindowModel) -> String? {
        m.nav.selection(in: .native(.shifts))?.id
    }

    static func select(_ id: String?, _ m: WindowModel) {
        guard selectedRowID(m) != id else { return }
        m.navigator?.select(id.map { SectionSelection(id: $0) }, in: .native(.shifts))
    }

    /// Double-click / Return on a row: select it and show the inspector.
    static func open(_ id: String, _ m: WindowModel) {
        select(id, m)
        if !m.nav.isInspectorVisible(.native(.shifts)) { m.navigator?.setInspector(true) }
    }

    private func here(_ m: WindowModel) -> Bool {
        m.nav.section == section && m.nav.search == nil && m.forced(section) == nil
    }

    /// Week navigation needs a team's schedule on hand.
    private func navigable(_ m: WindowModel) -> Bool {
        guard here(m), let store = m.app?.shifts else { return false }
        return store.state == .loaded || (store.state == .empty && !store.teams.isEmpty)
    }

    // MARK: commands

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let store = m.app?.shifts else { return false }
        switch c {
        case ShiftsCommands.previousWeek: store.showWeek(offset: -1)
        case ShiftsCommands.nextWeek: store.showWeek(offset: 1)
        case ShiftsCommands.today: store.showCurrentWeek()
        case ShiftsCommands.team:
            guard let id = arg, id != store.selectedTeamID else { return false }
            Self.select(nil, m)
            store.select(teamID: id)
        default:
            return false
        }
        m.navigator?.refreshTitle() // subtitle = team · week shown
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard let store = m.app?.shifts else { return .disabled }
        switch c {
        case ShiftsCommands.previousWeek, ShiftsCommands.nextWeek:
            return CommandValidation(enabled: navigable(m))
        case ShiftsCommands.today:
            return CommandValidation(enabled: navigable(m) && !store.isCurrentWeek)
        case ShiftsCommands.team:
            return CommandValidation(enabled: here(m) && !store.teams.isEmpty)
        default:
            return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        guard c == ShiftsCommands.team, let store = m.app?.shifts else { return [] }
        return store.teams.map { SubmenuItem($0.name, arg: $0.id, checked: $0.id == store.selectedTeamID) }
    }
}
