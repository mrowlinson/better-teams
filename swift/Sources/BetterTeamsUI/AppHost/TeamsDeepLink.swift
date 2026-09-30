// TeamsDeepLink.swift — Teams deep links (`https://teams.microsoft.com/l/…`)
// opened by hosted apps (openLink / executeDeepLink / navigateToApp),
// parsed into native targets (APPHOST-B2). Pure parsing here; routing
// lives in `DeepLinkRouter`. A link with no native view is refused with an
// error by `TeamsLinkRouter` (LINKGUARD), never sent to the browser.
import AppKit
import Foundation
import OstMacCore

public enum TeamsDeepLink: Equatable, Sendable {
    /// `/l/entity/<appId>/<entityId>?context={"subEntityId","channelId"}`,
    /// `/l/app/<appId>`.
    case entity(appID: String, entityID: String?, subEntityID: String?, channelID: String?)
    /// `/l/chat/<chatId>/conversations` or `/l/chat/0/0?users=a,b`.
    case chat(chatID: String?, users: [String])
    /// `/l/message/<threadId>/<messageId>?parentMessageId=`.
    case message(threadID: String, messageID: String, parentMessageID: String?)
    /// `/l/meetup-join/…`: the whole link is the join URL.
    case meetupJoin(URL)
    /// `/l/team/<threadId>/conversations?groupId=`.
    case team(threadID: String, groupID: String?)
    /// `/l/channel/<threadId>/<name>?groupId=`.
    case channel(threadID: String, name: String, groupID: String?)
    /// `/l/profile/<userId>` (also `/l/user/<userId>`): a person's card.
    case profile(userID: String)
    /// `/l/file/<id>?objectUrl=<SharePoint/OneDrive url>`: the file.
    case file(URL)

    static let hosts = ["teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com"]

    /// Nil when `url` is not a Teams `/l/…` link (hash routes included:
    /// `/_#/l/…`, `/v2/#/l/…`).
    public static func parse(_ url: URL) -> TeamsDeepLink? {
        guard let scheme = url.scheme?.lowercased(), ["https", "msteams"].contains(scheme) else { return nil }
        if scheme == "https" {
            guard let h = url.host?.lowercased(), FramePolicy.hostMatches(h, hosts) else { return nil }
        }
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = c?.percentEncodedPath ?? url.path
        if !path.hasPrefix("/l/"), let frag = c?.percentEncodedFragment, frag.hasPrefix("/l/") {
            // Hash route: the fragment carries path + query.
            let parts = frag.split(separator: "?", maxSplits: 1).map(String.init)
            path = parts[0]
            c?.percentEncodedQuery = parts.count > 1 ? parts[1] : nil
        }
        // Top-level meeting links: `/meet/<id>?p=…`, `/meetup-join/<thread>/0`.
        if path.hasPrefix("/meet/") || path.hasPrefix("/meetup-join/") { return .meetupJoin(url) }
        guard path.hasPrefix("/l/") else { return nil }
        let seg = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard seg.count >= 2 else { return nil }
        var q: [String: String] = [:]
        for i in c?.queryItems ?? [] { q[i.name.lowercased()] = i.value ?? "" }
        let rest = Array(seg.dropFirst(2))
        switch seg[1].lowercased() {
        case "entity", "app":
            guard let app = rest.first, !app.isEmpty else { return nil }
            let ctx = q["context"].flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let entity = rest.count > 1 && !rest[1].isEmpty ? rest[1] : nil
            return .entity(appID: app, entityID: entity, subEntityID: ctx?["subEntityId"] as? String,
                           channelID: ctx?["channelId"] as? String)
        case "chat":
            let users = (q["users"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let id = rest.first.flatMap { $0 == "0" || $0.isEmpty ? nil : $0 }
            guard id != nil || !users.isEmpty else { return nil }
            return .chat(chatID: id, users: users)
        case "message":
            guard rest.count >= 2 else { return nil }
            let parent = q["parentmessageid"].flatMap { $0.isEmpty || $0 == rest[1] ? nil : $0 }
            return .message(threadID: rest[0], messageID: rest[1], parentMessageID: parent)
        case "meetup-join", "meet":
            return .meetupJoin(url)
        case "team":
            guard let t = rest.first, !t.isEmpty else { return nil }
            return .team(threadID: t, groupID: q["groupid"])
        case "channel":
            guard let t = rest.first, !t.isEmpty else { return nil }
            return .channel(threadID: t, name: rest.count > 1 ? rest[1] : "", groupID: q["groupid"])
        case "profile", "user":
            guard let u = rest.first, !u.isEmpty, u != "0" else { return nil }
            return .profile(userID: u)
        case "file":
            guard let raw = q["objecturl"], let object = URL(string: raw),
                  TeamsLinkRouter.family(object) == .files else { return nil }
            return .file(object)
        default:
            return nil
        }
    }
}

extension TeamsDeepLink {
    /// The tab a channel link names (`tab::<id>` path segment), else nil.
    static func tabRef(_ name: String) -> String? {
        guard name.lowercased().hasPrefix("tab::") else { return nil }
        let ref = String(name.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        return ref.isEmpty ? nil : ref
    }
}

/// Routes a parsed deep link to a native screen of one window.
@MainActor
enum DeepLinkRouter {
    /// True when handled natively; false → no native view (the caller
    /// refuses it: `TeamsLinkRouter`), never the browser.
    @discardableResult
    static func route(_ url: URL, _ m: WindowModel) -> Bool {
        guard let link = TeamsDeepLink.parse(url) else { return false }
        switch link {
        case .entity(let appID, _, _, let channelID):
            let lib = m.frameHost.library
            // A channel's tab of this app: open that tab in its channel.
            if let channelID, let team = teamID(containing: channelID, m),
               let tab = (m.provider(.teams) as? TeamsSection)?.tabs(channelID, m)
                   .first(where: { $0.appID?.caseInsensitiveCompare(appID) == .orderedSame }) {
                m.navigator?.select(section: .teams)
                m.navigator?.select(TeamsSelection(teamID: team, channelID: channelID, tab: .web(tab.id)).selection,
                                    in: .teams)
                return true
            }
            if let hosted = lib.hostedApp(forCatalogApp: appID) {
                AppActions.open(LibraryItem(hosted), m)
                return true
            }
            if let item = lib.item(AppsLibrary.appID(forCatalogApp: appID)) ?? lib.item(appID) {
                AppActions.open(item, m)
                return true
            }
            if lib.store.manifest(appID) != nil {
                m.navigator?.select(section: .apps)
                m.navigator?.select(AppStoreRoute.detail(appID), in: .apps)
                return true
            }
            return false
        case .profile(let userID):
            ContactActions.openCard(ContactRef(name: "", userID: userID), m)
            return true
        case .file(let object):
            return TeamsLinkFiles.open(object, m)
        case .chat(nil, let users) where users.count == 1:
            // A 1:1 chat by address: the person's card (Message from there).
            ContactActions.openCard(ContactRef(name: users[0], email: users[0].contains("@") ? users[0] : nil), m)
            return true
        case .chat(let chatID, _):
            guard let chatID else { return false }
            m.navigator?.select(section: .chat)
            m.navigator?.select(SectionSelection(id: chatID), in: .chat)
            return true
        case .message(let thread, let message, let parent):
            if let team = teamID(containing: thread, m) {
                m.navigator?.select(section: .teams)
                m.navigator?.select(TeamsSelection(teamID: team, channelID: thread,
                                                   threadID: parent ?? message).selection, in: .teams)
            } else {
                m.navigator?.select(section: .chat)
                m.navigator?.select(SectionSelection([thread, message]), in: .chat)
            }
            return true
        case .meetupJoin(let join):
            if let running = m.call, !running.ended {
                running.show()
                return true
            }
            return m.beginCall(.meeting(id: join.absoluteString, subject: "Meeting")) != nil
        case .team(let thread, let group):
            guard let team = teamID(matching: [thread, group].compactMap { $0 }, m) ?? teamID(containing: thread, m)
            else { return false }
            m.navigator?.select(section: .teams)
            m.navigator?.select(TeamsSelection(teamID: team).selection, in: .teams)
            return true
        case .channel(let thread, let name, _):
            guard let team = teamID(containing: thread, m) else { return false }
            m.navigator?.select(section: .teams)
            // `/l/channel/<thread>/tab::<tab id or entity id>`: that tab
            // when the channel's tabs are known, else the channel.
            var sel = TeamsSelection(teamID: team, channelID: thread)
            if let ref = TeamsDeepLink.tabRef(name),
               let tab = (m.provider(.teams) as? TeamsSection)?.tabs(thread, m).first(where: {
                   $0.id.caseInsensitiveCompare(ref) == .orderedSame
                       || $0.entityID?.caseInsensitiveCompare(ref) == .orderedSame
               }) {
                sel = TeamsSelection(teamID: team, channelID: thread, tab: .web(tab.id))
            }
            m.navigator?.select(sel.selection, in: .teams)
            return true
        }
    }

    private static func teamID(containing channelID: String, _ m: WindowModel) -> String? {
        m.app?.teams.teams.first { t in t.channels.contains { $0.id == channelID } }?.teamId
    }

    private static func teamID(matching ids: [String], _ m: WindowModel) -> String? {
        m.app?.teams.teams.first { t in ids.contains { $0.caseInsensitiveCompare(t.teamId) == .orderedSame } }?.teamId
    }
}
