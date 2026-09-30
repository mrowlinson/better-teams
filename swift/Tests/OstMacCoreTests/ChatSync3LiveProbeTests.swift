// ChatSync3LiveProbeTests.swift — opt-in live proof for CHATSYNC3 R1.
//
// CHATSYNC3_LIVE=1: read-only GETs. The owner's user properties (the
// Teams client's own `GET {chatService}/v1/users/ME/properties`, where
// Teams keeps "userPersonalSettings") and one chat-list page. Prints
// shapes only: key names, value types, the meeting-chat notification
// enum values and mute counts. Never tokens, names, ids, URLs or text.
import COstMac
import Foundation
import XCTest
@testable import OstMacCore

final class ChatSync3LiveProbeTests: XCTestCase {
    func testLiveMeetingChatNotificationSettingShape() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CHATSYNC3_LIVE"] == "1" else {
            throw XCTSkip("set CHATSYNC3_LIVE=1 to run the read-only probe")
        }
        let ctx = try CoreReads.production()
        let profile = TomlConfig.normalize(CoreLocal.activeProfileID())
        let slots = ctx.store.load(profile: profile)
        guard let sk = slots.skypeToken, !sk.isExpired(now: ctx.now()) else {
            print("CHATSYNC3 BLOCKED stored skype token missing or stale; not refreshing from a probe")
            throw XCTSkip("stale tokens")
        }
        let svc = CoreReads.chatServiceURL(slots)
        guard let d = try? CoreReads.chatGET("\(svc)/v1/users/ME/properties", code: "probe",
                                             skype: sk.token, http: ctx.http),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            print("CHATSYNC3 FAIL properties GET"); return
        }
        func kind(_ v: Any?) -> String {
            switch v {
            case nil: "nil"
            case is String: "string"
            case let n as NSNumber: CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool" : "number"
            case is [String: Any]: "object"
            case is [Any]: "array"
            default: "other"
            }
        }
        print("CHATSYNC3 propKeys=\(obj.count) hasUPS=\(obj["userPersonalSettings"] != nil) upsType=\(kind(obj["userPersonalSettings"]))")
        var ups: [String: Any]?
        if let s = obj["userPersonalSettings"] as? String, let sd = s.data(using: .utf8) {
            ups = (try? JSONSerialization.jsonObject(with: sd)) as? [String: Any]
        } else {
            ups = obj["userPersonalSettings"] as? [String: Any]
        }
        print("CHATSYNC3 upsKeys \((ups?.keys.sorted() ?? []).joined(separator: ","))")
        let chat = ups?["chatSettings"] as? [String: Any]
        print("CHATSYNC3 chatSettingsType=\(kind(ups?["chatSettings"])) keys=\(chat?.count ?? 0)")
        for (k, v) in (chat ?? [:]).sorted(by: { $0.key < $1.key }) where k.lowercased().contains("meeting") {
            let shown: String = (v as? String) ?? ((v as? NSNumber).map { "\($0)" } ?? "<\(kind(v))>")
            print("CHATSYNC3 chatSetting \(k) [\(kind(v))] = \(shown)")
        }
        let parsed = MeetingChatSettingsReader.parse(status: 200, data: d)
        print("CHATSYNC3 parsed \(parsed.map { "\($0)" } ?? "nil")")
        // The app's own list read: the settings read happens inside it.
        var listCtx = ctx
        listCtx.meetingChatSettings = MeetingChatSettingsCache()
        let r = try CoreReads.chats(limit: 100, profile: profile, ctx: listCtx)
        let meetings = r.chats.filter { ChatMuteRule.isMeetingChat($0.id) }
        print("CHATSYNC3 list chats=\(r.chats.count) meeting=\(meetings.count) muted=\(meetings.filter { $0.muted == true }.count) "
              + "unmuted=\(meetings.filter { $0.muted == false }.count) settingsReadInList=\(listCtx.meetingChatSettings.known(profile: profile) != nil) "
              + "equalsProbe=\(listCtx.meetingChatSettings.known(profile: profile) == parsed)")
    }
}
