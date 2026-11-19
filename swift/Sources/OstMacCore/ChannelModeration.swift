// ChannelModeration.swift — who can post / reply in a channel (TEAMMOD).
//
// Teams lets owners moderate a channel: restrict new posts to everyone,
// everyone-except-guests, or moderators only, and restrict replies to
// everyone or author+moderators. Unmoderated (unknown fields nil) behaves
// as everyone/everyone. Moderators are the team's owners (implicit) plus
// any listed channel moderators; the UI shows the owner list from the
// roster whenever posting is moderators-only. Writes are owner-only and
// fail closed: an unknown ownership never enables them.
import Foundation

/// Who may start new posts in a channel.
public enum WhoCanPost: String, Sendable, CaseIterable, Equatable {
    case everyone
    case everyoneExceptGuests
    case moderators

    public var label: String {
        switch self {
        case .everyone: return "Everyone"
        case .everyoneExceptGuests: return "Everyone except guests"
        case .moderators: return "Moderators only"
        }
    }

    /// Graph wire value; unknown strings fall back to everyone.
    public static func from(_ raw: String?) -> WhoCanPost {
        guard let raw else { return .everyone }
        return WhoCanPost(rawValue: raw) ?? .everyone
    }
}

/// Who may reply to posts in a channel.
public enum WhoCanReply: String, Sendable, CaseIterable, Equatable {
    case everyone
    case authorAndModerators

    public var label: String {
        switch self {
        case .everyone: return "Everyone"
        case .authorAndModerators: return "Author and moderators"
        }
    }

    public static func from(_ raw: String?) -> WhoCanReply {
        guard let raw else { return .everyone }
        return WhoCanReply(rawValue: raw) ?? .everyone
    }
}

/// One channel's moderation settings. `nil` fields are unknown (the
/// read failed or the tenant omitted them) and render as the default.
public struct ChannelModeration: Codable, Sendable, Equatable {
    public var userNewMessageRestriction: String?
    public var replyRestriction: String?
    public var allowBots: Bool?
    public var allowConnectors: Bool?

    enum CodingKeys: String, CodingKey {
        case userNewMessageRestriction = "user_new_message_restriction"
        case replyRestriction = "reply_restriction"
        case allowBots = "allow_bots"
        case allowConnectors = "allow_connectors"
    }

    public init(userNewMessageRestriction: String? = nil, replyRestriction: String? = nil,
                allowBots: Bool? = nil, allowConnectors: Bool? = nil) {
        self.userNewMessageRestriction = userNewMessageRestriction
        self.replyRestriction = replyRestriction
        self.allowBots = allowBots
        self.allowConnectors = allowConnectors
    }

    public var posts: WhoCanPost { WhoCanPost.from(userNewMessageRestriction) }
    public var replies: WhoCanReply { WhoCanReply.from(replyRestriction) }
    public var isModerated: Bool { posts != .everyone || replies != .everyone }
}

/// One team's privacy. Unknown renders as-is (no guess).
public enum TeamPrivacy: String, Sendable, Equatable {
    case `private`
    case `public`
    case unknown

    public var label: String {
        switch self {
        case .private: return "Private (invite-only)"
        case .public: return "Public (anyone in the org can join)"
        case .unknown: return "Unknown"
        }
    }

    public static func from(_ raw: String?) -> TeamPrivacy {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return .unknown }
        return TeamPrivacy(rawValue: raw) ?? .unknown
    }
}

/// FFI visibility answer: `{ok, team_id, visibility?}` (TEAMMOD).
public struct TeamVisibilityResponse: Codable, Sendable, Equatable {
    public var teamId: String?
    public var visibility: String?

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case visibility
    }

    public init(teamId: String? = nil, visibility: String? = nil) {
        self.teamId = teamId
        self.visibility = visibility
    }

    public var privacy: TeamPrivacy { TeamPrivacy.from(visibility) }
}

public enum ChannelModerationRights {
    /// Moderation + privacy writes need a KNOWN owner (fail closed:
    /// these change tenant-wide settings, unlike row edits Teams itself
    /// would refuse). Unknown ownership disables the controls.
    public static func canEdit(isOwner: Bool?) -> Bool {
        isOwner == true
    }
}
