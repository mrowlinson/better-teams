// TeamTags.swift — team tag management model (TAGS lane).
//
// Owners create/edit/delete/assign team tags; @tag mentions notify the
// tag's members. Graph endpoints (Microsoft Learn, `teamworkTag`):
//   List    GET    /teams/{team-id}/tags
//   Create  POST   /teams/{team-id}/tags {displayName, description?, members[]}
//   Get     GET    /teams/{team-id}/tags/{tag-id}
//   Update  PATCH  /teams/{team-id}/tags/{tag-id}
//   Delete  DELETE /teams/{team-id}/tags/{tag-id}
//   Members GET    /teams/{team-id}/tags/{tag-id}/members
//   Assign  POST   /teams/{team-id}/tags/{tag-id}/members {userId}
//   Unassign DELETE /teams/{team-id}/tags/{tag-id}/members/{member-id}
// Scopes: TeamworkTag.Read[.All] for list/get, TeamworkTag.ReadWrite[.All]
// for everything else. The app's Teams token grants NONE of these
// (docs/graph-allowlist.txt; live 403 proven 11-19 on the trial tenant:
// "Missing scope permissions … requires one of 'TeamworkTag.Read,
// TeamworkTag.ReadWrite, TeamSettings.ReadWrite.All'"). So the live
// store stays unavailable with a reason (no network attempt per load,
// no fake controls); demo is a seeded in-memory fake that acts.
import Foundation

/// One team tag. `memberIDs` are roster user ids (demo) or AAD object
/// ids (live, once scopes are granted).
public struct TeamTag: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var displayName: String
    public var description: String?
    public var memberIDs: [String]

    public init(id: String, displayName: String, description: String? = nil, memberIDs: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.memberIDs = memberIDs
    }
}

/// Pure tag helpers (unit-tested).
public enum TeamTags {
    /// Graph caps displayName at 100 characters.
    public static let maxNameLength = 100
    /// Graph create accepts at most 25 members in one call.
    public static let maxCreateMembers = 25

    /// Live-disabled reason (UI text: no URL, status code or id).
    public static let unavailableReason =
        "Tag management needs the TeamworkTag permission, which hasn't been granted yet. Ask your admin to approve it."

    /// Live 403 capability text for a failed tag read/write.
    public static let capabilityMessage =
        "tags: not allowed — TeamworkTag.ReadWrite.All is not granted."

    /// Blank-checked display name, or nil when unusable.
    public static func validName(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxNameLength else { return nil }
        return t
    }

    /// Case-insensitive substring filter over tag names. Blank query
    /// returns the tags in order.
    public static func filtered(_ tags: [TeamTag], query: String) -> [TeamTag] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.displayName.lowercased().contains(q) }
    }

    /// Tag names for the @-mention picker (display order). Query
    /// filters like people; blank returns all.
    public static func mentionCandidates(_ tags: [TeamTag], query: String) -> [String] {
        filtered(tags, query: query).map(\.displayName)
    }

    /// Insert `@Tag ` into the draft (same token shape as people:
    /// the send path is untouched, plain text like person mentions).
    public static func insert(_ name: String, into draft: String) -> String {
        MentionCompose.insert(name, into: draft)
    }
}

/// Demo tag seeds (Western names only; ids are demo-scoped).
public enum DemoTeamTags {
    public static func seed(teamID: String) -> [TeamTag] {
        [
            TeamTag(id: "\(teamID)-tag-design", displayName: "Designers",
                    description: "Design reviews and mock feedback",
                    memberIDs: ["demo-u-megan", "demo-u-tom", "demo-u-ava"]),
            TeamTag(id: "\(teamID)-tag-oncall", displayName: "On-Call",
                    description: "This week's incident rotation",
                    memberIDs: ["demo-u-luis", "demo-u-paula"]),
            TeamTag(id: "\(teamID)-tag-qa", displayName: "QA",
                    memberIDs: ["demo-u-paula", "demo-u-ethan", "demo-u-hannah"]),
        ]
    }
}
