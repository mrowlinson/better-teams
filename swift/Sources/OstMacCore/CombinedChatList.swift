// CombinedChatList.swift — chatlist-org R2: chats+channels combined view.
//
// Pure projection behind the default-off
// `AppSettings.combinedChatsChannels` switch: when on, the chat list
// shows one Channels section with every visible channel (hidden teams
// and hidden channels excluded, team order then channel order); when
// off, no channel rows. The pane renders the rows with the shared
// `ChannelRow`; tapping one selects the channel in the Teams section.
import Foundation

/// Combined chats+channels rows for the chat list.
public enum CombinedChatList {
    /// One channel row: identity for selection, names for display.
    public struct ChannelRow: Sendable, Equatable {
        public let teamID: String
        public let teamName: String
        public let channelID: String
        public let channelName: String

        public init(teamID: String, teamName: String, channelID: String, channelName: String) {
            self.teamID = teamID
            self.teamName = teamName
            self.channelID = channelID
            self.channelName = channelName
        }
    }

    /// Visible channel rows in team-then-channel order. Empty unless
    /// `combined` is on (the default-off switch gates everything).
    public static func channelRows(
        teams: [TeamItem],
        hiddenTeams: Set<String> = [],
        hiddenChannels: Set<String> = [],
        combined: Bool
    ) -> [ChannelRow] {
        guard combined else { return [] }
        var rows: [ChannelRow] = []
        for team in teams {
            guard !hiddenTeams.contains(team.teamId) else { continue }
            for ch in team.channels {
                guard !hiddenChannels.contains(ch.channelId) else { continue }
                rows.append(ChannelRow(teamID: team.teamId, teamName: team.name,
                                       channelID: ch.channelId, channelName: ch.name))
            }
        }
        return rows
    }
}
