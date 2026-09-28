// NcDelivery.swift — om-nc-delivery: Notification Center banner mapping.
//
// Single pure layer between the rules engine (ChatFilter.Decision) and the
// UNUserNotificationCenter backends (Notifier + SystemNotificationCenter):
// - decision-to-banner: only .notify decisions banner; every .skip reason
//   (mute, own, type, edit, noisy, keyword-block, …) suppresses.
// - grouping: every banner's threadIdentifier is its chatID, so banners
//   stack per thread in Notification Center.
// - redact: when the screen is locked the banner carries generic
//   title/body — never sender, chat name, or message text.
// - settings: preview-off hides message text (meeting bodies stay),
//   sound-off posts silent — both flow through this one banner home.
// - routing: one pure action->route map tolerant of both userInfo keys
//   (om-notif "chatID" and om-rules "OMChatID"); both delegates share it
//   so click opens the chat and Reply sends no matter which backend
//   posted or which delegate is installed.
import CoreGraphics
import Foundation
import UserNotifications

public enum NcDelivery {
    /// Generic lock-screen title/body: no sender, chat, or text leaks.
    public static let redactedTitle = "New message"
    public static let redactedBody = "Unlock to view the message."
    /// Empty-text fallback (matches Notifier's direct-post behavior).
    public static let emptyBody = "(no text content)"

    /// One banner to post: the decision mapped to NC content fields.
    /// `threadIdentifier` is always the chatID (group by thread).
    /// Elevated mentions carry the OM_MENTION style (the caller flags
    /// them; Notifier renders the category + critical sound + subtitle).
    public struct Banner: Sendable, Equatable {
        public let id: String // msgId (UN request identifier)
        public let chatID: String
        public let title: String
        public let body: String
        public let threadIdentifier: String
        /// Play the banner sound. False = silent post (Settings → Sound).
        public let sound: Bool
        public let isMention: Bool
        /// Banner subtitle for elevated mentions ("Mentioned you" /
        /// "Channel mention"); nil for plain messages.
        public let subtitle: String?

        public init(id: String, chatID: String, title: String, body: String, sound: Bool = true, isMention: Bool = false, subtitle: String? = nil) {
            self.id = id
            self.chatID = chatID
            self.title = title
            self.body = body
            threadIdentifier = chatID
            self.sound = sound
            self.isMention = isMention
            self.subtitle = subtitle
        }
    }

    /// Map one rules decision to a banner. Nil = suppressed (any .skip).
    /// Meeting-starting decisions synthesize their body (raw beacons/blobs
    /// never shown); `screenLocked` redacts title+body to generics.
    /// `showPreview` false hides message text (synthesized meeting bodies
    /// are not message content, so they stay); `sound` false posts silent.
    /// `isMention`/`subtitle` ride through for the OM_MENTION style.
    /// gap-g1: `accountName` prefixes the title (`[Work] …`) so
    /// background banners name the account (locked redaction drops the
    /// prefix too — no account leak on the lock screen).
    public static func makeBanner(
        for msg: RealtimeMessage, chatName: String,
        decision: ChatFilter.Decision, screenLocked: Bool,
        showPreview: Bool = true, sound: Bool = true,
        isMention: Bool = false, subtitle: String? = nil,
        accountName: String? = nil
    ) -> Banner? {
        guard case .notify(let reason) = decision else { return nil }
        let title: String
        var body: String
        if reason == ChatFilter.meetingStartingReason {
            if chatName.isEmpty || chatName == msg.chatID {
                title = "Teams meeting"
                body = "Meeting starting"
            } else {
                title = chatName
                body = "Meeting starting: \(chatName)"
            }
        } else if chatName.isEmpty || chatName == msg.chatID {
            title = msg.sender.isEmpty ? "Teams message" : msg.sender
            body = msg.text.isEmpty ? emptyBody : msg.text
        } else if msg.sender.isEmpty {
            title = chatName
            body = msg.text.isEmpty ? emptyBody : msg.text
        } else if chatName == msg.sender {
            // 1:1 chat: the chat name IS the sender — no "X in X".
            title = msg.sender
            body = msg.text.isEmpty ? emptyBody : msg.text
        } else {
            title = "\(msg.sender) in \(chatName)"
            body = msg.text.isEmpty ? emptyBody : msg.text
        }
        if screenLocked {
            return Banner(id: msg.msgId, chatID: msg.chatID, title: redactedTitle, body: redactedBody, sound: sound, isMention: isMention, subtitle: subtitle)
        }
        if !showPreview, reason != ChatFilter.meetingStartingReason {
            body = MessageNotifications.hiddenPreviewBody
        }
        let named: String
        if let name = accountName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            named = "[\(name)] \(title)"
        } else {
            named = title
        }
        return Banner(id: msg.msgId, chatID: msg.chatID, title: named, body: body, sound: sound, isMention: isMention, subtitle: subtitle)
    }

    /// Chat id from banner userInfo: accepts both backend keys (om-notif
    /// "chatID", om-rules "OMChatID"). Blank/missing = nil.
    public static func chatID(from userInfo: [AnyHashable: Any]) -> String? {
        for key in [SystemNotificationCenter.chatIDKey, OmReplyInfo.chatIDKey] {
            if let id = userInfo[key] as? String, !id.isEmpty { return id }
        }
        return nil
    }

    /// Call id from an incoming-call banner (gap-g3 OMCallID key).
    /// Blank/missing = nil. Disjoint from the chat keys above.
    public static func callID(from userInfo: [AnyHashable: Any]) -> String? {
        if let id = userInfo[OmCallInfo.callIDKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// Owning account profile id from a message banner (gap-g1
    /// OMAccountID key). Blank/missing = nil = the active account.
    /// Disjoint from the chat/call keys.
    public static func accountID(from userInfo: [AnyHashable: Any]) -> String? {
        if let id = userInfo[OmReplyInfo.accountIDKey] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// Pure action->route map shared by both center delegates:
    /// Reply (+ non-empty text) sends, banner click / Open-chat opens,
    /// call Accept/Decline answer the call, call click shows the app,
    /// dismiss and unknown actions route nowhere.
    public static func route(
        actionID: String, userInfo: [AnyHashable: Any], replyText: String? = nil
    ) -> NotificationRoute {
        // gap-g3: call banners route before the chat map (disjoint keys).
        if let call = callID(from: userInfo) {
            if actionID == OmCallInfo.acceptActionID {
                return .acceptCall(callID: call)
            }
            if actionID == OmCallInfo.declineActionID {
                return .declineCall(callID: call)
            }
            if actionID == UNNotificationDefaultActionIdentifier {
                return .showCall(callID: call)
            }
            return .none
        }
        guard let chat = chatID(from: userInfo) else { return .none }
        if actionID == SystemNotificationCenter.replyActionID,
           let text = replyText, !text.isEmpty
        {
            return .reply(chatID: chat, text: text)
        }
        if actionID == UNNotificationDefaultActionIdentifier
            || actionID == OmReplyInfo.openActionID
        {
            return .open(chatID: chat)
        }
        return .none
    }

    /// True while the login session is screen-locked (CGSession flag).
    /// Never throws: any unreadable state reads unlocked (banner shows).
    public static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
