// Notifier.swift — om-rules lane: native notification delivery.
//
// Port of TeamsNotifier's Notifier (title/body/sound, Reply + Open chat
// actions), adapted for OstMac:
// - Category ids are OM_* (no TeamsNotifier overlap on shared machines).
// - Two categories: with Reply (when onReply is wired) and open-only
//   (when it is not) — an unwired Reply button never shows.
// - Click opens the chat (om-nc-delivery); only chat-less system/test
//   notifs keep the TeamsNotifier click-copies-body behavior.
// - No logging (observability skipped): post failures are silent.
import AppKit
import Foundation
import UserNotifications

/// Notification category/action/userInfo for message banners. userInfo
/// carries the chat id so the action handlers know where to reply/open.
public enum OmReplyInfo {
    public static let categoryID = "OM_MESSAGE"
    public static let categoryNoReplyID = "OM_MESSAGE_NOREPLY"
    public static let replyActionID = "OM_REPLY"
    public static let chatIDKey = "OMChatID"
    /// Second action next to Reply: opens the chat in the app.
    public static let openActionID = "OM_OPEN_CHAT"
    public static let openActionTitle = "Open chat"
    /// Action button title: banner/alert hover + NC expanded. Keep "Reply".
    public static let actionTitle = "Reply"
    /// Inline-reply send button title (expanded UI).
    public static let sendButtonTitle = "Send"
    /// Inline-reply field placeholder (expanded UI).
    public static let textInputPlaceholder = "Type a reply…"
    /// Owning account profile id (gap-g1 background banners). Absent =
    /// the active account (back-compat: every live banner omits it).
    public static let accountIDKey = "OMAccountID"

    public static func userInfo(chatID: String, accountID: String? = nil) -> [String: String] {
        var info = [chatIDKey: chatID]
        if let accountID, !accountID.isEmpty {
            info[accountIDKey] = accountID
        }
        return info
    }

    /// Tolerant read: this backend's key plus om-notif's "chatID",
    /// so banners route whichever backend posted them.
    public static func chatID(from userInfo: [AnyHashable: Any]) -> String? {
        NcDelivery.chatID(from: userInfo)
    }
}

/// Native notifications. Title = "sender in chat" (or sender when the chat
/// has no better name). Body = full message text. Sound on. Banners group
/// by thread (threadIdentifier = chatID) and redact to generic text while
/// the screen is locked. Click / Open chat foregrounds the chat via
/// onOpenChat; Reply (text-input) posts via onReply. When onReply is nil
/// the banner offers Open chat only.
/// Sticky banners: owner sets Alerts style in System Settings > Notifications.
public final class Notifier: NSObject, @unchecked Sendable {
    public static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    /// Reply sender, wired by the app (chatID, text, owning account —
    /// nil = active account). Result failure text is surfaced as a loud
    /// system notification. Nil = no Reply button offered.
    public var onReply: (@Sendable (String, String, String?) async -> Result<Void, Error>)?

    /// Open-chat handler, wired by the app (chatID, owning account —
    /// nil = active account).
    public var onOpenChat: (@Sendable (String, String?) async -> Void)?

    /// gap-g3: call-banner handlers, wired by the app (call id in).
    /// Used only when this delegate is installed; the live app routes
    /// call actions through the shared delegate's .omNotif*Call notes.
    public var onAcceptCall: (@Sendable (String) async -> Void)?
    public var onDeclineCall: (@Sendable (String) async -> Void)?

    /// Screen-lock probe (om-nc-delivery). Nil = live CGSession read;
    /// tests inject a stub. Locked message banners redact title+body.
    public var lockCheck: (@Sendable () -> Bool)?

    private override init() {
        super.init()
    }

    public func setup() {
        center.delegate = self
        // Reply affordance: text-input action, minimal options (no
        // .foreground/.destructive/.authenticationRequired — any of those
        // hides or degrades the button). Explicit placeholder: the SDK
        // default is empty, which leaves the expanded field unlabeled.
        let reply = UNTextInputNotificationAction(
            identifier: OmReplyInfo.replyActionID,
            title: OmReplyInfo.actionTitle,
            options: [],
            textInputButtonTitle: OmReplyInfo.sendButtonTitle,
            textInputPlaceholder: OmReplyInfo.textInputPlaceholder)
        // Open chat: foregrounds the app so the conversation appears
        // above the owner's work.
        let open = UNNotificationAction(
            identifier: OmReplyInfo.openActionID,
            title: OmReplyInfo.openActionTitle,
            options: [.foreground])
        // UI-SPEC §9.3 MESSAGE: Reply + Mark as Read.
        let markRead = OmMarkReadInfo.action
        let message = UNNotificationCategory(
            identifier: OmReplyInfo.categoryID, actions: [reply, markRead, open],
            intentIdentifiers: [], options: [])
        let messageNoReply = UNNotificationCategory(
            identifier: OmReplyInfo.categoryNoReplyID, actions: [markRead, open],
            intentIdentifiers: [], options: [])
        // Elevated mention banners (om-mention-alerts): same actions,
        // distinct category so the style + sound stay separable.
        let mention = UNNotificationCategory(
            identifier: MentionAlert.categoryID, actions: [reply, markRead, open],
            intentIdentifiers: [], options: [])
        let mentionNoReply = UNNotificationCategory(
            identifier: MentionAlert.categoryNoReplyID, actions: [markRead, open],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([message, messageNoReply, mention, mentionNoReply, OmCallInfo.category,
                                          MeetingNotifyInfo.category])
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Full per-setting state (alert/sound/badge + style). Authorization can
    /// read authorized while the app is switched off in Settings.
    public func settings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    /// chatID attaches the message actions + thread grouping (banners
    /// stack per thread). Locked message banners redact to generic text.
    /// Nil (system/test notifs) posts a plain notification with no action.
    /// `sound` false posts silent (Settings → Sound, via the caller).
    /// Elevated mentions (om-mention-alerts) take the OM_MENTION
    /// category, the critical sound, and the mention subtitle.
    /// gap-g1: `accountID` stamps the owning account into userInfo
    /// (nil/blank = active account, back-compat) and scopes the thread
    /// so cross-account banners never merge. The title already names the
    /// account when NcDelivery built it (`[Work] …`); this posts it
    /// verbatim. Locked banners redact everything (no account leak on
    /// the lock screen).
    public func post(title: String, body: String, id: String? = nil, chatID: String? = nil, sound: Bool = true, isMention: Bool = false, subtitle: String? = nil, accountID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "(no text content)" : body
        content.sound = sound ? MentionAlert.sound(isMention: isMention).unSound : nil
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        if let chatID, !chatID.isEmpty {
            if isMention {
                content.categoryIdentifier = onReply == nil ? MentionAlert.categoryNoReplyID : MentionAlert.categoryID
            } else {
                content.categoryIdentifier = onReply == nil ? OmReplyInfo.categoryNoReplyID : OmReplyInfo.categoryID
            }
            let acct = (accountID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            content.userInfo = OmReplyInfo.userInfo(
                chatID: chatID, accountID: acct.isEmpty ? nil : acct)
            content.threadIdentifier = acct.isEmpty ? chatID : "\(acct):\(chatID)"
            if lockCheck?() ?? NcDelivery.isScreenLocked() {
                content.title = NcDelivery.redactedTitle
                content.body = NcDelivery.redactedBody
            }
        }
        let req = UNNotificationRequest(
            identifier: id ?? UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(req)
    }

    public func postSystem(title: String, body: String) {
        post(title: title, body: body, id: "system-\(title)")
    }

    /// gap-g3: incoming-call banner (Accept/Decline actions, stable id
    /// per call so re-posts replace). SILENT — the CallRinger loop owns
    /// all call audio so banner + ring never double-play.
    /// gap-g4: content via OmCallInfo.makeContent (interruption
    /// .active — Focus/DND suppress by OS policy; the post still
    /// fires every ring, the OS decides display).
    public func postCall(title: String, body: String, callID: String) {
        let content = OmCallInfo.makeContent(
            title: title, body: body, callID: callID)
        let req = UNNotificationRequest(
            identifier: OmCallInfo.requestID(callID: callID),
            content: content,
            trigger: nil
        )
        center.add(req)
    }

    /// gap-g3: pull a call banner (answered, declined, dismissed, timed
    /// out — every ring end withdraws, so no stale Accept lingers).
    public func withdrawCall(callID: String) {
        let id = OmCallInfo.requestID(callID: callID)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Shared route: Reply posts, banner click / Open-chat opens.
        // gap-g1: the owning account rides alongside (nil = active) so
        // background banners route to their account, never the active one.
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let info = response.notification.request.content.userInfo
        let accountID = NcDelivery.accountID(from: info)
        switch NcDelivery.route(
            actionID: response.actionIdentifier,
            userInfo: info,
            replyText: text)
        {
        case .reply(let chatID, _):
            if let textResponse = response as? UNTextInputNotificationResponse {
                await handleReply(textResponse, chatID: chatID, accountID: accountID)
            }
            return
        case .open(let chatID):
            await onOpenChat?(chatID, accountID)
            return
        case .acceptCall(let callID):
            await onAcceptCall?(callID)
            return
        case .declineCall(let callID):
            await onDeclineCall?(callID)
            return
        case .showCall:
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        case .none:
            break
        }
        // Unrouted clicks on system/test notifs (no chat) copy the body;
        // message banners never copy (click opens, dismiss is silent).
        guard OmReplyInfo.chatID(from: info) == nil else { return }
        let body = response.notification.request.content.body
        guard !body.isEmpty else { return }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(body, forType: .string)
        }
    }

    private func handleReply(_ response: UNTextInputNotificationResponse, chatID: String, accountID: String?) async {
        let text = response.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let onReply else { return }
        switch await onReply(chatID, text, accountID) {
        case .success:
            break
        case .failure(let err):
            postSystem(title: "OstMac: reply failed", body: "Reply failed: \(err.localizedDescription)")
        }
    }

    // Show banners even while the app is frontmost. .list keeps the
    // foreground copy in Notification Center too, where the Reply button
    // sits expanded. No API forces always-visible buttons; hover
    // (banner/alert) + expanded NC is the macOS ceiling.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
