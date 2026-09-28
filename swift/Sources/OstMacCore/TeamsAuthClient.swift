// TeamsAuthClient.swift — R13 token-store lane: Swift `TeamsClient`.
//
// URL-for-URL, header-for-header port of `ost::api::client::TeamsClient`
// (build auto-refresh trigger + graph/skype/chat/csa request helpers).
// The fetcher is injected so tests never touch the network.
import Foundation

// MARK: - Fetcher seam

public struct AuthHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public let headers: [String: String]

    public init(status: Int, data: Data, headers: [String: String] = [:]) {
        self.status = status
        self.data = data
        self.headers = headers
    }
}

public protocol TeamsAuthFetcher: Sendable {
    func send(
        method: String, url: URL, headers: [String: String], body: Data?
    ) async throws -> AuthHTTPResponse
}

public struct URLSessionAuthFetcher: TeamsAuthFetcher {
    public init() {}

    public func send(
        method: String, url: URL, headers: [String: String], body: Data?
    ) async throws -> AuthHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var out: [String: String] = [:]
        if let http = resp as? HTTPURLResponse {
            for (k, v) in http.allHeaderFields {
                if let ks = k as? String, let vs = v as? String {
                    out[ks] = vs
                }
            }
        }
        return AuthHTTPResponse(status: status, data: data, headers: out)
    }
}

public enum TeamsAuthError: Error, Sendable, Equatable {
    case auth(String)
    case http(String)
    case network(String)
}

// MARK: - Client

public enum TeamsAuthClient {
    public static let graphBase = "https://graph.microsoft.com/v1.0"
    public static let defaultChatService =
        "https://amer.ng.msg.teams.microsoft.com"
    public static let chatsvcagg = "https://chatsvcagg.teams.microsoft.com"
    public static let csaClientVersion = "1416/1.0.0.2024050301"

    /// Authenticated client over a token snapshot. Build (auto-refresh
    /// trigger) mirrors `TeamsClient::new_for_profile`: AAD or graph
    /// missing/expired + RT present → exactly 1 refresh before the API
    /// call, else 0; needs-refresh without RT → throw.
    public struct Client: Sendable {
        public let profile: String
        let slots: TokenSlots
        let fetcher: any TeamsAuthFetcher

        func graphToken() throws -> String {
            guard let t = slots.graphToken else {
                throw TeamsAuthError.auth(
                    "No Graph token. Run 'teams-cli login' first."
                )
            }
            if t.isExpired(now: TokenStatus.nowSecs()) {
                throw TeamsAuthError.auth(
                    "Graph token expired. Run 'teams-cli login'."
                )
            }
            return t.token
        }

        func skypeToken() throws -> String {
            guard let t = slots.skypeToken else {
                throw TeamsAuthError.auth(
                    "No Skype token. Run 'teams-cli login' first."
                )
            }
            if t.isExpired(now: TokenStatus.nowSecs()) {
                throw TeamsAuthError.auth(
                    "Skype token expired. Run 'teams-cli login'."
                )
            }
            return t.token
        }

        // MARK: Graph (Bearer [REDACTED] graph token)

        public func graphGet(_ path: String) async throws -> AuthHTTPResponse {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(graphBase + path)
            return try await checked(
                fetcher.send(
                    method: "GET", url: url,
                    headers: ["Authorization": "Bearer \(token)"], body: nil
                ),
                url: url.absoluteString
            )
        }

        /// GET with `ConsistencyLevel: eventual` (Graph `$search`/`$count`
        /// 400 without it). Otherwise identical to `graphGet`.
        public func graphGetConsistent(_ path: String) async throws
            -> AuthHTTPResponse
        {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(graphBase + path)
            return try await checked(
                fetcher.send(
                    method: "GET", url: url,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "ConsistencyLevel": "eventual",
                    ], body: nil
                ),
                url: url.absoluteString
            )
        }

        /// GET an absolute Graph URL (async `Content-Location` polls).
        public func graphGetURL(_ urlString: String) async throws
            -> AuthHTTPResponse
        {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(urlString)
            return try await checked(
                fetcher.send(
                    method: "GET", url: url,
                    headers: ["Authorization": "Bearer \(token)"], body: nil
                ),
                url: urlString
            )
        }

        public func graphPost(
            _ path: String, body: [String: Any]
        ) async throws -> AuthHTTPResponse {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(graphBase + path)
            return try await checked(
                fetcher.send(
                    method: "POST", url: url,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json",
                    ],
                    body: TeamsAuthClient.json(body)
                ),
                url: url.absoluteString
            )
        }

        public func graphDelete(_ path: String) async throws -> AuthHTTPResponse {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(graphBase + path)
            return try await checked(
                fetcher.send(
                    method: "DELETE", url: url,
                    headers: ["Authorization": "Bearer \(token)"], body: nil
                ),
                url: url.absoluteString
            )
        }

        /// PUT bytes (drive upload). `contentType` is the file MIME.
        public func graphPutBytes(
            _ path: String, bytes: Data, contentType: String
        ) async throws -> AuthHTTPResponse {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(graphBase + path)
            return try await checked(
                fetcher.send(
                    method: "PUT", url: url,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": contentType,
                    ],
                    body: bytes
                ),
                url: url.absoluteString
            )
        }

        public func graphPatch(
            _ path: String, body: [String: Any]
        ) async throws -> AuthHTTPResponse {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(graphBase + path)
            return try await checked(
                fetcher.send(
                    method: "PATCH", url: url,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": "application/json",
                    ],
                    body: TeamsAuthClient.json(body)
                ),
                url: url.absoluteString
            )
        }

        /// PATCH with a raw body (OneNote multipart edit path).
        public func graphPatchRaw(
            _ path: String, contentType: String, body: Data
        ) async throws -> AuthHTTPResponse {
            let token = try graphToken()
            let url = try TeamsAuthClient.url(graphBase + path)
            return try await checked(
                fetcher.send(
                    method: "PATCH", url: url,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Content-Type": contentType,
                    ],
                    body: body
                ),
                url: url.absoluteString
            )
        }

        /// One resumable-upload fragment to a pre-authenticated session
        /// URL: no Bearer [REDACTED] (Graph rejects authed fragment PUTs).
        /// `start`/`end` are inclusive.
        public func driveSessionPut(
            uploadURL: String, chunk: Data, start: UInt64, end: UInt64,
            total: UInt64
        ) async throws -> AuthHTTPResponse {
            let url = try TeamsAuthClient.url(uploadURL)
            return try await checked(
                fetcher.send(
                    method: "PUT", url: url,
                    headers: [
                        "Content-Range": "bytes \(start)-\(end)/\(total)",
                        "Content-Length": "\(chunk.count)",
                    ],
                    body: chunk
                ),
                url: uploadURL
            )
        }

        // MARK: Teams/Skype (X-SkypeToken)

        public func teamsGet(_ urlString: String) async throws
            -> AuthHTTPResponse
        {
            let token = try skypeToken()
            let url = try TeamsAuthClient.url(urlString)
            return try await checked(
                fetcher.send(
                    method: "GET", url: url,
                    headers: ["X-SkypeToken": token], body: nil
                ),
                url: urlString
            )
        }

        public func teamsPost(
            _ urlString: String, body: [String: Any]
        ) async throws -> AuthHTTPResponse {
            let token = try skypeToken()
            let url = try TeamsAuthClient.url(urlString)
            return try await checked(
                fetcher.send(
                    method: "POST", url: url,
                    headers: [
                        "X-SkypeToken": token,
                        "Content-Type": "application/json",
                    ],
                    body: TeamsAuthClient.json(body)
                ),
                url: urlString
            )
        }

        // MARK: CSA (Bearer [REDACTED] skype + client version)

        public func csaGet(_ urlString: String) async throws -> AuthHTTPResponse {
            let token = try skypeToken()
            let url = try TeamsAuthClient.url(urlString)
            return try await checked(
                fetcher.send(
                    method: "GET", url: url,
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "x-ms-client-version": csaClientVersion,
                    ], body: nil
                ),
                url: urlString
            )
        }

        // MARK: Native chat (`Authentication: skypetoken=…`)

        public func chatGet(_ urlString: String) async throws -> AuthHTTPResponse {
            let token = try skypeToken()
            let url = try TeamsAuthClient.url(urlString)
            return try await checked(
                fetcher.send(
                    method: "GET", url: url,
                    headers: ["Authentication": "skypetoken=\(token)"],
                    body: nil
                ),
                url: urlString
            )
        }

        public func chatPost(
            _ urlString: String, body: [String: Any]
        ) async throws -> AuthHTTPResponse {
            let token = try skypeToken()
            let url = try TeamsAuthClient.url(urlString)
            return try await checked(
                fetcher.send(
                    method: "POST", url: url,
                    headers: [
                        "Authentication": "skypetoken=\(token)",
                        "Content-Type": "application/json",
                    ],
                    body: TeamsAuthClient.json(body)
                ),
                url: urlString
            )
        }

        public func chatPut(
            _ urlString: String, body: [String: Any]
        ) async throws -> AuthHTTPResponse {
            let token = try skypeToken()
            let url = try TeamsAuthClient.url(urlString)
            return try await checked(
                fetcher.send(
                    method: "PUT", url: url,
                    headers: [
                        "Authentication": "skypetoken=\(token)",
                        "Content-Type": "application/json",
                    ],
                    body: TeamsAuthClient.json(body)
                ),
                url: urlString
            )
        }

        /// DELETE with optional JSON body (reaction removal / deletes).
        public func chatDelete(
            _ urlString: String, body: [String: Any]? = nil
        ) async throws -> AuthHTTPResponse {
            let token = try skypeToken()
            let url = try TeamsAuthClient.url(urlString)
            var headers = ["Authentication": "skypetoken=\(token)"]
            var data: Data?
            if let body {
                headers["Content-Type"] = "application/json"
                data = TeamsAuthClient.json(body)
            }
            return try await checked(
                fetcher.send(
                    method: "DELETE", url: url, headers: headers, body: data
                ),
                url: urlString
            )
        }

        // MARK: Region URLs

        /// Chat service base from region_gtms, else the default.
        public var chatServiceURL: String {
            regionString("chatService") ?? defaultChatService
        }

        public var chatsvcaggURL: String {
            regionString("chatServiceAggregator") ?? chatsvcagg
        }

        private func regionString(_ key: String) -> String? {
            guard let g = slots.regionGtms,
                  let data = g.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                  let s = obj[key] as? String
            else { return nil }
            return s
        }

        private func checked(
            _ resp: AuthHTTPResponse, url: String
        ) async throws -> AuthHTTPResponse {
            try TeamsAuthClient.checked(resp, url: url)
        }
    }

    public static func build(
        profile: String,
        store: any TokenStore,
        refreshFetcher: any TokenRefreshFetcher,
        apiFetcher: any TeamsAuthFetcher,
        singleflight: RefreshSingleflight? = nil,
        now: @Sendable @escaping () -> UInt64 = { TokenStatus.nowSecs() }
    ) async throws -> Client {
        let name = TomlConfig.normalize(profile)
        var slots = store.load(profile: name)
        let nowVal = now()
        let needsRefresh =
            slots.accessToken.map { $0.isExpired(now: nowVal) } ?? true
            || slots.graphToken.map { $0.isExpired(now: nowVal) } ?? true
        if needsRefresh {
            guard slots.refreshToken != nil else {
                throw TeamsAuthError.auth(
                    "Token expired and no refresh token. Run 'teams-cli login'."
                )
            }
            let ok: Bool
            do {
                if let singleflight {
                    ok = try await singleflight.refresh(
                        profile: name, store: store, fetcher: refreshFetcher,
                        now: now
                    )
                } else {
                    ok = try await TokenRefresh.refresh(
                        profile: name, store: store, fetcher: refreshFetcher,
                        now: now
                    )
                }
            } catch {
                throw TeamsAuthError.auth(
                    "Token refresh failed: \(error). Run 'teams-cli login'."
                )
            }
            guard ok else {
                throw TeamsAuthError.auth(
                    "No refresh token available. Run 'teams-cli login'."
                )
            }
            slots = store.load(profile: name)
        }
        return Client(profile: name, slots: slots, fetcher: apiFetcher)
    }

    static func url(_ s: String) throws -> URL {
        guard let url = URL(string: s) else {
            throw TeamsAuthError.network("bad URL: \(s)")
        }
        return url
    }

    static func json(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// Status check mirroring Rust `check_response` (same messages).
    static func checked(_ resp: AuthHTTPResponse, url: String) throws
        -> AuthHTTPResponse
    {
        if resp.status == 401 {
            throw TeamsAuthError.http(
                "401 Unauthorized for \(url). " +
                    "Token may be invalid -- run 'teams-cli login'."
            )
        }
        if !(200 ... 299).contains(resp.status) {
            let body = String(data: resp.data, encoding: .utf8) ?? ""
            throw TeamsAuthError.http(
                "HTTP \(resp.status) for \(url): \(body)"
            )
        }
        return resp
    }
}
