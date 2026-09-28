// TokenRefresh.swift — R13 token-store lane: Swift refresh flow.
//
// Port of `ost::auth::oauth::refresh_for` + `exchange_skype_token` (work
// path only; personal stays unimplemented in both — documented gap, not a
// regression). Same client_id/tenant/scopes/endpoints, same rotation and
// best-effort derived fan-out rules. The fetcher is injected so tests never
// touch the network. Auth-critical: never log token values.
import Foundation

// MARK: - Endpoint table (single source; test pins the Rust literals)

/// All auth URLs/scopes in one table. Values must equal the Rust literals
/// (`AuthConfig::work`, `build_client`, `acquire_*`, `AUTHZ_URL_WORK`) —
/// pinned by `TokenRefreshTests.testEndpointsMatchRust`.
public enum AuthEndpoints {
    public static let clientID = "1fec8e78-bce4-4aaf-ab1b-5451cc387264"
    public static let tenant = "common"
    public static let tokenURL =
        "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    public static let deviceCodeURL =
        "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode"
    public static let authorizeURL =
        "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    public static let authzWorkURL =
        "https://teams.microsoft.com/api/authsvc/v1.0/authz"
    public static let scopeAAD = "https://api.spaces.skype.com/.default"
    public static let scopeGraph = "https://graph.microsoft.com/.default"
    public static let scopeIC3 = "https://ic3.teams.office.com/.default"
    public static let scopeRecorder =
        "4580fd1d-e5a3-4f56-9ad1-aab0e3bf8f76/.default"

    /// RT-grant scope param: `<aud>/.default` + `offline_access` (matches
    /// the oauth2 `add_scope` pair in Rust).
    public static func grantScope(_ audience: String) -> String {
        "\(audience) offline_access"
    }
}

// MARK: - Fetcher seam

public struct TokenHTTPResponse: Sendable {
    public let status: Int
    public let data: Data

    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }
}

public protocol TokenRefreshFetcher: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws
        -> TokenHTTPResponse
}

public enum TokenRefreshError: Error, Sendable, Equatable {
    case network(String)
    case tokenRejected(String)
    case persist(String)
}

/// URLSession-backed fetcher for production use.
public struct URLSessionTokenFetcher: TokenRefreshFetcher {
    public init() {}

    public func post(url: URL, headers: [String: String], body: Data) async throws
        -> TokenHTTPResponse
    {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return TokenHTTPResponse(status: status, data: data)
        } catch {
            throw TokenRefreshError.network(String(describing: error))
        }
    }
}

// MARK: - Refresh flow (mirrors `oauth::refresh_for`)

public enum TokenRefresh {
    /// Refresh one profile. Returns false (zero network calls) when no
    /// refresh token is stored. Throws when the AAD grant fails or the
    /// write-through save fails; derived (skype/graph/ic3/recorder)
    /// failures are best-effort (kept going, never fail the refresh).
    public static func refresh(
        profile: String,
        store: any TokenStore,
        fetcher: any TokenRefreshFetcher,
        now: @Sendable @escaping () -> UInt64 = { TokenStatus.nowSecs() }
    ) async throws -> Bool {
        let name = TomlConfig.normalize(profile)
        var slots = store.load(profile: name)
        guard let rt = slots.refreshToken, !rt.isEmpty else { return false }

        // 1. AAD grant (rotation persisted). Failure is loud.
        let aad = try await grant(
            audience: AuthEndpoints.scopeAAD, refreshToken: rt, fetcher: fetcher
        )
        slots.accessToken = StoredTokenValue(
            token: aad.accessToken, now: now(), expiresIn: aad.expiresIn
        )
        if let rotated = aad.refreshToken {
            slots.refreshToken = rotated
        }
        let liveRT = slots.refreshToken ?? ""

        // 2. Skype exchange via authsvc (best-effort).
        if let skype = try? await exchangeSkype(
            aadToken: aad.accessToken, fetcher: fetcher
        ) {
            slots.skypeToken = StoredTokenValue(
                token: skype.token, now: now(), expiresIn: skype.expiresIn
            )
            if let gtms = skype.regionGtms {
                slots.regionGtms = gtms
            }
        }

        // 3. Derived fan-out (each best-effort, never fails the refresh).
        if !liveRT.isEmpty {
            if let g = try? await grant(
                audience: AuthEndpoints.scopeGraph, refreshToken: liveRT,
                fetcher: fetcher
            ) {
                slots.graphToken = StoredTokenValue(
                    token: g.accessToken, now: now(), expiresIn: g.expiresIn
                )
            }
            if let ic3 = try? await grant(
                audience: AuthEndpoints.scopeIC3, refreshToken: liveRT,
                fetcher: fetcher
            ) {
                slots.ic3Token = StoredTokenValue(
                    token: ic3.accessToken, now: now(), expiresIn: ic3.expiresIn
                )
            }
            if let rec = try? await grant(
                audience: AuthEndpoints.scopeRecorder, refreshToken: liveRT,
                fetcher: fetcher
            ) {
                slots.recorderToken = StoredTokenValue(
                    token: rec.accessToken, now: now(), expiresIn: rec.expiresIn
                )
            }
        }

        // 4. Write-through is part of success (STAY-36 ride the TOML).
        do {
            try store.save(slots, profile: name)
        } catch {
            throw TokenRefreshError.persist(String(describing: error))
        }
        return true
    }

    /// Login-path backfill rule (matches `oauth::login` lines 210-221):
    /// valid AAD + missing ic3/recorder + RT present → refresh to acquire
    /// the missing derived tokens.
    public static func loginNeedsRefresh(_ slots: TokenSlots, now: UInt64) -> Bool {
        guard let aad = slots.accessToken, !aad.isExpired(now: now) else {
            return false
        }
        guard slots.refreshToken != nil else { return false }
        return slots.recorderToken == nil || slots.ic3Token == nil
    }

    // MARK: - Grants

    struct Grant: Sendable {
        let accessToken: String
        let expiresIn: UInt64?
        let refreshToken: String?
    }

    struct SkypeExchange: Sendable {
        let token: String
        let expiresIn: UInt64?
        let regionGtms: String?
    }

    static func grant(
        audience: String,
        refreshToken: String,
        fetcher: any TokenRefreshFetcher
    ) async throws -> Grant {
        guard let url = URL(string: AuthEndpoints.tokenURL) else {
            throw TokenRefreshError.network("bad token URL")
        }
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: AuthEndpoints.clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(
                name: "scope", value: AuthEndpoints.grantScope(audience)
            ),
        ]
        let body = Data((comps.percentEncodedQuery ?? "").utf8)
        let resp: TokenHTTPResponse
        do {
            resp = try await fetcher.post(
                url: url,
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                ],
                body: body
            )
        } catch let e as TokenRefreshError {
            throw e
        } catch {
            throw TokenRefreshError.network(String(describing: error))
        }
        guard (200 ... 299).contains(resp.status) else {
            throw TokenRefreshError.tokenRejected(
                "token grant HTTP \(resp.status)"
            )
        }
        return try parseGrant(resp.data)
    }

    static func parseGrant(_ data: Data) throws -> Grant {
        guard let obj = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
            let access = obj["access_token"] as? String, !access.isEmpty
        else {
            throw TokenRefreshError.tokenRejected("grant missing access_token")
        }
        var expires: UInt64?
        if let n = obj["expires_in"] as? Int, n >= 0 {
            expires = UInt64(n)
        } else if let n = obj["expires_in"] as? UInt64 {
            expires = n
        } else if let s = obj["expires_in"] as? String, let n = UInt64(s) {
            expires = n
        }
        let rotated = (obj["refresh_token"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        return Grant(
            accessToken: access, expiresIn: expires, refreshToken: rotated
        )
    }

    /// Work-path Skype exchange (matches `exchange_skype_token(work)`:
    /// Bearer [REDACTED] AAD, Content-Length 0, `tokens.skypeToken` required,
    /// `regionGtms` optional).
    static func exchangeSkype(
        aadToken: String, fetcher: any TokenRefreshFetcher
    ) async throws -> SkypeExchange {
        guard let url = URL(string: AuthEndpoints.authzWorkURL) else {
            throw TokenRefreshError.network("bad authz URL")
        }
        let resp: TokenHTTPResponse
        do {
            resp = try await fetcher.post(
                url: url,
                headers: [
                    "Authorization": "Bearer \(aadToken)",
                    "Content-Length": "0",
                ],
                body: Data()
            )
        } catch let e as TokenRefreshError {
            throw e
        } catch {
            throw TokenRefreshError.network(String(describing: error))
        }
        guard (200 ... 299).contains(resp.status) else {
            throw TokenRefreshError.tokenRejected(
                "authsvc HTTP \(resp.status)"
            )
        }
        guard let obj = try? JSONSerialization.jsonObject(with: resp.data)
            as? [String: Any],
            let tokens = obj["tokens"] as? [String: Any],
            let skype = tokens["skypeToken"] as? String, !skype.isEmpty
        else {
            throw TokenRefreshError.tokenRejected(
                "authsvc response missing skypeToken"
            )
        }
        var expires: UInt64?
        if let n = tokens["expiresIn"] as? Int, n >= 0 {
            expires = UInt64(n)
        } else if let n = tokens["expiresIn"] as? UInt64 {
            expires = n
        }
        var gtms: String?
        if let g = obj["regionGtms"], !(g is NSNull),
           let gdata = try? JSONSerialization.data(
               withJSONObject: g, options: [.sortedKeys]
           ),
           let gstr = String(data: gdata, encoding: .utf8)
        {
            // serde_json parity: it never emits `\/` for slashes.
            gtms = gstr.replacingOccurrences(of: "\\/", with: "/")
        }
        return SkypeExchange(
            token: skype, expiresIn: expires, regionGtms: gtms
        )
    }
}

// MARK: - Singleflight (one in-flight refresh per profile)

/// Coalesces overlapping refreshes for the same profile into one network
/// flow (RT-rotation race guard: the second caller joins the first task
/// instead of firing a second grant with a stale RT).
public actor RefreshSingleflight {
    private var inflight: [String: Task<Bool, Error>] = [:]

    public init() {}

    public func refresh(
        profile: String,
        store: any TokenStore,
        fetcher: any TokenRefreshFetcher,
        now: @Sendable @escaping () -> UInt64 = { TokenStatus.nowSecs() }
    ) async throws -> Bool {
        let name = TomlConfig.normalize(profile)
        if let pending = inflight[name] {
            return try await pending.value
        }
        let task = Task<Bool, Error> {
            try await TokenRefresh.refresh(
                profile: name, store: store, fetcher: fetcher, now: now
            )
        }
        inflight[name] = task
        do {
            let ok = try await task.value
            inflight[name] = nil
            return ok
        } catch {
            inflight[name] = nil
            throw error
        }
    }
}
