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
    /// SharePoint values (APPHOST-B3): tenant or team site, OneDrive.
    public var teamSiteUrl = ""
    public var teamSiteDomain = ""
    public var teamSitePath = ""
    public var mySiteDomain = ""
    public var mySitePath = ""
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

    /// Placeholders filled from SharePoint (the host looks them up).
    static let siteKeys: Set<String> = ["teamsiteurl", "teamsitedomain", "teamsitepath", "mysitedomain", "mysitepath"]

    /// Fills the documented tab placeholders (`{locale}`, `{tid}`,
    /// `{entityId}`, `{userObjectId}`, `{upn}`, `{theme}`, `{teamName}`,
    /// `{teamSiteDomain}`…) in one forward pass. Values are
    /// percent-encoded, except site values before the query (they are
    /// the URL's host/path); unknown placeholders become "". A `{` with
    /// no closing `}` is kept verbatim. `encode: false` = raw values
    /// (manifest domains and resources).
    public static func expand(_ template: String, _ c: TeamsJSAppContext, encode: Bool = true) -> String {
        let values: [String: String] = [
            "locale": c.locale, "theme": c.theme, "tid": c.tenantId, "entityid": c.entityId,
            "subentityid": c.subEntityId, "sessionid": c.sessionId, "appsessionid": c.appSessionId,
            "hostclienttype": c.hostClientType, "ringid": "general", "userprincipalname": c.userPrincipalName,
            "loginhint": c.userPrincipalName, "upn": c.userPrincipalName, "userobjectid": c.userObjectId,
            "groupid": c.groupId ?? "", "channelid": c.channelId ?? "", "teamid": c.teamId ?? "",
            "frameContext".lowercased(): c.frameContext, "hostname": c.hostName,
            "teamname": c.teamName ?? "", "channelname": c.channelName ?? "",
            "channeltype": c.channelId == nil ? "" : "Regular",
            "teamsiteurl": c.teamSiteUrl, "teamsitedomain": c.teamSiteDomain, "teamsitepath": c.teamSitePath,
            "mysitedomain": c.mySiteDomain, "mysitepath": c.mySitePath,
        ]
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let key = rest[rest.index(after: open)..<close].lowercased()
            let v = values[key] ?? ""
            if !encode {
                out += v
            } else if siteKeys.contains(key), !out.contains("?") {
                out += v.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            } else {
                out += v.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            }
            rest = rest[rest.index(after: close)...]
        }
        return (out + rest).replacingOccurrences(of: "\u{200B}", with: "")
    }

    /// Whether a launch uses SharePoint placeholders (the host must look
    /// the site values up before loading it).
    public static func needsSite(_ l: TeamsAppLaunch) -> Bool {
        ([l.contentTemplate, l.resource ?? ""] + l.validDomains).contains { s in
            let low = s.lowercased()
            return siteKeys.contains { low.contains("{\($0)}") }
        }
    }

    /// `l` with placeholders filled in its token resource and
    /// validDomains (raw values; `https://{teamSiteDomain}` → the tenant).
    public static func resolved(_ l: TeamsAppLaunch, _ c: TeamsJSAppContext) -> TeamsAppLaunch {
        var r = l
        r.resource = l.resource.map { expand($0, c, encode: false) }
        r.validDomains = l.validDomains.map { expand($0, c, encode: false) }.filter { !$0.isEmpty }
        return r
    }

    /// Host of a site URL, and its path (no trailing slash):
    /// `https://contoso.sharepoint.com/sites/X/` → (`contoso…`, `/sites/X`).
    public static func siteParts(_ url: String?) -> (domain: String, path: String) {
        guard let url, let u = URL(string: url), let h = u.host else { return ("", "") }
        var path = u.path
        while path.hasSuffix("/") { path.removeLast() }
        return (h.lowercased(), path)
    }

    /// OneDrive `webUrl` (`…/personal/<user>/Documents`) → its site path.
    public static func mySitePath(_ url: String?) -> String {
        let path = siteParts(url).path
        let parts = path.split(separator: "/")
        guard let i = parts.firstIndex(of: "personal"), i + 1 < parts.count else { return path }
        return "/" + parts[...(i + 1)].joined(separator: "/")
    }

    // MARK: consent (APPHOST-B3)

    /// The Teams client that getAuthToken mints for (its consent is what
    /// AADSTS65001 asks for) and its registered native redirect.
    public static let teamsClientID = "1fec8e78-bce4-4aaf-ab1b-5451cc387264"
    public static let nativeRedirect = "https://login.microsoftonline.com/common/oauth2/nativeclient"

    /// A getAuthToken failure that a user consent can fix.
    public static func needsConsent(_ why: String) -> Bool {
        why.contains("AADSTS65001") || why.localizedCaseInsensitiveContains("consent_required")
    }

    /// The Microsoft consent page for the Teams client to call `resource`
    /// (the user accepts there; the redirect back ends the sheet).
    public static func consentURL(resource: String, tenant: String, loginHint: String) -> URL? {
        var r = resource.trimmingCharacters(in: .whitespaces)
        while r.hasSuffix("/") { r.removeLast() }
        guard !r.isEmpty else { return nil }
        var c = URLComponents(string: "https://login.microsoftonline.com/")
        c?.path = "/\(tenant.isEmpty ? "organizations" : tenant)/oauth2/v2.0/authorize"
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: teamsClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: nativeRedirect),
            URLQueryItem(name: "scope", value: r.contains("/.default") ? r : r + "/.default"),
            URLQueryItem(name: "prompt", value: "consent"),
        ] + (loginHint.isEmpty ? [] : [URLQueryItem(name: "login_hint", value: loginHint)])
        return c?.url
    }

    /// Federated sign-in host from the tenant's own realm discovery
    /// (`userrealm` `AuthURL`), else nil (managed tenant).
    public static func federatedHost(realmJSON data: Data) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (o["NameSpaceType"] as? String)?.caseInsensitiveCompare("Federated") == .orderedSame,
              let auth = o["AuthURL"] as? String, let u = URL(string: auth), u.scheme?.lowercased() == "https",
              let h = u.host?.lowercased(), !h.isEmpty else { return nil }
        return h
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
    public static func allowsNavigation(_ url: URL, launch: TeamsAppLaunch, signInHosts: [String] = []) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) { return true }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return false }
        if FramePolicy.hostMatches(host, authHosts) { return true }
        // The tenant's own federated sign-in host (exact, https only).
        if scheme == "https", signInHosts.contains(host) { return true }
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

    // MARK: native host failure signals (APPHOST-B3)

    /// `app.notifyFailure` / `notifyExpectedFailure` reasons that mean the
    /// app cannot run here. Throttling and Offline pass (retry later).
    public static func isFailure(_ fn: String, reason: String) -> Bool {
        if fn == "appInitialization.expectedFailure" { return !["Throttling", "Offline"].contains(reason) }
        return fn == "appInitialization.failure"
    }

    /// A main-frame URL that carries a Microsoft sign-in error (an
    /// `AADSTS` code, e.g. a redirect back with `error_description`):
    /// the short reason, else nil. Never includes the URL.
    public static func signInFailure(_ url: URL) -> String? {
        let raw = (url.query ?? "") + "#" + (url.fragment ?? "")
        let text = raw.removingPercentEncoding ?? raw
        guard let r = text.range(of: "AADSTS") else { return nil }
        let code = text[r.upperBound...].prefix { $0.isNumber }
        return code.isEmpty ? "sign-in error" : "sign-in error AADSTS\(code)"
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
