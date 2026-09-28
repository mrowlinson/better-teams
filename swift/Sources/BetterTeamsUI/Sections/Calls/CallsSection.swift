// CallsSection.swift — Calls section provider (UI-SPEC §6.5).
//
// List: the Current call row while a call runs, Speed Dial (pinned
// contacts), then Recent (`CallsRowModel.rows`: history + realtime
// missed calls). Detail: the person — avatar, presence, Call / Video /
// Chat, and recent calls with them. No inspector (§5.3). Calls start
// through the core call slot (`CallStore.placeLive` / `echoLive`) and show in
// the chosen presentation (§8, DL1).
import OstMacCore
import SwiftUI

@MainActor
final class CallsSection: SectionProvider {
    let section: SectionID = .calls
    let title = "Calls"

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(.calls) == nil else { return "" }
        let n = Self.rows(m).filter(\.isMissed).count
        return n == 0 ? "" : n == 1 ? "1 missed call" : "\(n) missed calls"
    }

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane("No Recent Calls", systemImage: "phone"))
        }
        return AnyView(CallsListPane(history: app.history, activity: app.activity, contacts: app.contacts,
                                     presence: app.presence))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else { return AnyView(NoSelectionPane("No Contact Selected")) }
        return AnyView(CallsDetailPane(history: app.history, activity: app.activity, contacts: app.contacts,
                                       presence: app.presence, chats: m.graph.chats))
    }

    var allToolbarItems: [CommandID] { [CallsCommands.newCall, CallsCommands.testCall] }

    func selection(for route: Route) -> SectionSelection? {
        guard let id = route.tail.first else { return nil }
        return SectionSelection(id: id == CallsRowModel.demoPersonAlias ? CallsRowModel.demoPersonID : id)
    }

    // MARK: shared helpers

    static func rows(_ m: WindowModel) -> [CallsRowModel] {
        guard let app = m.app else { return [] }
        return CallsRowModel.rows(history: app.history.records, activity: app.activity.items)
    }

    static let speedDialPrefix = "dial:"

    /// The selected person: a Recent row or a Speed Dial contact.
    struct Person {
        var name: String
        var personID: String?
        var personKey: String
        var thread: String
    }

    static func person(_ id: String?, _ m: WindowModel) -> Person? {
        guard let id, let app = m.app else { return nil }
        if id.hasPrefix(speedDialPrefix) {
            let ref = String(id.dropFirst(speedDialPrefix.count))
            guard let c = app.contacts.pinnedContacts().first(where: { $0.id == ref }) else { return nil }
            let key = (c.userId ?? c.id).lowercased()
            return Person(name: c.displayName, personID: c.userId ?? c.id, personKey: key,
                          thread: oneToOne(named: c.displayName, m) ?? "")
        }
        guard let r = rows(m).first(where: { $0.id == id }) else { return nil }
        return Person(name: r.name, personID: r.personID, personKey: r.personKey,
                      thread: r.thread.isEmpty ? (oneToOne(named: r.name, m) ?? "") : r.thread)
    }

    /// The 1:1 chat with `name` (call and chat target when the record
    /// carries no thread).
    static func oneToOne(named name: String, _ m: WindowModel) -> String? {
        m.graph.chats.chats.first { !$0.is_group && $0.name == name }?.id
    }

    /// The chat to open for a person: their thread when it is a known
    /// chat, else the 1:1 chat named after them.
    static func chatID(_ p: Person, _ m: WindowModel) -> String? {
        if !p.thread.isEmpty, m.graph.chats.chats.contains(where: { $0.id == p.thread }) { return p.thread }
        return oneToOne(named: p.name, m)
    }

    /// Call / Call Back: places the call on the person's thread and
    /// shows it in the chosen presentation.
    static func call(_ p: Person, _ m: WindowModel) {
        guard let app = m.app, !p.thread.isEmpty else { return }
        guard m.beginCall(.person(name: p.name, thread: p.thread)) != nil else { return }
        app.call.placeLive(threadID: p.thread)
    }

    static func message(_ p: Person, _ m: WindowModel) {
        guard let id = chatID(p, m) else { return }
        m.navigator?.select(SectionSelection(id: id), in: .chat)
        m.navigator?.select(section: .chat)
    }

    static func testCall(_ m: WindowModel) {
        guard let app = m.app, m.beginCall(.test) != nil else { return }
        app.call.echoLive()
    }

    private func selected(_ m: WindowModel) -> Person? {
        guard m.nav.section == .calls, m.nav.search == nil else { return nil }
        return Self.person(m.nav.selection(in: .calls)?.id, m)
    }

    // MARK: commands

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard m.app != nil else { return false }
        switch c {
        case CallsCommands.newCall:
            if m.nav.section != .calls { m.navigator?.select(section: .calls) }
            m.presentSheet(SheetRequest(CallsCommands.newCallSheet, in: .calls))
        case CallsCommands.testCall:
            Self.testCall(m)
        case CallsCommands.callBack:
            guard let p = selected(m) else { return false }
            Self.call(p, m)
        case CallsCommands.message:
            guard let p = selected(m) else { return false }
            Self.message(p, m)
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard m.app != nil else { return .disabled }
        let idle = m.call.map(\.ended) ?? true
        switch c {
        case CallsCommands.newCall, CallsCommands.testCall:
            return CommandValidation(enabled: idle)
        case CallsCommands.callBack:
            guard let p = selected(m) else { return .disabled }
            return CommandValidation(enabled: idle && !p.thread.isEmpty)
        case CallsCommands.message:
            guard let p = selected(m) else { return .disabled }
            return CommandValidation(enabled: Self.chatID(p, m) != nil)
        default:
            return .disabled
        }
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        guard r.name == CallsCommands.newCallSheet, let app = m.app else { return nil }
        return AnyView(NewCallSheet(chats: m.graph.chats,
                                    contacts: NewChatSheet.directory(app, demo: m.options.demo),
                                    presence: app.presence))
    }
}
