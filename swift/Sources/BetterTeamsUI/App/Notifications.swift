// Notifications.swift — the app side of notifications (UI-SPEC §9.3).
//
// Categories live in the core (`Notifier.setup`): MESSAGE (`OM_MESSAGE`,
// `OM_MENTION`: Reply, Mark as Read), CALL (`OM_CALL`: Accept, Decline)
// and MEETING (`OM_MEETING`: Join). The rules engine (ChatFilter,
// NotifyRule, quiet hours, Focus sync, keyword and mention alerts, mute
// and snooze) decides and posts message banners in the core, unchanged.
// This file routes the responses the core's shared delegate re-posts to
// the window through `Navigator` (click-through), keeps the foreground
// rule's snapshot current (`ForegroundBannerPolicy`), and schedules the
// MEETING reminders, and draws sender avatars for message banners
// (communication notifications, §9.3). Demo and evidence runs never post
// a system notification and never request permission.
import AppKit
import Combine
import OstMacCore
import SwiftUI
import UserNotifications

@MainActor
final class NotificationRouter {
    /// System notifications only for live runs (never demo or evidence).
    static func postsSystemNotifications(_ o: LaunchOptions) -> Bool { !o.demo && !o.evidence }

    private weak var shell: ShellWindowController?
    private var observers: [NSObjectProtocol] = []
    private var subs: Set<AnyCancellable> = []
    private(set) var reminders: MeetingReminders?

    init(shell: ShellWindowController) {
        self.shell = shell
        let m = shell.model
        guard let app = m.app else { return }
        observe(.omNotifOpenChat) { [weak self] info in
            guard let id = info["chatID"] as? String else { return }
            // A banner of another account: the core switches first.
            if let acct = info["accountID"] as? String, acct != app.accounts.activeID { return }
            self?.open(Route(path: ["chat", id]))
        }
        observe(.omNotifMarkRead) { info in
            guard let id = info["chatID"] as? String else { return }
            app.unread.markRead(chatID: id)
            app.mentions.markRead(chatID: id)
        }
        observe(.omNotifPresenceUndo) { _ in app.presenceTruth.undoLastAutoChange() }
        observe(.omNotifShowCall) { [weak self] _ in
            self?.shell?.model.call?.show()
        }
        observe(.omNotifMeeting) { [weak self] info in
            guard let self, let wc = self.shell, let id = info["meetingID"] as? String else { return }
            let join = info["join"] as? Bool ?? false
            if join, let meeting = app.meetings.meetings.first(where: { $0.id == id }) {
                self.bringForward(wc)
                CalendarSection.join(meeting, wc.model)
            } else {
                self.open(Route(path: ["calendar", id]))
            }
        }
        // Foreground rule: the conversation on screen never banners;
        // banners while active follow Settings ▸ General.
        app.$openChatID.sink { [weak self] _ in self?.queuePolicy() }.store(in: &subs)
        AppSettings.shared.changes.sink { [weak self] in self?.queuePolicy() }.store(in: &subs)
        syncPolicy()
        if Self.postsSystemNotifications(m.options) {
            reminders = MeetingReminders(meetings: app.meetings)
            SystemNotificationCenter.senderImage = { Self.avatarPNG($0) }
            // Quiet banner with Undo for every automatic status change;
            // withdrawn once the offer is used, dismissed or expired.
            app.presenceTruth.$undoOffer.dropFirst().removeDuplicates().sink { offer in
                let center = UNUserNotificationCenter.current()
                guard let offer, !offer.isExpired() else {
                    center.removeDeliveredNotifications(withIdentifiers: [PresenceUndoInfo.requestID])
                    return
                }
                center.add(UNNotificationRequest(identifier: PresenceUndoInfo.requestID,
                                                 content: PresenceUndoInfo.makeContent(offer), trigger: nil))
            }.store(in: &subs)
        }
    }

    /// The sender's monogram avatar (the one rows show, G6: no photos)
    /// as PNG for the banner.
    static func avatarPNG(_ name: String) -> Data? {
        let r = ImageRenderer(content: Avatar(name: name, diameter: 64))
        r.scale = 2
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    private func observe(_ name: Notification.Name, _ body: @escaping @MainActor ([AnyHashable: Any]) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            let info = note.userInfo ?? [:]
            MainActor.assumeIsolated { body(info) }
        })
    }

    private func open(_ route: Route) {
        guard let wc = shell else { return }
        bringForward(wc)
        wc.navigator.apply(route)
    }

    private func bringForward(_ wc: ShellWindowController) {
        NSApp.activate()
        wc.window?.makeKeyAndOrderFront(nil)
    }

    private var policyQueued = false

    /// Publishers fire in willSet; read the values after they land.
    private func queuePolicy() {
        guard !policyQueued else { return }
        policyQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.policyQueued = false
            self?.syncPolicy()
        }
    }

    private func syncPolicy() {
        ForegroundBannerPolicy.shared.update(onScreenChatID: shell?.model.app?.openChatID,
                                             bannersWhileActive: AppSettings.shared.bannersWhileActive)
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }
}

/// MEETING reminders (§9.3): one pending request per upcoming online
/// meeting, delivered 5 minutes before it starts (a notification
/// trigger, no app timer). Live only; re-synced whenever the meetings
/// list changes, so moved or cancelled meetings never ring stale.
@MainActor
final class MeetingReminders {
    private var sub: AnyCancellable?
    private var scheduled: Set<String> = []

    init(meetings: MeetingsViewModel) {
        sub = meetings.$meetings.sink { [weak self] list in self?.sync(list, now: Date()) }
    }

    /// Requests to schedule: online meetings with a join link whose
    /// reminder time is still ahead (pure, request id → (item, fire date)).
    static func plan(_ list: [MeetingItem], now: Date) -> [String: (MeetingItem, Date)] {
        var out: [String: (MeetingItem, Date)] = [:]
        for m in list where m.isOnline && m.joinURL?.isEmpty == false {
            guard let start = CalendarFormat.date(m.start) else { continue }
            let fire = start.addingTimeInterval(-MeetingNotifyInfo.leadTime)
            guard fire > now else { continue }
            out[MeetingNotifyInfo.requestID(meetingID: m.id)] = (m, fire)
        }
        return out
    }

    private func sync(_ list: [MeetingItem], now: Date) {
        let plan = Self.plan(list, now: now)
        let center = UNUserNotificationCenter.current()
        let stale = scheduled.subtracting(plan.keys)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: Array(stale)) }
        for (id, entry) in plan {
            let content = MeetingNotifyInfo.makeContent(subject: entry.0.subject, meetingID: entry.0.id)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: entry.1.timeIntervalSince(now), repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        scheduled = Set(plan.keys)
    }
}
