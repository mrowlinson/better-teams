// CallSection.swift — main-window call provider (UI-SPEC §8 In Main
// Window): layout `.full`, detail = the session's stage (pre-join or
// call), attached through `CallStageSlot`; inspector = People | Chat;
// detail and trailing toolbar groups = the call controls; title = call
// name, subtitle = duration. The call commands validate and perform
// here wherever the call is hosted (the call window forwards menu
// commands to the main window).
import SwiftUI

@MainActor
final class CallSection: SectionProvider, InspectorCapable {
    let section: SectionID = .call
    /// The running call's name (set when a call begins).
    var title = "Call"

    var hasInspector: Bool { true }

    func subtitle(_ m: WindowModel) -> String { m.call?.statusLine ?? "" }

    func layout(_ sel: SectionSelection?) -> SectionLayout { .full }

    func listPane(_ m: WindowModel) -> AnyView { AnyView(EmptyView()) }

    func detailPane(_ m: WindowModel) -> AnyView { AnyView(CallDetailPane()) }

    func inspector(_ m: WindowModel) -> AnyView? { AnyView(CallInspectorPane()) }

    var allToolbarItems: [CommandID] {
        [CallCommands.mute, CallCommands.camera, CallCommands.share, CallCommands.devices, CallCommands.leave]
    }

    func toolbarItems(_ sel: SectionSelection?) -> [CommandID] { allToolbarItems }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let s = m.call, !s.ended else { return false }
        switch c {
        case CallCommands.show: s.show()
        case CallCommands.leave: s.leave()
        case CallCommands.mute: s.toggleMute()
        case CallCommands.camera: s.toggleCamera()
        case CallCommands.share: s.toggleShare()
        case CallCommands.devices: s.showDevices()
        default: return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard let s = m.call, !s.ended else { return .disabled }
        switch c {
        case CallCommands.show, CallCommands.leave, CallCommands.devices:
            return .enabled
        case CallCommands.mute, CallCommands.camera, CallCommands.share:
            guard let ctl = s.controls.control(c) else { return .disabled }
            return CommandValidation(enabled: ctl.enabled, title: ctl.menuTitle)
        default:
            return .disabled
        }
    }
}

/// The main window's host for the stage. Reads `model.call`, so a new
/// call swaps the embedded stage and an ended call clears it.
private struct CallDetailPane: View {
    @Environment(\.windowModel) private var model

    var body: some View {
        if let s = model?.call, !s.ended, s.presentation == .mainWindow {
            CallStageSlot(stage: s.stage)
        } else {
            CallStageSlot(stage: nil)
                .overlay { EmptyPane("No Call", systemImage: "phone") }
        }
    }
}

private struct CallInspectorPane: View {
    @Environment(\.windowModel) private var model

    var body: some View {
        if let s = model?.call, !s.ended {
            CallInspector(session: s)
        } else {
            EmptyPane("No Call", systemImage: "phone")
        }
    }
}

extension CallSession {
    /// The toolbar call item shows while a call runs and its stage is
    /// not on screen in this window: always for a separate call window,
    /// outside the call section In Main Window (§8).
    func showsToolbarItem(in section: SectionID) -> Bool {
        guard !ended else { return false }
        return presentation == .separateWindow || section != .call
    }

    /// The rail call item (In Main Window only, §8).
    var showsRailItem: Bool { !ended && presentation == .mainWindow }
}
