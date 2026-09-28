// TeamsJSPolicy.swift — pure rules of the native TeamsJS host (APPHOST
// phase 1): app context, manifest URL placeholders, the validDomains
// navigation allowlist, which resource getAuthToken may mint for, and
// the Teams theme name. Unit-tested; no WebKit, no I/O.
import AppKit
import Foundation

public enum TeamsJSTransport: String, Sendable, Codable {
    /// The app page is the top document; a document-start shim defines
    /// `window.nativeInterface.framelessPostMessage` (TeamsJS picks it
    /// when it has no parent/opener).
    case frameless
    /// A host page at the https://teams.microsoft.com origin embeds the
    /// app and relays postMessage (for apps that insist on a parent).
    case iframe
}

/// What the host tells the app about itself and the user (legacy
/// `getContext` shape; TeamsJS v2 maps it to `app.Context`).
public struct TeamsJSAppContext: Sendable, Equatable {
    public var appId = ""
    public var entityId = ""
    public var subEntityId = ""
    public var frameContext = "content"
    public var hostClientType = "desktop"
    public var hostName = "Teams"
    public var locale = "en-us"
    public var theme = "default"
    public var tenantId = ""
    public var userObjectId = ""
    public var userPrincipalName = ""
    public var userDisplayName = ""
    public var teamId: String?
    public var channelId: String?
    public var groupId: String?
    public var teamName: String?
    public var channelName: String?
    public var sessionId = UUID().uuidString.lowercased()
    public var appSessionId = UUID().uuidString.lowercased()
    public init() {}
}

public enum TeamsJSPolicy {
    // MARK: context values

    /// Teams theme name for an appearance: `default` / `dark` / `contrast`.
    public static func theme(dark: Bool, increaseContrast: Bool) -> String {
        increaseContrast ? "contrast" : (dark ? "dark" : "default")
    }

    @MainActor
    public static func theme(for appearance: NSAppearance) -> String {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return theme(dark: dark, increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    /// BCP-47, lowercased as Teams sends it (`en-us`, `de-de`).
    public static func locale(_ l: Locale = .current) -> String {
        let lang = l.language.languageCode?.identifier ?? "en"
        guard let region = l.region?.identifier else { return lang.lowercased() }
        return "\(lang)-\(region)".lowercased()
    }

    // MARK: manifest URL placeholders

    /// Fills the documented tab placeholders (`{locale}`, `{tid}`,
    /// `{entityId}`, `{userObjectId}`, `{upn}`, `{theme}`…) in one
    /// forward pass. Values are percent-encoded; unknown placeholders
    /// become "". A `{` with no closing `}` is kept verbatim.
    public static func expand(_ template: String, _ c: TeamsJSAppContext) -> String {
        let values: [String: String] = [
            "locale": c.locale, "theme": c.theme, "tid": c.tenantId, "entityid": c.entityId,
            "subentityid": c.subEntityId, "sessionid": c.sessionId, "appsessionid": c.appSessionId,
            "hostclienttype": c.hostClientType, "ringid": "general", "userprincipalname": c.userPrincipalName,
            "loginhint": c.userPrincipalName, "upn": c.userPrincipalName, "userobjectid": c.userObjectId,
            "groupid": c.groupId ?? "", "channelid": c.channelId ?? "", "teamid": c.teamId ?? "",
            "frameContext".lowercased(): c.frameContext, "hostname": c.hostName,
        ]
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let key = rest[rest.index(after: open)..<close].lowercased()
            let v = values[key] ?? ""
            out += v.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // MARK: navigation allowlist

    /// Microsoft sign-in hosts: apps with their own OIDC login (Forms)
    /// must be able to round-trip through them in the frame.
    static let authHosts = ["login.microsoftonline.com", "login.microsoft.com", "login.live.com",
                            "login.windows.net"]

    /// Manifest `validDomains` entry match: `contoso.com`,
    /// `*.contoso.com` (subdomains only), optional scheme/port/path.
    public static func domainMatches(host: String, pattern raw: String) -> Bool {
        var p = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = p.range(of: "://") { p = String(p[r.upperBound...]) }
        if let slash = p.firstIndex(of: "/") { p = String(p[..<slash]) }
        if let colon = p.firstIndex(of: ":") { p = String(p[..<colon]) }
        let h = host.lowercased()
        guard !p.isEmpty else { return false }
        if p.hasPrefix("*.") {
            let base = String(p.dropFirst(2))
            return !base.isEmpty && h.hasSuffix("." + base)
        }
        return h == p
    }

    /// Main-frame navigation stays in the app frame only for the app's
    /// own content host, its manifest validDomains, Microsoft sign-in,
    /// and (iframe transport) the host page origin. Everything else
    /// opens in the default browser.
    public static func allowsNavigation(_ url: URL, launch: TeamsAppLaunch) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) { return true }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return false }
        if FramePolicy.hostMatches(host, authHosts) { return true }
        if launch.transport == .iframe, host == "teams.microsoft.com" { return true }
        if let content = contentHost(launch), host == content { return true }
        return launch.validDomains.contains { domainMatches(host: host, pattern: $0) }
    }

    /// The content page's host (placeholders do not affect it).
    public static func contentHost(_ launch: TeamsAppLaunch) -> String? {
        URL(string: expand(launch.contentTemplate, TeamsJSAppContext()))?.host?.lowercased()
    }

    /// Whether a page origin (`https://host[:port]`) belongs to the app
    /// (NAA tokens are only brokered for the app's own pages).
    public static func isAppOrigin(_ origin: URL, launch: TeamsAppLaunch) -> Bool {
        guard origin.scheme?.lowercased() == "https", let host = origin.host?.lowercased() else { return false }
        if let content = contentHost(launch), host == content { return true }
        return launch.validDomains.contains { domainMatches(host: host, pattern: $0) }
    }

    // MARK: getAuthToken

    /// The resource `authentication.getAuthToken` mints for: the
    /// manifest's `webApplicationInfo.resource` (as Teams does), else a
    /// requested resource whose host is one of the app's validDomains
    /// (SharePoint-style apps). Nil = refuse (never mint a token for an
    /// arbitrary audience on an app's say-so).
    public static func authResource(requested: [String], launch: TeamsAppLaunch) -> String? {
        if let r = launch.resource?.trimmingCharacters(in: .whitespaces), !r.isEmpty { return r }
        for raw in requested {
            guard let u = URL(string: raw), u.scheme?.lowercased() == "https", let h = u.host else { continue }
            if launch.validDomains.contains(where: { domainMatches(host: h, pattern: $0) }) { return raw }
        }
        return nil
    }
}
