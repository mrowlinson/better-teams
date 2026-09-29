// NavigationModel.swift — the one navigation state per window (UI-SPEC
// §11.3, R3, R21).
//
// Every property is `private(set)`; the only writer is `Navigator`
// (enforced by `NavigationWriteToken`, whose initializer is private to
// Navigator.swift). P1 declares every case, including all native apps,
// so no later lane edits these enums.
import Foundation
import Observation

/// Native (non-web) apps that pin like web apps (§6.7).
public enum NativeAppID: String, CaseIterable, Codable, Sendable {
    case planner, todo, shifts, recaps, onenote

    public var title: String {
        switch self {
        case .planner: "Planner"
        case .todo: "To Do"
        case .shifts: "Shifts"
        case .recaps: "Recaps"
        case .onenote: "OneNote"
        }
    }

    public var symbol: String {
        switch self {
        case .planner: "checklist"
        case .todo: "checkmark.circle"
        case .shifts: "person.badge.clock"
        case .recaps: "play.rectangle.on.rectangle"
        case .onenote: "note.text"
        }
    }

    /// Lane that builds this app (placeholder copy until then).
    public var owningLane: String { "P4b" }
}

/// Web app identity (`FrameApp.ID`, §7.1; P3a owns the model).
public typealias FrameAppID = String

/// Top-level sections (rail items plus the call and web apps).
public enum SectionID: Hashable, Codable, Sendable {
    case activity, chat, teams, calendar, calls, files, apps
    case native(NativeAppID)
    case web(FrameAppID)
    case call

    /// The six fixed built-ins, rail order (⌘1–⌘6).
    public static let builtIns: [SectionID] = [
        .activity, .chat, .teams, .calendar, .calls, .files,
    ]

    /// Stable string key (pane children, persistence, routes).
    public var key: String {
        switch self {
        case .activity: "activity"
        case .chat: "chat"
        case .teams: "teams"
        case .calendar: "calendar"
        case .calls: "calls"
        case .files: "files"
        case .apps: "apps"
        case .native(let n): "native.\(n.rawValue)"
        case .web(let id): "web.\(id)"
        case .call: "call"
        }
    }

    public init?(key: String) {
        switch key {
        case "activity": self = .activity
        case "chat": self = .chat
        case "teams": self = .teams
        case "calendar": self = .calendar
        case "calls": self = .calls
        case "files": self = .files
        case "apps": self = .apps
        case "call": self = .call
        default:
            if key.hasPrefix("native."), let n = NativeAppID(rawValue: String(key.dropFirst(7))) {
                self = .native(n)
            } else if key.hasPrefix("web."), key.count > 4 {
                self = .web(String(key.dropFirst(4)))
            } else {
                return nil
            }
        }
    }
}

/// A section's selection. Generic path so each provider interprets its
/// own segments (chat: `[chatID]`; teams: `[team, channel]`; …).
public struct SectionSelection: Hashable, Codable, Sendable {
    public var path: [String]

    public init(_ path: [String]) { self.path = path }
    public init(id: String) { self.path = [id] }

    public var id: String? { path.first }
}

/// Conversation reference (chat or channel id).
public typealias ConversationRef = String

/// Conversation detail tabs (§6.2).
public enum ConversationTab: String, Codable, Sendable, CaseIterable {
    case chat, files, notes, recap

    /// Teams' names: the files tab of a chat is "Shared" (CHATTABS);
    /// Recap exists on meeting chats only (`ChatTabCatalog`).
    public var title: String {
        switch self {
        case .chat: "Chat"
        case .files: "Shared"
        case .notes: "Notes"
        case .recap: "Recap"
        }
    }
}

/// Search scope (§5.5).
public enum SearchScope: String, Codable, Sendable, CaseIterable {
    case all, messages, people, files
}

/// Search mode state, including the exact state to restore on exit.
public struct SearchState: Equatable, Codable, Sendable {
    public var query: String
    public var scope: SearchScope
    public var restoreSection: SectionID
    public var restoreSelection: SectionSelection?
}

/// Codable snapshot (persisted per account, R26).
public struct NavigationState: Equatable, Codable, Sendable {
    public var section: SectionID = .chat
    public var previousSection: SectionID?
    public var selection: [String: SectionSelection] = [:]
    public var detailTab: [ConversationRef: ConversationTab] = [:]
    public var inspectorVisible: [String: Bool] = [:]

    public init() {}
}

@Observable
@MainActor
public final class NavigationModel {
    public private(set) var section: SectionID = .chat
    public private(set) var previousSection: SectionID?
    public private(set) var selection: [SectionID: SectionSelection] = [:]
    public private(set) var detailTab: [ConversationRef: ConversationTab] = [:]
    /// A chat's selected pinned tab (Graph tab id), over `detailTab`;
    /// UI-only (not persisted). Any built-in tab write clears it.
    public private(set) var detailAppTab: [ConversationRef: String] = [:]
    /// A chat's pinned tab opened from "+N": a temporary tab with a close
    /// button until closed or replaced (TABS2); UI-only.
    public private(set) var detailOpenedTab: [ConversationRef: String] = [:]
    public private(set) var inspectorVisible: [SectionID: Bool] = [:]
    public private(set) var search: SearchState?

    public init() {}

    public func selection(in s: SectionID) -> SectionSelection? { selection[s] }

    public func tab(for ref: ConversationRef) -> ConversationTab { detailTab[ref] ?? .chat }

    public func isInspectorVisible(_ s: SectionID) -> Bool { inspectorVisible[s] ?? false }

    // MARK: writes (Navigator only)

    func setSection(_ s: SectionID, _: NavigationWriteToken) {
        guard s != section else { return }
        previousSection = section
        section = s
    }

    func setSelection(_ sel: SectionSelection?, in s: SectionID, _: NavigationWriteToken) {
        guard selection[s] != sel else { return }
        selection[s] = sel
    }

    func setTab(_ t: ConversationTab, for ref: ConversationRef, _: NavigationWriteToken) {
        if detailAppTab[ref] != nil { detailAppTab[ref] = nil }
        guard tab(for: ref) != t else { return }
        detailTab[ref] = t
    }

    func setAppTab(_ id: String, for ref: ConversationRef, _: NavigationWriteToken) {
        guard detailAppTab[ref] != id else { return }
        detailAppTab[ref] = id
    }

    func setOpenedTab(_ id: String?, for ref: ConversationRef, _: NavigationWriteToken) {
        guard detailOpenedTab[ref] != id else { return }
        detailOpenedTab[ref] = id
    }

    func setInspector(_ visible: Bool, in s: SectionID, _: NavigationWriteToken) {
        guard isInspectorVisible(s) != visible else { return }
        inspectorVisible[s] = visible
    }

    func setSearch(_ state: SearchState?, _: NavigationWriteToken) {
        guard search != state else { return }
        search = state
    }

    // MARK: persistence

    public var snapshot: NavigationState {
        var s = NavigationState()
        s.section = section
        s.previousSection = previousSection
        s.selection = Dictionary(uniqueKeysWithValues: selection.map { ($0.key.key, $0.value) })
        s.detailTab = detailTab
        s.inspectorVisible = Dictionary(uniqueKeysWithValues: inspectorVisible.map { ($0.key.key, $0.value) })
        return s
    }

    func restore(_ s: NavigationState, _: NavigationWriteToken) {
        section = s.section
        previousSection = s.previousSection
        selection = Dictionary(uniqueKeysWithValues: s.selection.compactMap { k, v in
            SectionID(key: k).map { ($0, v) }
        })
        detailTab = s.detailTab
        inspectorVisible = Dictionary(uniqueKeysWithValues: s.inspectorVisible.compactMap { k, v in
            SectionID(key: k).map { ($0, v) }
        })
        search = nil
    }
}
