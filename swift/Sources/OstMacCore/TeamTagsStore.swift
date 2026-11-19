// TeamTagsStore.swift — one team's tag store (TAGS lane).
//
// Demo: a seeded in-memory fake that acts (create/edit/delete/assign
// persist while the window lives). Live: unavailable with
// `TeamTags.unavailableReason` — the Teams token lacks TeamworkTag.*
// (live 403 proven 11-19), so the store never attempts network and
// the UI disables tag controls instead of faking them.
import Combine
import Foundation

/// Tag content state (mirrors TeamRosterState).
public enum TeamTagsState: Equatable, Sendable {
    /// Fetch in flight.
    case loading
    /// Tags in `tags`.
    case loaded
    /// Live scope-blocked (associated user-facing reason).
    case unavailable(String)
}

@MainActor
public final class TeamTagsStore: ObservableObject {
    /// Team this store belongs to.
    public let teamID: String
    /// Latest rows (only meaningful in `.loaded`).
    @Published public private(set) var tags: [TeamTag] = []
    /// Current content state. Demo starts `.loaded`; live `.unavailable`.
    @Published public private(set) var state: TeamTagsState = .loading
    /// Last write error (shown once, cleared on next write).
    @Published public private(set) var error: String?

    private let demo: Bool

    /// Shared demo tags by team, so the manager sheet and the
    /// @-mention picker see the same rows (and demo edits).
    private static var demoRegistry: [String: [TeamTag]] = [:]

    /// Demo tags for one team (seeded on first read). Live returns
    /// [] (scope-blocked: the picker never fakes tag rows).
    public static func demoTags(teamID: String) -> [TeamTag] {
        if let hit = demoRegistry[teamID] { return hit }
        let seed = DemoTeamTags.seed(teamID: teamID)
        demoRegistry[teamID] = seed
        return seed
    }

    public init(teamID: String, demo: Bool, seed: [TeamTag]? = nil) {
        self.teamID = teamID
        self.demo = demo
        if demo {
            if let seed { self.tags = seed; Self.demoRegistry[teamID] = seed } else { self.tags = Self.demoTags(teamID: teamID) }
            self.state = .loaded
        } else {
            self.state = .unavailable(TeamTags.unavailableReason)
        }
    }

    /// Live availability gate: demo acts, live refuses with the
    /// scope reason (no fake controls, no network attempt).
    public var canEdit: Bool { demo }

    /// Demo writes publish to the shared registry too.
    private func persist() {
        if demo { Self.demoRegistry[teamID] = tags }
    }

    @discardableResult
    public func create(name: String, description: String?, memberIDs: [String]) -> Bool {
        error = nil
        guard demo else { error = TeamTags.unavailableReason; return false }
        guard let valid = TeamTags.validName(name) else { error = "Give the tag a name (up to 100 characters)."; return false }
        let trimmed = Array(memberIDs.prefix(TeamTags.maxCreateMembers))
        tags.append(TeamTag(id: "\(teamID)-tag-\(UUID().uuidString.prefix(8).lowercased())",
                            displayName: valid, description: description?.isEmpty == true ? nil : description,
                            memberIDs: trimmed))
        persist()
        return true
    }

    @discardableResult
    public func rename(id: String, name: String) -> Bool {
        error = nil
        guard demo else { error = TeamTags.unavailableReason; return false }
        guard let valid = TeamTags.validName(name) else { error = "Give the tag a name (up to 100 characters)."; return false }
        guard let i = tags.firstIndex(where: { $0.id == id }) else { return false }
        tags[i].displayName = valid
        persist()
        return true
    }

    @discardableResult
    public func remove(id: String) -> Bool {
        error = nil
        guard demo else { error = TeamTags.unavailableReason; return false }
        tags.removeAll { $0.id == id }
        persist()
        return true
    }

    @discardableResult
    public func setMembers(id: String, memberIDs: [String]) -> Bool {
        error = nil
        guard demo else { error = TeamTags.unavailableReason; return false }
        guard let i = tags.firstIndex(where: { $0.id == id }) else { return false }
        tags[i].memberIDs = memberIDs
        persist()
        return true
    }

    public func clearError() { error = nil }
}
