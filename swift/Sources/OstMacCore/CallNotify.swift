// CallNotify.swift — gap-g3: incoming-call system notification + ring.
//
// G3 wires the CallCenter phase machine to the OS so a call is never
// missed while the app is minimized or behind other windows:
// - OmCallInfo: the OM_CALL category (Accept/Decline actions) that both
//   banner backends register (Notifier.setup + SystemNotificationCenter,
//   which rewrites the category set on every message post — the call
//   category must ride along or message traffic wipes it).
// - CallRinger: NSSound loop, started/stopped by CallStore.syncRing as
//   the phase machine enters/leaves an incoming ring. Native API only;
//   the looped system sound is the ring (macOS ships no ringtone file).
//   The banner itself posts SILENT — the ringer owns all call audio so
//   the two never double-play.
// - CallStore owns the phase→bell glue (ringer + onIncomingRing /
//   onRingEnded hooks); the app assigns the hooks to Notifier posts.
//   Nil ringer = silent (headless/tests never make noise).
// gap-g4: CallKit provider API does not exist on macOS (see
// CallKitSupport.swift), so this G3 path is the PERMANENT macOS
// route, not a fallback. G4 hardened it in place: the banner content
// is built by OmCallInfo.makeContent (interruption .active = Focus/
// DND suppress by OS policy) and the ringer consults the system
// output-mute probe before starting.
import AppKit
import Foundation
import UserNotifications

/// Notification category/action/userInfo for incoming-call banners.
/// userInfo carries the call id so Accept/Decline route to the call.
public enum OmCallInfo {
    public static let categoryID = "OM_CALL"
    public static let acceptActionID = "OM_CALL_ACCEPT"
    public static let declineActionID = "OM_CALL_DECLINE"
    public static let acceptTitle = "Accept"
    public static let declineTitle = "Decline"
    public static let callIDKey = "OMCallID"

    /// Stable request id per call: re-posts replace, withdraw removes.
    public static func requestID(callID: String) -> String {
        "call-\(callID)"
    }

    public static func userInfo(callID: String) -> [String: String] {
        [callIDKey: callID]
    }

    /// gap-g4: sole builder for the call banner content
    /// (Notifier.postCall posts through here). SILENT — the CallRinger loop owns
    /// all call audio so banner + ring never double-play.
    /// interruptionLevel is .active ON PURPOSE: Focus/DND suppress
    /// the banner by OS policy (no app-side quiet check, no bypass).
    /// Pure — fully unit-testable without UNCenter.
    public static func makeContent(
        title: String, body: String, callID: String
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? "(incoming call)" : body
        content.sound = nil
        content.interruptionLevel = .active
        content.categoryIdentifier = categoryID
        content.userInfo = userInfo(callID: callID)
        content.threadIdentifier = callID
        return content
    }

    /// Shared category (both backends register this same shape).
    /// Accept foregrounds the app onto the call; Decline stays put.
    public static var category: UNNotificationCategory {
        let accept = UNNotificationAction(
            identifier: acceptActionID, title: acceptTitle,
            options: [.foreground])
        let decline = UNNotificationAction(
            identifier: declineActionID, title: declineTitle,
            options: [.destructive])
        return UNNotificationCategory(
            identifier: categoryID, actions: [accept, decline],
            intentIdentifiers: [], options: [])
    }
}

/// Ring loop seam: the real NSSound loop in the app, the fake in tests.
public protocol CallRinging: AnyObject {
    var isRinging: Bool { get }
    func start()
    func stop()
}

/// Looped system-sound ring (native NSSound only). start() is idempotent
/// (a second ring for the same call never layers); stop() always silences.
/// No system sound resolves headless → silent no-op, never a crash.
/// gap-g4: start() consults mutedCheck first — a ring into a muted
/// output never starts (the banner still posts; silence must not eat
/// the visual call too). Nil check = ring unconditionally (legacy).
public final class CallRinger: CallRinging {
    /// Preferred ring sounds, first resolvable wins.
    public static let soundNames = ["Glass", "Ping", "Tink"]

    /// System-mute probe (the app installs SystemAudioMute's;
    /// tests inject a stub). Consulted on every start().
    public var mutedCheck: (() -> Bool)?

    private var sound: NSSound?

    public init() {}

    public var isRinging: Bool { sound?.isPlaying == true }

    public func start() {
        if mutedCheck?() == true { return }
        if isRinging { return }
        if sound == nil {
            sound = Self.soundNames.lazy.compactMap { NSSound(named: $0) }.first
        }
        guard let sound else { return }
        sound.loops = true
        sound.play()
    }

    public func stop() {
        sound?.stop()
    }
}

/// In-memory ringer (tests): counts starts/stops, never plays audio.
public final class FakeRinger: CallRinging {
    public private(set) var starts = 0
    public private(set) var stops = 0
    public private(set) var isRinging = false

    public init() {}

    public func start() {
        starts += 1
        isRinging = true
    }

    public func stop() {
        stops += 1
        isRinging = false
    }
}
