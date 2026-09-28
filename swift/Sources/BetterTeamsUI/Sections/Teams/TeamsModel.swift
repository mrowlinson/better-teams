// TeamsModel.swift — Teams selection grammar, channel tabs, and the
// section's UI-only state (UI-SPEC §6.3, §11.3).
//
// The selection lives in `NavigationModel` (R3) as a generic path:
//   [team] · [team, channel] · […, "tab:<key>"] · […, "thread:<id>"]
// `TeamsSelection` is the one parser/serializer (pure, unit-tested).
import Combine
import Foundation
import Observation
import OstMacCore

/// A channel detail tab (§6.3: Posts | Files | Notes | web tabs).
public enum ChannelTabKey: Hashable, Sendable {
    case posts, files, notes
    case web(String)

    public var raw: String {
        switch self {
        case .posts: "posts"
        case .files: "files"
        case .notes: "notes"
        case .web(let id): "web:\(id)"
        }
    }

    public init?(raw: String) {
        switch raw {
        case "posts": self = .posts
        case "files": self = .files
        case "notes": self = .notes
        default:
            guard raw.hasPrefix("web:"), raw.count > 4 else { return nil }
            self = .web(String(raw.dropFirst(4)))
        }
    }
}

public struct TeamsSelection: Hashable, Sendable {
    public var teamID: String
    public var channelID: String?
    public var tab: ChannelTabKey = .posts
    public var threadID: String?

    public init(teamID: String, channelID: String? = nil, tab: ChannelTabKey = .posts, threadID: String? = nil) {
        self.teamID = teamID
        self.channelID = channelID
        self.tab = tab
        self.threadID = threadID
    }

    public init?(_ sel: SectionSelection?) {
        guard let path = sel?.path, let team = path.first, !team.isEmpty else { return nil }
        teamID = team
        for seg in path.dropFirst() {
            if seg.hasPrefix("tab:") {
                tab = ChannelTabKey(raw: String(seg.dropFirst(4))) ?? .posts
            } else if seg.hasPrefix("thread:") {
                let id = String(seg.dropFirst(7))
                threadID = id.isEmpty ? nil : id
            } else if channelID == nil, !seg.isEmpty {
                channelID = seg
            }
        }
        if channelID == nil { tab = .posts; threadID = nil }
    }

    public var selection: SectionSelection {
        var p = [teamID]
        if let channelID {
            p.append(channelID)
            if tab != .posts { p.append("tab:\(tab.raw)") }
            if let threadID { p.append("thread:\(threadID)") }
        }
        return SectionSelection(p)
    }

    /// Row tag in the outline list (channels are unique across teams).
    public var rowTag: String { channelID.map { "chan:\($0)" } ?? "team:\(teamID)" }
}

/// Evidence aliases (§11.3 demo aliases `demo-team`, `demo-channel`,
/// `demo-thread`); demo only.
enum TeamsDemoAliases {
    static func resolve(_ raw: String) -> String {
        switch raw {
        case "demo-team": "demo-team-eng"
        case "demo-channel": DemoTeams.threadedChannelID
        case "demo-thread": DemoTeams.threadRootID
        default: raw
        }
    }
}

/// Channel tabs as the header shows them (§6.3): the three fixed tabs,
/// then at most two web tabs; the rest go into More ▾. Pure.
struct ChannelTabLayout: Equatable {
    var visibleWeb: [ChannelTab]
    var overflow: [ChannelTab]

    static let maxVisibleWeb = 2

    init(_ tabs: [ChannelTab]) {
        // Posts/Files/Notes are fixed; web and link-less tabs are extra.
        let extra = tabs.filter {
            switch $0.target {
            case .chat, .shared, .notes: false
            case .web, .none: true
            }
        }
        let web = extra.filter { if case .web = $0.target { true } else { false } }
        visibleWeb = Array(web.prefix(Self.maxVisibleWeb))
        let shown = Set(visibleWeb.map(\.id))
        overflow = extra.filter { !shown.contains($0.id) }
    }

    /// Most segments the row shows (Posts, Files, Notes, 2 web tabs).
    static let maxSegments = 3 + maxVisibleWeb

    /// Segment order: the fixed tabs, then the visible web tabs.
    var primary: [ChannelTabEntry] {
        [ChannelTabEntry(key: .posts, name: "Posts"), ChannelTabEntry(key: .files, name: "Files"),
         ChannelTabEntry(key: .notes, name: "Notes")]
            + visibleWeb.map { ChannelTabEntry(key: .web($0.id), name: $0.name) }
    }

    /// More ▾ extras; link-less tabs are listed dimmed.
    var extras: [ChannelTabEntry] {
        overflow.map { t in
            let web = if case .web = t.target { true } else { false }
            return ChannelTabEntry(key: .web(t.id), name: t.name, enabled: web)
        }
    }

    /// The first `segments` tabs as segments, the rest in More ▾. The
    /// selected tab is always a segment: when it would fold, it takes
    /// the last segment's place and that tab moves into More.
    func fold(segments: Int, selected: ChannelTabKey) -> (segments: [ChannelTabEntry], more: [ChannelTabEntry]) {
        let all = primary + extras
        let n = max(1, min(segments, primary.count))
        var shown = Array(primary.prefix(n))
        if !shown.contains(where: { $0.key == selected }), let sel = all.first(where: { $0.key == selected }) {
            shown[shown.count - 1] = sel
        }
        let keys = Set(shown.map(\.key))
        return (shown, all.filter { !keys.contains($0.key) })
    }
}

/// One channel tab as a segment or More ▾ item.
struct ChannelTabEntry: Identifiable, Equatable {
    let key: ChannelTabKey
    let name: String
    var enabled = true
    var id: String { key.raw }
}

/// UI-only Teams state (collapse, per-thread reply drafts). Never
/// mirrors a store field (R3).
@Observable
@MainActor
final class TeamsSectionState {
    /// Collapsed team ids (§6.3 "collapse state persisted").
    private(set) var collapsed: Set<String>
    var replyDrafts: [String: String] = [:]
    /// Teams whose hidden channels are revealed in the list.
    private(set) var revealHidden: Set<String> = []
    @ObservationIgnored private let key: String?

    init(accountKey: String, persist: Bool) {
        key = persist ? "bt.teams.collapsed.\(accountKey)" : nil
        collapsed = Set(key.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? [])
    }

    func isExpanded(_ teamID: String) -> Bool {
        TeamsViewModel.isExpanded(teamID: teamID, collapsed: collapsed, filtering: false)
    }

    func setExpanded(_ teamID: String, _ expanded: Bool) {
        guard isExpanded(teamID) != expanded else { return }
        collapsed = TeamsViewModel.toggled(collapsed, teamID: teamID)
        if let key { UserDefaults.standard.set(collapsed.sorted(), forKey: key) }
    }

    func toggleReveal(_ teamID: String) {
        if revealHidden.contains(teamID) { revealHidden.remove(teamID) } else { revealHidden.insert(teamID) }
    }

    /// Demo seed (in memory only).
    func seedCollapsed(_ ids: Set<String>) { collapsed = ids }
}

/// Per-channel preferences: pinned, hidden, notification level.
/// Live: hidden + level use the core `RulesStore` (notifications honor
/// them); pins are the core `PinnedChannelStore` (per account, in the
/// user's order, local only). Demo: memory only, so a demo run never
/// reads or writes the person's real rules or defaults.
@MainActor
final class ChannelPrefs: ObservableObject {
    /// Pinned channel ids, first = top of the Pinned section.
    var pinned: [String] { pins.orderedIDs }
    @Published private var memHidden: Set<String> = []
    @Published private var memLevels: [String: ChatNotifyLevel] = [:]
    private let rules: RulesStore?
    let pins: PinnedChannelStore
    private var pinsChange: AnyCancellable?

    init(pins: PinnedChannelStore, rules: RulesStore?, demo: Bool) {
        self.rules = demo ? nil : rules
        self.pins = pins
        pinsChange = pins.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func isPinned(_ id: String) -> Bool { pins.isPinned(id) }

    func setPinned(_ id: String, _ on: Bool) { pins.setPinned(id, on) }

    func isHidden(_ id: String) -> Bool { rules?.isHidden(chatID: id) ?? memHidden.contains(id) }

    func setHidden(_ id: String, _ on: Bool) {
        guard isHidden(id) != on else { return }
        if let rules {
            objectWillChange.send()
            rules.setHidden(chatID: id, hidden: on)
        } else if on {
            memHidden.insert(id)
        } else {
            memHidden.remove(id)
        }
    }

    func level(_ id: String) -> ChatNotifyLevel { rules?.level(chatID: id) ?? memLevels[id] ?? .all }

    func setLevel(_ id: String, _ l: ChatNotifyLevel) {
        guard level(id) != l else { return }
        if let rules {
            objectWillChange.send()
            rules.setLevel(chatID: id, level: l)
        } else {
            memLevels[id] = l
        }
    }

    /// Demo seed (in memory only).
    func seedDemo(pinned: [String], hidden: Set<String>) {
        pins.seedDemo(pinned)
        memHidden = hidden
    }
}
