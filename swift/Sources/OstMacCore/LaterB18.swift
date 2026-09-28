// LaterB18.swift — R14 om-later-b18: device-code auth in Swift.
//
// Verbatim port of `device_start_json{,_for}` + `device_poll_json`
// (rust/ostmac-core/src/lib.rs:132-360): same endpoints/forms, same
// PendingSession map semantics (`dc-<now>-<n>` ids), same save +
// best-effort derived fan-out via TokenRefresh (the Swift
// `oauth::refresh_for`), same error codes. Network runs through the
// injected TokenRefreshFetcher (URLSession in production, stub in
// tests); persistence through the injected TokenStore (keychain+TOML
// PersistentTokenStore in production, memory in tests).
//
// One documented deviation: Rust cleared the Rust-side whoami cache
// on poll-complete; no FFI to it remains, so only the Swift cache is
// cleared (the UI path). Rust readers (calls.rs display names) refresh
// on next sign-out/miss. Auth-critical: never log token values.
import Foundation

/// Device-code sign-in (was `ostmac_device_start{,_for}`, `ostmac_device_poll`).
public enum DeviceAuth {
    // MARK: - Pending sessions (port of Rust `sessions()` map)

    struct Pending: Sendable {
        let deviceCode: String
        let tokenURL: String
        let clientID: String
        let createdAt: UInt64
        let expiresIn: UInt64
        let interval: UInt64
        let profile: String
    }

    /// Process-wide pending map. Lock-guarded like the Rust Mutex; ids
    /// match Rust `new_session_id` (`dc-<now>-<n>`, counter from 1).
    enum Sessions {
        private static let lock = NSLock()
        private static var map: [String: Pending] = [:]
        private static var counter: UInt64 = 1

        static func insert(_ p: Pending, now: UInt64) -> String {
            lock.lock(); defer { lock.unlock() }
            let id = "dc-\(now)-\(counter)"
            counter += 1
            map[id] = p
            return id
        }

        static func get(_ id: String) -> Pending? {
            lock.lock(); defer { lock.unlock() }
            return map[id]
        }

        static func remove(_ id: String) {
            lock.lock(); defer { lock.unlock() }
            map.removeValue(forKey: id)
        }

        /// Sign-out path (was the `retain` in `sign_out_json_for`).
        /// Normalizes like the Rust `target` compare.
        static func drop(profile: String) {
            let target = TomlConfig.normalize(profile)
            lock.lock(); defer { lock.unlock() }
            map = map.filter { $0.value.profile != target }
        }
    }

    // MARK: - Production defaults

    static func productionStore() throws -> PersistentTokenStore {
        try PersistentTokenStore(blob: KeychainTokenStore(), configDir: nil)
    }

    // MARK: - Start (port of `device_start_json_for`)

    /// Device-code start for one profile. `store` is unused here (start
    /// is network + session map only) but kept for call symmetry.
    public static func deviceStart(
        profile: String,
        store _: any TokenStore,
        fetcher: any TokenRefreshFetcher,
        now: @Sendable @escaping () -> UInt64 = { TokenStatus.nowSecs() }
    ) async throws -> DeviceStart {
        let target = TomlConfig.normalize(profile)
        guard let url = URL(string: AuthEndpoints.deviceCodeURL) else {
            throw CoreCallError.failed("device_start: bad devicecode URL")
        }
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: AuthEndpoints.clientID),
            URLQueryItem(name: "scope", value: AuthEndpoints.deviceCodeScope),
        ]
        let body = Data((comps.percentEncodedQuery ?? "").utf8)
        let resp: TokenHTTPResponse
        do {
            resp = try await fetcher.post(
                url: url,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: body
            )
        } catch {
            throw CoreCallError.failed("device_start: devicecode request: \(error)")
        }
        // Parse first, then status (Rust order: `resp.json()` before
        // `is_success`, so a non-JSON error body reports parse, not http).
        guard let obj = try? JSONSerialization.jsonObject(with: bodyData(resp))
            as? [String: Any]
        else {
            throw CoreCallError.failed("device_start: devicecode parse: body is not JSON")
        }
        guard (200 ... 299).contains(resp.status) else {
            throw CoreCallError.failed(
                "device_start: devicecode http \(resp.status): \(rawBody(resp))"
            )
        }
        func get(_ k: String) throws -> String {
            // Rust `get`: string-typed passes (even empty); missing or
            // non-string fails.
            guard let s = obj[k] as? String else {
                throw CoreCallError.failed("device_start: devicecode missing \(k)")
            }
            return s
        }
        // All required keys validated BEFORE insert (Rust order: the
        // `get` closure runs before `lock_sessions().insert`).
        let deviceCode = try get("device_code")
        let userCode = try get("user_code")
        let verificationURI = try get("verification_uri")
        let expiresIn = u64(obj["expires_in"]) ?? 900
        let interval = u64(obj["interval"]) ?? 5
        let started = now()
        let id = Sessions.insert(
            Pending(
                deviceCode: deviceCode,
                tokenURL: AuthEndpoints.tokenURL,
                clientID: AuthEndpoints.clientID,
                createdAt: started,
                expiresIn: expiresIn,
                interval: interval,
                profile: target
            ),
            now: started
        )
        return DeviceStart(
            ok: true,
            session: id,
            verification_uri: verificationURI,
            user_code: userCode,
            message: obj["message"] as? String ?? "",
            expires_in: Int(expiresIn),
            interval: Int(interval)
        )
    }

    // MARK: - Poll (port of `device_poll_json`)

    public static func devicePoll(
        session: String,
        store: any TokenStore,
        fetcher: any TokenRefreshFetcher,
        now: @Sendable @escaping () -> UInt64 = { TokenStatus.nowSecs() }
    ) async throws -> DevicePoll {
        guard let p = Sessions.get(session) else {
            throw CoreCallError.failed("no_session: unknown or finished session")
        }
        let at = now()
        if at > p.createdAt + p.expiresIn {
            Sessions.remove(session)
            throw CoreCallError.failed(
                "device_expired: device code expired; start again"
            )
        }
        guard let url = URL(string: p.tokenURL) else {
            Sessions.remove(session)
            throw CoreCallError.failed("device_poll: bad token URL")
        }
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(
                name: "grant_type",
                value: "urn:ietf:params:oauth:grant-type:device_code"
            ),
            URLQueryItem(name: "device_code", value: p.deviceCode),
            URLQueryItem(name: "client_id", value: p.clientID),
        ]
        let form = Data((comps.percentEncodedQuery ?? "").utf8)
        // Transport AND parse failures are retryable (Rust maps both to
        // pending) — only an error code is fatal.
        let obj: [String: Any]
        do {
            let resp = try await fetcher.post(
                url: url,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: form
            )
            guard let parsed = try? JSONSerialization.jsonObject(
                with: bodyData(resp)
            ) as? [String: Any] else {
                return DevicePoll(
                    ok: true, status: "pending",
                    interval: Int(p.interval), tokens: nil
                )
            }
            obj = parsed
        } catch {
            return DevicePoll(
                ok: true, status: "pending",
                interval: Int(p.interval), tokens: nil
            )
        }
        // Rust: any string-typed access_token completes (even empty).
        if let tok = obj["access_token"] as? String {
            try await complete(
                pending: p, session: session, body: obj, accessToken: tok,
                store: store, fetcher: fetcher, now: now
            )
            let tokens = store.status(profile: p.profile).tokens
            return DevicePoll(
                ok: true, status: "complete", interval: nil, tokens: tokens
            )
        }
        let code = obj["error"] as? String ?? "unknown"
        switch code {
        case "authorization_pending", "slow_down":
            return DevicePoll(
                ok: true, status: "pending",
                interval: Int(p.interval), tokens: nil
            )
        default:
            Sessions.remove(session)
            throw CoreCallError.failed("device_poll: \(code): \(rawBody(obj))")
        }
    }

    /// Save AAD tokens + best-effort derived fan-out (Rust: save_to +
    /// `let _ = refresh_for`). Write-through failure is loud (`token_save`).
    private static func complete(
        pending p: Pending,
        session: String,
        body: [String: Any],
        accessToken: String,
        store: any TokenStore,
        fetcher: any TokenRefreshFetcher,
        now: @Sendable @escaping () -> UInt64
    ) async throws {
        let at = now()
        var slots = store.load(profile: p.profile)
        slots.accessToken = StoredTokenValue(
            token: accessToken, now: at, expiresIn: u64(body["expires_in"])
        )
        if let rt = body["refresh_token"] as? String, !rt.isEmpty {
            slots.refreshToken = rt
        }
        do {
            try store.save(slots, profile: p.profile)
        } catch {
            throw CoreCallError.failed("token_save: \(error)")
        }
        // Best-effort derived tokens (each warns, never fails login).
        _ = try? await TokenRefresh.refresh(
            profile: p.profile, store: store, fetcher: fetcher, now: now
        )
        Sessions.remove(session)
        CoreReads.whoamiCacheClear(profile: p.profile)
    }

    // MARK: - JSON helpers

    /// Unsigned int from a JSON number (Rust `as_u64`: strings rejected).
    static func u64(_ v: Any?) -> UInt64? {
        if let n = v as? UInt64 { return n }
        if let n = v as? Int, n >= 0 { return UInt64(n) }
        return nil
    }

    private static func bodyData(_ resp: TokenHTTPResponse) -> Data {
        resp.data
    }

    private static func rawBody(_ resp: TokenHTTPResponse) -> String {
        String(data: resp.data, encoding: .utf8) ?? ""
    }

    private static func rawBody(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s.replacingOccurrences(of: "\\/", with: "/")
    }
}

extension AuthEndpoints {
    /// Device-code `scope` param (matches `AuthConfig::work().scope` =
    /// AAD audience + `offline_access`, sent verbatim, not via grantScope).
    static let deviceCodeScope =
        "https://api.spaces.skype.com/.default offline_access"
}
