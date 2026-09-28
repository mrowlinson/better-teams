// SectionLayout.swift — the section provider contract and the one
// `SectionID` → provider switch (UI-SPEC §5.3, §11.3).
//
// Later lanes replace only their own provider folders; this switch is
// written once by P1, which is what keeps parallel lanes merge-safe.
import Combine
import SwiftUI

public enum SectionLayout: Sendable, Equatable {
    case listDetail, full
}

@MainActor
public protocol SectionProvider: AnyObject {
    var section: SectionID { get }
    /// Window title (section or app name, §5.4).
    var title: String { get }
    func subtitle(_ m: WindowModel) -> String
    func layout(_ sel: SectionSelection?) -> SectionLayout
    func listPane(_ m: WindowModel) -> AnyView
    func detailPane(_ m: WindowModel) -> AnyView
    func inspector(_ m: WindowModel) -> AnyView?
    /// This section's share of the fixed toolbar superset (§5.4).
    var allToolbarItems: [CommandID] { get }
    /// Visible subset for a selection.
    func toolbarItems(_ sel: SectionSelection?) -> [CommandID]
    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool
    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation
    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem]
    func selection(for route: Route) -> SectionSelection?
    /// Loads start here (R24), never from a view's onAppear/task.
    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel)
    /// Sheet body for a request this section declared (§9.5).
    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView?
    /// Rail badge (§5.2): nil = none, 0 = dot only, n = count.
    func badge(_ m: WindowModel) -> Int?
    /// Store changes that can move `badge` (the rail re-renders on them).
    func badgeChanges(_ m: WindowModel) -> [AnyPublisher<Void, Never>]
}

public extension SectionProvider {
    func subtitle(_ m: WindowModel) -> String { "" }
    func layout(_ sel: SectionSelection?) -> SectionLayout { .listDetail }
    func inspector(_ m: WindowModel) -> AnyView? { nil }
    var allToolbarItems: [CommandID] { [] }
    func toolbarItems(_ sel: SectionSelection?) -> [CommandID] { allToolbarItems }
    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool { false }
    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation { .disabled }
    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] { [] }
    func selection(for route: Route) -> SectionSelection? {
        route.tail.isEmpty ? nil : SectionSelection(route.tail)
    }
    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {}
    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? { nil }
    func badge(_ m: WindowModel) -> Int? { nil }
    func badgeChanges(_ m: WindowModel) -> [AnyPublisher<Void, Never>] { [] }
}

/// Placeholder provider for sections a later lane builds: list and
/// detail both explain themselves in place (R18: no blank panes).
@MainActor
open class PlaceholderSection: SectionProvider {
    public let section: SectionID
    public let title: String
    let symbol: String
    let lane: String
    let sectionLayout: SectionLayout

    public init(_ section: SectionID, title: String, symbol: String, lane: String,
                layout: SectionLayout = .listDetail) {
        self.section = section
        self.title = title
        self.symbol = symbol
        self.lane = lane
        self.sectionLayout = layout
    }

    public func layout(_ sel: SectionSelection?) -> SectionLayout { sectionLayout }

    // Class members (not the protocol-extension defaults) so subclasses
    // can override them through the conformance.
    open func badge(_ m: WindowModel) -> Int? { nil }

    open func badgeChanges(_ m: WindowModel) -> [AnyPublisher<Void, Never>] { [] }

    public func listPane(_ m: WindowModel) -> AnyView {
        AnyView(EmptyPane(title, systemImage: symbol, message: Self.message(section)))
    }

    /// `.full` sections show only the detail pane, so it carries the
    /// section message; list/detail sections show the §6 no-selection title.
    public func detailPane(_ m: WindowModel) -> AnyView {
        if sectionLayout == .full {
            return AnyView(EmptyPane(title, systemImage: symbol, message: Self.message(section)))
        }
        return AnyView(NoSelectionPane(Self.noSelection(section)))
    }

    /// One-line, user-facing description of what the section will hold.
    static func message(_ s: SectionID) -> String {
        switch s {
        case .activity: "Mentions, replies and reactions appear here."
        case .chat: "Your chats appear here."
        case .teams: "Your teams and channels appear here."
        case .calendar: "Your meetings appear here."
        case .calls: "Your recent calls appear here."
        case .files: "Your files appear here."
        case .apps: "Your apps appear here."
        case .native(.planner): "Your plans appear here."
        case .native(.todo): "Your tasks appear here."
        case .native(.shifts): "Your schedule appears here."
        case .native(.recaps): "Your meeting recaps appear here."
        case .native(.onenote): "Your notebooks appear here."
        case .web: "This app opens here."
        case .call: "Your call appears here."
        }
    }

    /// §6 pane-states table, "No selection (detail)" column.
    static func noSelection(_ s: SectionID) -> String {
        switch s {
        case .activity: "No Item Selected"
        case .chat: "No Chat Selected"
        case .teams: "No Channel Selected"
        case .calendar: "No Meeting Selected"
        case .calls: "No Contact Selected"
        case .files: "No File Selected"
        case .apps: "No App Selected"
        case .native(.planner): "No Plan Selected"
        case .native(.todo): "No Task Selected"
        case .native(.shifts): "No Shift Selected"
        case .native(.recaps): "No Recap Selected"
        case .native(.onenote): "No Page Selected"
        case .web, .call: "Nothing Selected"
        }
    }
}

@MainActor
enum SectionRegistry {
    /// The one switch (§11.3).
    static func make(_ s: SectionID) -> SectionProvider {
        switch s {
        case .activity: ActivitySection()
        case .chat: ChatSection()
        case .teams: TeamsSection()
        case .calendar: CalendarSection()
        case .calls: CallsSection()
        case .files: FilesSection()
        case .apps: AppsSection()
        case .native(.planner): PlannerSection()
        case .native(.todo): ToDoSection()
        case .native(.shifts): ShiftsSection()
        case .native(.recaps): RecapsSection()
        case .native(.onenote): OneNoteSection()
        case .web(let id): WebAppSection(appID: id)
        case .call: CallSection()
        }
    }
}
