// TeamRights.swift — who may edit / delete a team's channels (CHANMENU).
//
// Teams lets owners always, and members only while the team's
// memberSettings allow it (allowCreateUpdateChannels for edit,
// allowDeleteChannels for delete). The General channel can never be
// deleted. Anything unknown (a failed read) is allowed: Teams itself
// decides and a refusal comes back as a plain message, so a failed read
// never hides an action the user really has.
import Foundation

/// One team's member permissions and General channel id. `nil` fields
/// are unknown (the read failed or the tenant omitted them).
public struct TeamMemberSettings: Codable, Sendable, Equatable {
    public var allowDeleteChannels: Bool?
    public var allowCreateUpdateChannels: Bool?
    public var primaryChannelId: String?

    enum CodingKeys: String, CodingKey {
        case allowDeleteChannels = "allow_delete_channels"
        case allowCreateUpdateChannels = "allow_create_update_channels"
        case primaryChannelId = "primary_channel_id"
    }

    public init(allowDeleteChannels: Bool? = nil, allowCreateUpdateChannels: Bool? = nil,
                primaryChannelId: String? = nil) {
        self.allowDeleteChannels = allowDeleteChannels
        self.allowCreateUpdateChannels = allowCreateUpdateChannels
        self.primaryChannelId = primaryChannelId
    }
}

/// A channel write the menu can offer.
public enum ChannelAction: Sendable {
    case edit, delete
}

/// Result of the permission check: enabled, or disabled with the reason
/// shown in the menu.
public enum ChannelPermission: Equatable, Sendable {
    case allowed
    case denied(String)

    public var isAllowed: Bool { self == .allowed }
    public var reason: String? {
        if case .denied(let why) = self { why } else { nil }
    }
}

public enum ChannelRights {
    /// The General channel's usual name; the fallback when the team's
    /// primary channel id could not be read.
    public static let generalName = "General"

    /// Pure gate. `isOwner` nil = ownership unknown; `settings` nil =
    /// member settings unknown.
    public static func evaluate(
        _ action: ChannelAction, isGeneral: Bool, isOwner: Bool?, settings: TeamMemberSettings?
    ) -> ChannelPermission {
        if action == .delete, isGeneral {
            return .denied("The General channel can't be deleted.")
        }
        if isOwner == true { return .allowed }
        guard isOwner == false else { return .allowed }
        switch action {
        case .delete:
            if settings?.allowDeleteChannels == false {
                return .denied("Only team owners can delete channels in this team.")
            }
        case .edit:
            if settings?.allowCreateUpdateChannels == false {
                return .denied("Only team owners can edit channels in this team.")
            }
        }
        return .allowed
    }

    /// Whether `channel` is the team's General channel: the primary id
    /// when known, else the name.
    public static func isGeneral(_ channel: TeamChannel, primaryID: String?) -> Bool {
        if let primaryID, !primaryID.isEmpty { return channel.channelId == primaryID }
        return channel.name.caseInsensitiveCompare(generalName) == .orderedSame
    }

    /// Tree order: General first in each team, the rest keep server
    /// order (stable). `primary` maps teamID → General channel id.
    public static func generalFirst(_ teams: [TeamItem], primary: [String: String] = [:]) -> [TeamItem] {
        teams.map { team in
            let general = team.channels.filter { isGeneral($0, primaryID: primary[team.teamId]) }
            guard !general.isEmpty,
                  let first = team.channels.first, !general.contains(where: { $0.channelId == first.channelId })
            else { return team }
            let rest = team.channels.filter { c in !general.contains { $0.channelId == c.channelId } }
            return TeamItem(teamId: team.teamId, name: team.name, channels: general + rest)
        }
    }
}
