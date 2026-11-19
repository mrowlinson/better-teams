// ApprovalsSection.swift — approvals native app provider (UI-SPEC
// §6.7).
//
// List: the approval requests. Detail: the request (state, description,
// flow status with one row per approver, approve/reject + optional
// comment, owner cancel). Loads start from the selection (R24).
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class ApprovalsSection: SectionProvider {
    let section: SectionID = .native(.approvals)
    let title = NativeAppID.approvals.title

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil, let app = m.app, let id = Self.itemID(m) else { return "" }
        return app.approvals.items.first { $0.id == id }?.displayName ?? ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane(ApprovalsListState.emptyTitle, systemImage: NativeAppID.approvals.symbol,
                                     message: ApprovalsListState.emptyMessage))
        }
        return AnyView(ApprovalsListPane(approvals: app.approvals))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane(ApprovalsDetailState.noSelectionTitle)) }
        return AnyView(ApprovalsDetailPane(approvals: app.approvals))
    }

    /// `app/approvals/<id>` (the tail's head is the app id).
    func selection(for route: Route) -> SectionSelection? {
        guard let id = route.tail.dropFirst().first else { return nil }
        return SectionSelection(id: id)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.forced(section) == nil, let approvals = m.app?.approvals else { return }
        approvals.show(id: sel?.path.first)
    }

    // MARK: shared helpers

    static func itemID(_ m: WindowModel) -> String? {
        m.nav.selection(in: .native(.approvals))?.path.first
    }

    static func selectItem(_ id: String?, _ m: WindowModel) {
        guard itemID(m) != id else { return }
        m.navigator?.select(id.map(SectionSelection.init(id:)), in: .native(.approvals))
    }

    /// One-line summary for a list row (owner + state).
    static func subtitle(for item: ApprovalItem) -> String {
        let badge = ApprovalsFormat.stateLabel(item.state)
        if let owner = item.owner?.displayName {
            return "\(badge.text) · \(owner)"
        }
        return badge.text
    }

    static func selectedItem(_ m: WindowModel) -> ApprovalItem? {
        guard m.nav.section == .native(.approvals), m.nav.search == nil, let approvals = m.app?.approvals else {
            return nil
        }
        let s = itemID(m)
        guard let id = s, approvals.selected?.id == id else { return nil }
        return approvals.selected
    }

    // MARK: commands

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let approvals = m.app?.approvals, m.nav.section == section else { return false }
        switch c {
        case ApprovalsCommands.refresh:
            approvals.refresh()
        case ApprovalsCommands.approve, ApprovalsCommands.reject:
            guard let item = Self.selectedItem(m), !item.isDecided else { return false }
            let prompts = item.responsePrompts
            let response = c == ApprovalsCommands.approve
                ? (prompts.first ?? "Approve")
                : (prompts.dropFirst().first ?? "Reject")
            approvals.respond(id: item.id, response: response)
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        switch c {
        case ApprovalsCommands.refresh:
            guard m.nav.section == section, m.nav.search == nil else { return .disabled }
            return CommandValidation(enabled: true)
        case ApprovalsCommands.approve, ApprovalsCommands.reject:
            guard m.nav.section == section, m.nav.search == nil,
                  let item = Self.selectedItem(m), !item.isDecided else { return .disabled }
            let prompts = item.responsePrompts
            let title = c == ApprovalsCommands.approve
                ? (prompts.first ?? "Approve") : (prompts.dropFirst().first ?? "Reject")
            return CommandValidation(enabled: true, title: title)
        default:
            return .disabled
        }
    }
}
