// CopilotSection.swift — Copilot native app provider (UI-SPEC
// §6.7).
//
// `.full` layout: the one live conversation (no conversation list —
// the hub conversation store is server-side and unmapped, so a list
// would be a fake control). Loads start from the selection (R24):
// showing the section refreshes the Taiger licence, which gates the
// input with the honest reason.
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class CopilotSection: SectionProvider {
    let section: SectionID = .native(.copilot)
    let title = NativeAppID.copilot.title

    func layout(_ sel: SectionSelection?) -> SectionLayout { .full }

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil, let store = m.app?.copilot else { return "" }
        switch store.license {
        case .licensed(_, let note): return note ?? ""
        case .unlicensed(let reason): return reason
        case .unknown, .checking: return ""
        }
    }

    func listPane(_ m: WindowModel) -> AnyView { AnyView(EmptyView()) }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane(CopilotPaneState.notSetUpTitle, systemImage: NativeAppID.copilot.symbol,
                                     message: CopilotPaneState.notSetUpMessage))
        }
        return AnyView(CopilotChatPane(store: app.copilot, forced: m.forced(section)))
    }

    var allToolbarItems: [CommandID] {
        [CopilotCommands.newChat, CopilotCommands.stop]
    }

    /// `app/copilot` (no tail: the one conversation).
    func selection(for route: Route) -> SectionSelection? { nil }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.forced(section) == nil, let copilot = m.app?.copilot else { return }
        copilot.refreshLicense()
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let copilot = m.app?.copilot, m.nav.section == section else { return false }
        switch c {
        case CopilotCommands.newChat:
            copilot.newChat()
        case CopilotCommands.stop:
            guard copilot.streaming else { return false }
            copilot.stop()
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        switch c {
        case CopilotCommands.newChat:
            guard m.nav.section == section, m.nav.search == nil else { return .disabled }
            return CommandValidation(enabled: true)
        case CopilotCommands.stop:
            guard m.nav.section == section, m.nav.search == nil,
                  let copilot = m.app?.copilot, copilot.streaming else { return .disabled }
            return CommandValidation(enabled: true)
        default:
            return .disabled
        }
    }
}
