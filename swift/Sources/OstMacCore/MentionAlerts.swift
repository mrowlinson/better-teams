// MentionAlerts.swift — om-mention-alerts lane: elevated mention alerts.
//
// @me/@team mentions break through mute (global + Teams per-chat) with a
// distinct banner (OM_MENTION category, "Mentioned you"/"Channel mention"
// subtitle) and a distinct sound (critical vs default). They do NOT break
// through Do-Not-Disturb (own Teams presence = DoNotDisturb) or local
// quiet (QuietHoursStore schedule + manual DND): those suppress
// everything, mentions included.
//
// Suppression order (ChatFilter): presence-DND > local quiet >
// mute-with-breakthrough > keyword-block > structural/meeting >
// keyword-allow > own/type/edit/noisy. Teams-presence DND is DISTINCT
// from the local DND toggle (both suppress; either one quiets).
// The Mentions row flag set is the review queue (mute/DND/quiet never stop
// flagging — opening the chat clears it); its count drives the Dock tile,
// so the badge survives banner suppression. Alert counters live in
// Diagnostics only (never the sidebar, never the banner).
import Foundation
import UserNotifications

/// Elevated-mention alert surface: reasons, categories, sound + subtitle.
/// Pure (tested); the UN posting lives in the notifiers.
public enum MentionAlert {
    /// Notify reason when a mention breaks through mute.
    public static let breakthroughReason = "mention-breakthrough"
    /// Skip reason under Do-Not-Disturb (beats mute + breakthrough).
    public static let dndReason = "dnd"
    /// Skip reason inside quiet hours (beats mute + breakthrough).
    public static let quietReason = "quiet-hours"

    /// Banner category for elevated mentions (Reply + Open chat).
    public static let categoryID = "OM_MENTION"
    /// Mention category when Reply is unwired (Open chat only).
    public static let categoryNoReplyID = "OM_MENTION_NOREPLY"

    /// Elevated mention? Owner (@me) or channel/team/everyone (@team).
    /// Same gates as the noisy-chat rules: MRI preferred, display-name
    /// backup unless matchByName is false. Blank owners never match.
    public static func isElevated(
        mentions: [Mention], ownerMRI: String?,
        ownerDisplayName: String, matchByName: Bool = true
    ) -> Bool {
        Mentions.mentionsOwner(
            mentions, ownerMRI: ownerMRI,
            ownerDisplayName: ownerDisplayName, matchByName: matchByName)
            || Mentions.mentionsChannelOrEveryone(mentions)
    }

    /// Convenience over a live event's mined mentions.
    public static func isElevated(
        message: RealtimeMessage, ownerMRI: String?,
        ownerDisplayName: String, matchByName: Bool = true
    ) -> Bool {
        isElevated(
            mentions: message.mentions, ownerMRI: ownerMRI,
            ownerDisplayName: ownerDisplayName, matchByName: matchByName)
    }

    /// Banner subtitle for an elevated mention: owner mentions name you,
    /// channel-only mentions name the blast. Nil when neither (plain).
    public static func subtitle(ownerMention: Bool, channelMention: Bool) -> String? {
        if ownerMention { return "Mentioned you" }
        if channelMention { return "Channel mention" }
        return nil
    }

    /// Banner sound: mentions play the critical tone, plain the default.
    /// The interruption level stays default (never time-sensitive): app
    /// DND/quiet suppress posting entirely, and system Focus keeps the
    /// user's own settings.
    public enum Sound: String, Sendable, Equatable {
        case `default`
        case critical
    }

    public static func sound(isMention: Bool) -> Sound {
        isMention ? .critical : .default
    }

    /// Do-Not-Disturb from the own Teams availability (PresenceStore.own).
    /// Only DoNotDisturb suppresses; every other value (and unknown/nil)
    /// alerts normally.
    public static func isDND(ownAvailability: String?) -> Bool {
        ownAvailability == "DoNotDisturb"
    }
}

extension MentionAlert.Sound {
    /// UN sound for the alert level.
    public var unSound: UNNotificationSound {
        switch self {
        case .default: .default
        case .critical: .defaultCritical
        }
    }
}

/// No-op dock sink: the app wires UnreadStore to this so the Mentions row
/// count owns the tile alone (unread counts stay sidebar + Diagnostics).
public final class NullDockBadge: DockBadging, @unchecked Sendable {
    public init() {}

    public func setBadge(_ label: String?) {}
}
