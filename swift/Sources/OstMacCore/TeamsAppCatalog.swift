// TeamsAppCatalog.swift — the Teams app catalog (installed/pinned apps
// and their manifests) and the token broker calls a native TeamsJS host
// needs (APPHOST phase 1). Wire types mirror core `apphost.rs`
// (snake_case). Tokens only ever live in memory; never log them.
import COstMac
import Foundation

/// One static (personal) tab of an app manifest.
public struct TeamsAppStaticTab: Codable, Sendable, Equatable {
    public var entityId: String
    public var name: String
    public var contentUrl: String?
    public var websiteUrl: String?
    public var scopes: [String]

    public init(entityId: String, name: String, contentUrl: String?, websiteUrl: String? = nil,
                scopes: [String] = ["personal"]) {
        self.entityId = entityId
        self.name = name
        self.contentUrl = contentUrl
        self.websiteUrl = websiteUrl
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id", name, contentUrl = "content_url", websiteUrl = "website_url", scopes
    }
}

/// One configurable (channel / group chat) tab.
public struct TeamsAppConfigurableTab: Codable, Sendable, Equatable {
    public var configurationUrl: String
    public var canUpdateConfiguration: Bool
    public var scopes: [String]

    public init(configurationUrl: String, canUpdateConfiguration: Bool = false, scopes: [String] = ["team"]) {
        self.configurationUrl = configurationUrl
        self.canUpdateConfiguration = canUpdateConfiguration
        self.scopes = scopes
    }

    enum CodingKeys: String, CodingKey {
        case configurationUrl = "configuration_url", canUpdateConfiguration = "can_update_configuration", scopes
    }
}

/// `webApplicationInfo`: the AAD app SSO tokens are minted for.
public struct TeamsAppWebInfo: Codable, Sendable, Equatable {
    public var id: String
    public var resource: String?

    public init(id: String, resource: String?) {
        self.id = id
        self.resource = resource
    }
}

/// The hostable part of one app definition.
public struct TeamsAppManifest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var shortDescription: String?
    public var developer: String?
    public var version: String?
    public var colorIcon: String?
    public var outlineIcon: String?
    public var accentColor: String?
    public var staticTabs: [TeamsAppStaticTab]
    public var configurableTabs: [TeamsAppConfigurableTab]
    public var webApplicationInfo: TeamsAppWebInfo?
    public var validDomains: [String]
    // Store detail fields (APPHOST-B2). Optional: phase-1 caches lack them.
    public var fullDescription: String?
    public var hasBot: Bool?
    public var hasMessagingExtension: Bool?
    public var permissions: [String]?
    public var categories: [String]?
    public var websiteUrl: String?
    public var privacyUrl: String?
    public var termsOfUseUrl: String?

    public init(id: String, name: String, shortDescription: String? = nil, developer: String? = nil,
                staticTabs: [TeamsAppStaticTab], configurableTabs: [TeamsAppConfigurableTab] = [],
                webApplicationInfo: TeamsAppWebInfo? = nil, validDomains: [String] = [],
                fullDescription: String? = nil, hasBot: Bool = false, hasMessagingExtension: Bool = false,
                permissions: [String] = [], categories: [String] = [], websiteUrl: String? = nil,
                privacyUrl: String? = nil, termsOfUseUrl: String? = nil) {
        self.id = id
        self.name = name
        self.shortDescription = shortDescription
        self.developer = developer
        self.staticTabs = staticTabs
        self.configurableTabs = configurableTabs
        self.webApplicationInfo = webApplicationInfo
        self.validDomains = validDomains
        self.fullDescription = fullDescription
        self.hasBot = hasBot
        self.hasMessagingExtension = hasMessagingExtension
        self.permissions = permissions
        self.categories = categories
        self.websiteUrl = websiteUrl
        self.privacyUrl = privacyUrl
        self.termsOfUseUrl = termsOfUseUrl
    }

    enum CodingKeys: String, CodingKey {
        case id, name, shortDescription = "short_description", developer, version
        case colorIcon = "color_icon", outlineIcon = "outline_icon", accentColor = "accent_color"
        case staticTabs = "static_tabs", configurableTabs = "configurable_tabs"
        case webApplicationInfo = "web_application_info", validDomains = "valid_domains"
        case fullDescription = "full_description", hasBot = "has_bot"
        case hasMessagingExtension = "has_messaging_extension", permissions, categories
        case websiteUrl = "website_url", privacyUrl = "privacy_url", termsOfUseUrl = "terms_of_use_url"
    }

    /// Store capabilities: personal/channel tabs, bot, messaging extension.
    public var hasPersonalTab: Bool { personalTab != nil }
    public var hasConfigurableTab: Bool { !configurableTabs.isEmpty }

    /// The first personal static tab with a content page (what the app
    /// bar opens). Tabs that are only a website (no contentUrl) or
    /// Teams-native entities (`conversations`, `about`) are skipped.
    public var personalTab: TeamsAppStaticTab? {
        staticTabs.first { t in
            guard let c = t.contentUrl, !c.isEmpty else { return false }
            // Live manifests say "Personal" (APPHOST-B3); fixtures "personal".
            return (t.scopes.isEmpty || t.scopes.contains { $0.caseInsensitiveCompare("personal") == .orderedSame })
                && !["conversations", "about"].contains(t.entityId.lowercased())
        }
    }
}

/// `ostmac_app_catalog_for`: installed apps + app bar order.
public struct TeamsAppCatalogResponse: Decodable, Sendable {
    public let ok: Bool
    public let pinned: [String]
    public let apps: [TeamsAppManifest]
}

/// One store shelf (`ostmac_app_store_for`).
public struct TeamsAppStoreSection: Codable, Sendable, Equatable {
    public var title: String
    public var appIds: [String]

    public init(title: String, appIds: [String]) {
        self.title = title
        self.appIds = appIds
    }

    enum CodingKeys: String, CodingKey { case title, appIds = "app_ids" }
}

/// `ostmac_app_store_for`: store shelves + listed apps.
public struct TeamsAppStoreResponse: Decodable, Sendable {
    public let ok: Bool
    public let sections: [TeamsAppStoreSection]
    public let apps: [TeamsAppManifest]
}

/// `ostmac_app_search_for`.
public struct TeamsAppSearchResponse: Decodable, Sendable {
    public let ok: Bool
    public let apps: [TeamsAppManifest]
}

struct TeamsAppOK: Decodable, Sendable { let ok: Bool }

/// `ostmac_app_sites_for`: SharePoint URLs for tab placeholders
/// (`{teamSiteDomain}`, `{teamSitePath}`, `{mySiteDomain}`…).
public struct TeamsAppSites: Decodable, Sendable, Equatable {
    public var root: String?
    public var mySite: String?
    public var teamSite: String?

    public init(root: String? = nil, mySite: String? = nil, teamSite: String? = nil) {
        self.root = root
        self.mySite = mySite
        self.teamSite = teamSite
    }

    enum CodingKeys: String, CodingKey { case root, mySite = "my_site", teamSite = "team_site" }
}

/// `ostmac_app_identity_for`: who the host says the user is.
public struct TeamsAppIdentity: Codable, Sendable, Equatable {
    public var tenantId: String
    public var userObjectId: String
    public var upn: String
    public var name: String

    public init(tenantId: String, userObjectId: String, upn: String, name: String) {
        self.tenantId = tenantId
        self.userObjectId = userObjectId
        self.upn = upn
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case tenantId = "tenant_id", userObjectId = "user_object_id", upn, name
    }
}

/// A minted access token. `description` never shows the token.
public struct TeamsAppToken: Decodable, Sendable, CustomStringConvertible {
    public let token: String
    public let expiresIn: Int?
    public let scope: String?
    /// OIDC id token (nested app auth replies need one). Never shown.
    public let idToken: String?

    enum CodingKeys: String, CodingKey { case token, expiresIn = "expires_in", scope, idToken = "id_token" }

    public var description: String { "TeamsAppToken(<\(token.count) chars>, expiresIn: \(expiresIn ?? -1))" }
}

extension RustCore {
    /// Installed + pinned apps with manifests (blocking FFI + network:
    /// call off the main thread). Read-only.
    public static func appCatalog(profile: String?) throws -> TeamsAppCatalogResponse {
        try withProfile(profile) { try call(ostmac_app_catalog_for($0), as: TeamsAppCatalogResponse.self) }
    }

    /// Store shelves + listed apps (blocking FFI + network). Read-only.
    public static func appStore(profile: String?) throws -> TeamsAppStoreResponse {
        try withProfile(profile) { try call(ostmac_app_store_for($0), as: TeamsAppStoreResponse.self) }
    }

    /// Store search (blocking FFI + network). Read-only.
    public static func appSearch(profile: String?, query: String) throws -> TeamsAppSearchResponse {
        try withProfile(profile) { p in
            try query.withCString { try call(ostmac_app_search_for(p, $0), as: TeamsAppSearchResponse.self) }
        }
    }

    /// Manifests of a team's installed apps plus `ids` (blocking FFI +
    /// network). Read-only.
    public static func teamAppDefinitions(profile: String?, teamID: String?, ids: [String]) throws -> TeamsAppSearchResponse {
        let json = String(data: (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        return try withProfile(profile) { p in
            try (teamID ?? "").withCString { t in
                try json.withCString { try call(ostmac_team_app_definitions_for(p, t, $0), as: TeamsAppSearchResponse.self) }
            }
        }
    }

    /// SharePoint site URLs (blocking FFI + network). Read-only.
    public static func appSites(profile: String?, groupID: String?) throws -> TeamsAppSites {
        try withProfile(profile) { p in
            try (groupID ?? "").withCString { try call(ostmac_app_sites_for(p, $0), as: TeamsAppSites.self) }
        }
    }

    /// Installs an app for the user. REMOTE WRITE: callers confirm first.
    public static func appInstall(profile: String?, appID: String) throws {
        _ = try withProfile(profile) { p in
            try appID.withCString { try call(ostmac_app_install_for(p, $0), as: TeamsAppOK.self) }
        }
    }

    /// Tenant / object id / UPN from the stored token (no network).
    public static func appIdentity(profile: String?) throws -> TeamsAppIdentity {
        try withProfile(profile) { try call(ostmac_app_identity_for($0), as: TeamsAppIdentity.self) }
    }

    /// Access token for a resource or scope list (blocking FFI +
    /// network on a cache miss: call off the main thread).
    public static func tokenForScope(profile: String?, scopes: String) throws -> TeamsAppToken {
        try withProfile(profile) { p in
            try scopes.withCString { try call(ostmac_token_for_scope_for(p, $0), as: TeamsAppToken.self) }
        }
    }

    /// Nested app auth token for an app's own client id, requested by
    /// a page at `origin` (blocking FFI + network: off the main thread).
    public static func naaToken(profile: String?, clientID: String, scopes: String,
                                origin: String) throws -> TeamsAppToken {
        try withProfile(profile) { p in
            try clientID.withCString { c in
                try scopes.withCString { s in
                    try origin.withCString { o in
                        try call(ostmac_naa_token_for(p, c, s, o), as: TeamsAppToken.self)
                    }
                }
            }
        }
    }

    private static func withProfile<T>(_ profile: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        guard let profile else { return try body(nil) }
        return try profile.withCString { try body($0) }
    }
}

/// Last catalog per account (instant rail/library at launch; refreshed
/// in the background).
public enum TeamsAppCatalogCache {
    public struct Entry: Codable, Sendable, Equatable {
        public var pinned: [String]
        public var apps: [TeamsAppManifest]
        public init(pinned: [String], apps: [TeamsAppManifest]) {
            self.pinned = pinned
            self.apps = apps
        }
    }

    static func key(_ account: String) -> String { "bt.appCatalog.\(account)" }

    public static func load(account: String, defaults: UserDefaults = .standard) -> Entry? {
        guard let d = defaults.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }

    public static func save(_ e: Entry, account: String, defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(e) { defaults.set(d, forKey: key(account)) }
    }
}

/// Last store home per account (instant library; refreshed in the background).
public enum TeamsAppStoreCache {
    public struct Entry: Codable, Sendable, Equatable {
        public var sections: [TeamsAppStoreSection]
        public var apps: [TeamsAppManifest]
        public init(sections: [TeamsAppStoreSection], apps: [TeamsAppManifest]) {
            self.sections = sections
            self.apps = apps
        }
    }

    static func key(_ account: String) -> String { "bt.appStore.\(account)" }

    public static func load(account: String, defaults: UserDefaults = .standard) -> Entry? {
        guard let d = defaults.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: d)
    }

    public static func save(_ e: Entry, account: String, defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(e) { defaults.set(d, forKey: key(account)) }
    }
}

/// The UI's door to the catalog + broker FFI (views never call the FFI,
/// ui-lint R11). Network calls run off the main thread.
public enum TeamsAppService {
    public static func catalog(profile: String?) async -> Result<TeamsAppCatalogResponse, any Error> {
        await Task.blocking(priority: .utility) { Result { try RustCore.appCatalog(profile: profile) } }.value
    }

    public static func store(profile: String?) async -> Result<TeamsAppStoreResponse, any Error> {
        await Task.blocking(priority: .utility) { Result { try RustCore.appStore(profile: profile) } }.value
    }

    public static func search(profile: String?, query: String) async -> Result<[TeamsAppManifest], any Error> {
        await Task.blocking(priority: .userInitiated) {
            Result { try RustCore.appSearch(profile: profile, query: query).apps }
        }.value
    }

    /// Team-installed + channel-tab app manifests (read-only).
    public static func teamApps(profile: String?, teamID: String?, ids: [String]) async -> Result<[TeamsAppManifest], any Error> {
        await Task.blocking(priority: .utility) {
            Result { try RustCore.teamAppDefinitions(profile: profile, teamID: teamID, ids: ids).apps }
        }.value
    }

    /// SharePoint site URLs for tab placeholders (read-only).
    public static func sites(profile: String?, groupID: String?) async -> Result<TeamsAppSites, any Error> {
        await Task.blocking(priority: .userInitiated) {
            Result { try RustCore.appSites(profile: profile, groupID: groupID) }
        }.value
    }

    /// The signed-in account's joined teams, for hosted apps asking
    /// TeamsJS getUserJoinedTeams (read-only; empty on failure).
    public static func joinedTeams() async -> [TeamItem] {
        await Task.blocking(priority: .utility) { (try? RustCore.teams().teams) ?? [] }.value
    }

    /// REMOTE WRITE (tenant sees a new personal install). Confirm first.
    public static func install(profile: String?, appID: String) async -> Result<Void, any Error> {
        await Task.blocking(priority: .userInitiated) {
            Result { try RustCore.appInstall(profile: profile, appID: appID) }
        }.value
    }

    /// Local (stored token claims); nil when signed out.
    public static func identity(profile: String?) -> TeamsAppIdentity? {
        try? RustCore.appIdentity(profile: profile)
    }

    public static func token(profile: String?, scopes: String) async -> Result<TeamsAppToken, any Error> {
        await Task.blocking(priority: .userInitiated) {
            Result { try RustCore.tokenForScope(profile: profile, scopes: scopes) }
        }.value
    }

    public static func naaToken(profile: String?, clientID: String, scopes: String,
                                origin: String) async -> Result<TeamsAppToken, any Error> {
        await Task.blocking(priority: .userInitiated) {
            Result { try RustCore.naaToken(profile: profile, clientID: clientID, scopes: scopes, origin: origin) }
        }.value
    }
}
