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
        [CallCommands.mute, CallCommands.camera, CallCommands.share, CallCommands.record, CallCommands.transcribe,
         CallCommands.devices, CallCommands.leave]
    }

    func toolbarItems(_ sel: SectionSelection?) -> [CommandID] { allToolbarItems }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        switch c {
        case CallCommands.accept:
            guard Self.isRinging(m) else { return false }
            m.app?.call.accept()
        case CallCommands.decline:
            guard Self.isRinging(m) else { return false }
            m.app?.call.end()
        default:
            guard let s = m.call, !s.ended else { return false }
            switch c {
            case CallCommands.show: s.show()
            case CallCommands.leave: s.leave()
            case CallCommands.mute: s.toggleMute()
            case CallCommands.camera: s.toggleCamera()
            case CallCommands.share: s.toggleShare()
            case CallCommands.record: s.toggleRecording()
            case CallCommands.transcribe: s.toggleTranscribing()
            case CallCommands.devices: s.showDevices()
            case CallCommands.showPeople: Self.toggleInspector(segment: "people", m)
            case CallCommands.showChat: Self.toggleInspector(segment: "chat", m)
            case CallCommands.hand: s.toggleHandRaised()
            case CallCommands.pushToTalk: s.talkBurst()
            case CallCommands.rooms: m.presentSheet(SheetRequest(CallCommands.roomsSheet, in: .call))
            default: return false
            }
        }
        return true
    }

    /// An incoming ring on the core slot (answerable/declinable).
    static func isRinging(_ m: WindowModel) -> Bool {
        guard let info = m.app?.call.call else { return false }
        return info.dir == "in" && info.state == "ringing"
    }

    /// Breakout rooms sheet (BREAKOUT): the plan over the live roster.
    /// Live sessions have no rooms API (Teams-client-only), so the
    /// sheet disables every mutation there; demo stays interactive.
    static func roomsLive(_ m: WindowModel) -> Bool {
        m.app != nil && !m.options.demo
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        guard r.name == CallCommands.roomsSheet, let app = m.app, let s = m.call, !s.ended else { return nil }
        return AnyView(BreakoutRoomsSheet(rooms: s.breakoutRooms, roster: app.meeting,
                                          live: Self.roomsLive(m) || CallEvidence.roomsForceLive))
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        switch c {
        case CallCommands.accept, CallCommands.decline:
            return CommandValidation(enabled: Self.isRinging(m))
        default:
            guard let s = m.call, !s.ended else { return .disabled }
            switch c {
            case CallCommands.show, CallCommands.leave, CallCommands.devices:
                return .enabled
            case CallCommands.showPeople, CallCommands.showChat:
                let segment = c == CallCommands.showPeople ? "people" : "chat"
                let shown = m.nav.section == .call && m.nav.isInspectorVisible(.call)
                    && (m.inspectorSegment ?? "people") == segment
                let verb = shown ? "Hide" : "Show"
                let what = segment == "people" ? "People" : "Chat"
                return CommandValidation(enabled: true, title: "\(verb) \(what)")
            case CallCommands.mute, CallCommands.camera, CallCommands.share,
                 CallCommands.record, CallCommands.transcribe:
                guard let ctl = s.controls.control(c) else { return .disabled }
                return CommandValidation(enabled: ctl.enabled, title: ctl.menuTitle)
            case CallCommands.hand:
                // Main's C2b state is demo/evidence-only (live has no
                // signaling endpoint): the menu follows the same gate.
                return CommandValidation(enabled: s.joined && m.options.demo,
                                         title: s.handRaised ? "Lower Hand" : "Raise Hand")
            case CallCommands.pushToTalk:
                return CommandValidation(enabled: s.joined && AppSettings.shared.pushToTalk)
            case CallCommands.rooms:
                // Group calls and meetings only (rooms need a roster).
                // The menu stays enabled in live sessions: the sheet
                // itself disables every mutation there (no rooms API)
                // and says so, so live users see why, not a dead menu.
                return CommandValidation(enabled: s.joined && s.group)
            default:
                return .disabled
            }
        }
    }

    /// Show/Hide People/Chat (Call menu, SPECFIX-P2 #13): the call
    /// section's inspector on the segment, landing on the call section
    /// first when another section is showing. Showing the visible
    /// segment hides the inspector.
    static func toggleInspector(segment: String, _ m: WindowModel) {
        guard let nav = m.navigator, let s = m.call, !s.ended else { return }
        if m.nav.section != .call { nav.select(section: .call) }
        if m.nav.isInspectorVisible(.call), (m.inspectorSegment ?? "people") == segment {
            nav.setInspector(false, explicit: true)
        } else {
            m.setInspectorSegment(segment)
            nav.setInspector(true, explicit: true)
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
