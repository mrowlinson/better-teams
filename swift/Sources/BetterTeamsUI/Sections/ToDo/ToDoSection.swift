// ToDoSection.swift — To Do native app provider (UI-SPEC §6.7).
//
// List: the user's To Do lists. Detail: the list's tasks with
// checkboxes, an add field on top and a Show Completed toggle (View ▸
// Show Completed Tasks is its menu twin). No inspector. Task loads
// start from the selection (R24).
import Combine
import OstMacCore
import SwiftUI

/// Per-window To Do view state (Show Completed).
@MainActor
final class ToDoViewState: ObservableObject {
    @Published var showCompleted = false
}

@MainActor
final class ToDoSection: SectionProvider {
    let section: SectionID = .native(.todo)
    let title = NativeAppID.todo.title
    let viewState = ToDoViewState()

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil, let app = m.app, let id = Self.listID(m) else { return "" }
        return app.reminders.lists.first { $0.listId == id }?.name ?? ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane(ToDoListState.emptyTitle, systemImage: NativeAppID.todo.symbol,
                                     message: ToDoListState.emptyMessage))
        }
        return AnyView(ToDoListPane(reminders: app.reminders))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane(ToDoTasksState.noSelectionTitle)) }
        return AnyView(ToDoTasksPane(reminders: app.reminders, viewState: viewState))
    }

    /// `app/todo/<list>` (the tail's head is the app id).
    func selection(for route: Route) -> SectionSelection? {
        guard let id = route.tail.dropFirst().first else { return nil }
        return SectionSelection(id: id)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.forced(section) == nil, let reminders = m.app?.reminders else { return }
        reminders.show(listID: sel?.path.first)
    }

    // MARK: shared helpers

    static func listID(_ m: WindowModel) -> String? {
        m.nav.selection(in: .native(.todo))?.path.first
    }

    static func selectList(_ id: String?, _ m: WindowModel) {
        guard listID(m) != id else { return }
        m.navigator?.select(id.map { SectionSelection(id: $0) }, in: .native(.todo))
    }

    // MARK: commands

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard c == ToDoCommands.showCompleted, m.nav.section == section else { return false }
        viewState.showCompleted.toggle()
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard c == ToDoCommands.showCompleted, m.nav.section == section, m.nav.search == nil else {
            return .disabled
        }
        return CommandValidation(enabled: true, checked: viewState.showCompleted)
    }
}
