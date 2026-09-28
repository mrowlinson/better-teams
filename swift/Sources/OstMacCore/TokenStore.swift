// TokenStore.swift — R13 token-store lane: Swift-owned token store.
//
// Keychain-primary + TOML write-through (same paths/schema/0600 as
// `ost::config`), so the STAY-36 keep riding the TOML files throughout the
// FFI shrink. Read path: keychain first, TOML fallback + import on every
// mtime/size change (same fingerprint rule as Rust `load_cached_for`).
// Auth-critical: fixture tokens in tests ONLY; this file never logs values.
import Foundation
import Security

// MARK: - Slots (TOML-schema-compatible keys, mirrors `ost::config::Config`)

/// One stored access token. `expires_at` nil = never expires (matches Rust).
public struct StoredTokenValue: Codable, Sendable, Equatable {
    public var token: String
    public var expiresAt: UInt64?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }

    public init(token: String, expiresAt: UInt64? = nil) {
        self.token = token
        self.expiresAt = expiresAt
    }

    public init(token: String, now: UInt64, expiresIn: UInt64?) {
        self.token = token
        self.expiresAt = expiresIn.map { now + $0 }
    }

    /// 5-minute skew (matches `StoredToken::is_expired`: now + 300 >= exp).
    public func isExpired(now: UInt64) -> Bool {
        guard let exp = expiresAt else { return false }
        return now + TokenSlots.expirySkew >= exp
    }
}

/// 7 token slots + tenant, same keys as the Rust `Config` TOML schema.
public struct TokenSlots: Codable, Sendable, Equatable {
    public static let expirySkew: UInt64 = 300

    public var accessToken: StoredTokenValue?
    public var refreshToken: String?
    public var tenantID: String?
    public var skypeToken: StoredTokenValue?
    public var graphToken: StoredTokenValue?
    public var ic3Token: StoredTokenValue?
    public var recorderToken: StoredTokenValue?
    public var regionGtms: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tenantID = "tenant_id"
        case skypeToken = "skype_token"
        case graphToken = "graph_token"
        case ic3Token = "ic3_token"
        case recorderToken = "recorder_token"
        case regionGtms = "region_gtms"
    }

    public init(
        accessToken: StoredTokenValue? = nil,
        refreshToken: String? = nil,
        tenantID: String? = nil,
        skypeToken: StoredTokenValue? = nil,
        graphToken: StoredTokenValue? = nil,
        ic3Token: StoredTokenValue? = nil,
        recorderToken: StoredTokenValue? = nil,
        regionGtms: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tenantID = tenantID
        self.skypeToken = skypeToken
        self.graphToken = graphToken
        self.ic3Token = ic3Token
        self.recorderToken = recorderToken
        self.regionGtms = regionGtms
    }

    /// All slots empty (post-sign-out / never-signed-in shape).
    public static func cleared() -> TokenSlots { TokenSlots() }

    public var hasAnything: Bool {
        accessToken != nil || refreshToken != nil || tenantID != nil
            || skypeToken != nil || graphToken != nil || ic3Token != nil
            || recorderToken != nil || regionGtms != nil
    }
}

// MARK: - Store protocol

public enum TokenStoreError: Error, Sendable, Equatable {
    case io(String)
    case corrupt(String)
}

/// Per-profile token persistence. `status` is a pure read: zero network,
/// never blocks on refresh.
public protocol TokenStore: Sendable {
    func load(profile: String) -> TokenSlots
    func save(_ slots: TokenSlots, profile: String) throws
    /// Sign-out: drop the profile's tokens. Non-default profiles also lose
    /// their TOML file; `default` keeps a cleared file (matches Rust
    /// `sign_out_json_for`). Other profiles are untouched.
    func clear(profile: String) throws
    func status(profile: String) -> StatusResponse
}

// MARK: - Status builder (pure; same envelope as Rust `token_summary`)

public enum TokenStatus {
    public static func nowSecs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }

    public static func summarize(_ slots: TokenSlots, now: UInt64) -> StatusResponse {
        func slot(_ t: StoredTokenValue?) -> TokenSlot {
            switch t {
            case .none:
                TokenSlot(present: false, expired: false)
            case .some(let tok) where !tok.isExpired(now: now):
                TokenSlot(present: true, expired: false)
            case .some:
                TokenSlot(present: true, expired: true)
            }
        }
        let aad = slot(slots.accessToken)
        return StatusResponse(
            ok: true,
            signed_in: aad.present && !aad.expired,
            tokens: TokenSummary(
                aad: aad,
                refresh_present: slots.refreshToken != nil,
                graph: slot(slots.graphToken),
                ic3: slot(slots.ic3Token),
                recorder: slot(slots.recorderToken),
                skype: slot(slots.skypeToken),
                region_gtms_present: slots.regionGtms != nil
            )
        )
    }
}

// MARK: - In-memory store (tests / previews; never the real keychain)

/// In-memory slots keyed by normalized profile. All tests use this (or a
/// `PersistentTokenStore` over it) — the Klipy/CatchUp precedent.
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [String: TokenSlots] = [:]
    private let now: @Sendable () -> UInt64

    public init(now: (@Sendable () -> UInt64)? = nil) {
        self.now = now ?? { TokenStatus.nowSecs() }
    }

    private func key(_ profile: String) -> String {
        TomlConfig.normalize(profile)
    }

    public func load(profile: String) -> TokenSlots {
        lock.lock(); defer { lock.unlock() }
        return slots[key(profile)] ?? TokenSlots()
    }

    public func save(_ slots: TokenSlots, profile: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.slots[key(profile)] = slots
    }

    public func clear(profile: String) throws {
        lock.lock(); defer { lock.unlock() }
        slots.removeValue(forKey: key(profile))
    }

    public func status(profile: String) -> StatusResponse {
        TokenStatus.summarize(load(profile: profile), now: now())
    }
}

// MARK: - Keychain store (Klipy/CatchUp pattern, per-profile JSON blob)

// swiftlint:disable:next type_name
/// macOS keychain items: service `dev.ostmac.OstMac.tokens`, account
/// `profile:<sanitized>` (`profile:default` for the legacy profile). Own
/// service — KLIPY (`…klipy`) and CatchUp (`…catchup`) items are never
/// touched. The `SecItemDelete` in `clear` is scoped to service+account
/// (same precedent as Klipy/CatchUp); no blanket delete exists here.
public struct KeychainTokenStore: TokenStore {
    public static let service = "dev.ostmac.OstMac.tokens"

    private let now: @Sendable () -> UInt64

    public init(now: (@Sendable () -> UInt64)? = nil) {
        self.now = now ?? { TokenStatus.nowSecs() }
    }

    public static func account(profile: String) -> String {
        let name = TomlConfig.normalize(profile)
        if name.compare(
            TomlConfig.defaultProfile, options: .caseInsensitive
        ) == .orderedSame {
            return "profile:default"
        }
        return "profile:\(TomlConfig.sanitize(name))"
    }

    private static func query(profile: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(profile: profile),
        ]
    }

    public func load(profile: String) -> TokenSlots {
        var q = Self.query(profile: profile)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let slots = try? JSONDecoder().decode(TokenSlots.self, from: data)
        else { return TokenSlots() }
        return slots
    }

    public func save(_ slots: TokenSlots, profile: String) throws {
        let data = try JSONEncoder().encode(slots)
        let q = Self.query(profile: profile)
        if SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess {
            let st = SecItemUpdate(
                q as CFDictionary, [kSecValueData as String: data] as CFDictionary
            )
            guard st == errSecSuccess else {
                throw TokenStoreError.io("keychain update failed (\(st))")
            }
        } else {
            var add = q
            add[kSecValueData as String] = data
            let st = SecItemAdd(add as CFDictionary, nil)
            guard st == errSecSuccess else {
                throw TokenStoreError.io("keychain add failed (\(st))")
            }
        }
    }

    public func clear(profile: String) throws {
        _ = SecItemDelete(Self.query(profile: profile) as CFDictionary)
    }

    public func status(profile: String) -> StatusResponse {
        TokenStatus.summarize(load(profile: profile), now: now())
    }
}

// MARK: - TOML codec (same schema as `ost::config::Config`)

// swiftlint:disable:next type_name
/// Minimal TOML reader/writer for machine-written config files. Validation
/// is delegated to the strict `TomlConfig.parse` (same accept/reject as the
/// R12 status path); this layer only extracts values from valid docs and
/// serializes bytes the Rust `toml` crate parses back.
public enum TokenTOML {
    /// Parse full slot values. Unknown keys ignored (serde parity);
    /// wrong-typed known keys throw (serde parity). Missing file is the
    /// caller's `TokenSlots()` (matches Rust `load_for`).
    public static func parse(_ text: String) throws -> TokenSlots {
        _ = try TomlConfig.parse(text) // strict validation first
        var slots = TokenSlots()
        var table: String?
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let norm = body.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in norm.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = TomlConfig.stripComment(String(rawLine))
                .trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("[") {
                table = String(t.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = TomlConfig.indexOfEquals(t) else { continue }
            let rawKey = String(t[t.startIndex ..< eq])
                .trimmingCharacters(in: .whitespaces)
            let rawVal = String(t[t.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            let segments = (try? TomlConfig.parseKey(rawKey)) ?? []
            guard let key = segments.last else { continue }
            var parents = table.map { [$0] } ?? []
            parents.append(contentsOf: segments.dropLast())
            setValue(&slots, parents: parents, key: key, rawVal: rawVal)
        }
        return slots
    }

    private static func setValue(
        _ slots: inout TokenSlots, parents: [String], key: String, rawVal: String
    ) {
        if parents.isEmpty {
            switch key {
            case "refresh_token":
                slots.refreshToken = decodeString(rawVal)
            case "tenant_id":
                slots.tenantID = decodeString(rawVal)
            case "region_gtms":
                slots.regionGtms = decodeString(rawVal)
            default:
                break
            }
            return
        }
        guard parents.count == 1 else { return }
        switch (parents[0], key) {
        case ("access_token", "token"):
            var s = slots.accessToken ?? StoredTokenValue(token: "")
            s.token = decodeString(rawVal) ?? ""
            slots.accessToken = s
        case ("access_token", "expires_at"):
            var s = slots.accessToken ?? StoredTokenValue(token: "")
            s.expiresAt = TomlConfig.parseInt(rawVal)
            slots.accessToken = s
        case ("skype_token", "token"):
            var s = slots.skypeToken ?? StoredTokenValue(token: "")
            s.token = decodeString(rawVal) ?? ""
            slots.skypeToken = s
        case ("skype_token", "expires_at"):
            var s = slots.skypeToken ?? StoredTokenValue(token: "")
            s.expiresAt = TomlConfig.parseInt(rawVal)
            slots.skypeToken = s
        case ("graph_token", "token"):
            var s = slots.graphToken ?? StoredTokenValue(token: "")
            s.token = decodeString(rawVal) ?? ""
            slots.graphToken = s
        case ("graph_token", "expires_at"):
            var s = slots.graphToken ?? StoredTokenValue(token: "")
            s.expiresAt = TomlConfig.parseInt(rawVal)
            slots.graphToken = s
        case ("ic3_token", "token"):
            var s = slots.ic3Token ?? StoredTokenValue(token: "")
            s.token = decodeString(rawVal) ?? ""
            slots.ic3Token = s
        case ("ic3_token", "expires_at"):
            var s = slots.ic3Token ?? StoredTokenValue(token: "")
            s.expiresAt = TomlConfig.parseInt(rawVal)
            slots.ic3Token = s
        case ("recorder_token", "token"):
            var s = slots.recorderToken ?? StoredTokenValue(token: "")
            s.token = decodeString(rawVal) ?? ""
            slots.recorderToken = s
        case ("recorder_token", "expires_at"):
            var s = slots.recorderToken ?? StoredTokenValue(token: "")
            s.expiresAt = TomlConfig.parseInt(rawVal)
            slots.recorderToken = s
        default:
            break
        }
    }

    /// Decode a TOML basic or literal string value (already validated).
    static func decodeString(_ raw: String) -> String? {
        if raw.hasPrefix("\"") {
            guard let inner = basicInner(raw) else { return nil }
            return unescape(inner)
        }
        if raw.hasPrefix("'"), let end = raw.dropFirst().firstIndex(of: "'") {
            return String(raw[raw.index(after: raw.startIndex) ..< end])
        }
        return nil
    }

    /// Body between the outer basic-string quotes (escapes intact).
    private static func basicInner(_ raw: String) -> String? {
        var i = raw.index(after: raw.startIndex)
        var body = ""
        while i != raw.endIndex {
            let ch = raw[i]
            if ch == "\\" {
                let n = raw.index(after: i)
                guard n != raw.endIndex else { return nil }
                body.append(ch)
                body.append(raw[n])
                i = raw.index(after: n)
                continue
            }
            if ch == "\"" { return body }
            body.append(ch)
            i = raw.index(after: i)
        }
        return nil
    }

    /// Process TOML basic-string escapes (`\" \\ \b \f \n \r \t \u \U`).
    static func unescape(_ body: String) -> String? {
        var out = ""
        var i = body.startIndex
        while i != body.endIndex {
            let ch = body[i]
            i = body.index(after: i)
            guard ch == "\\" else {
                out.append(ch)
                continue
            }
            guard i != body.endIndex else { return nil }
            let e = body[i]
            i = body.index(after: i)
            switch e {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                guard let s = hexScalar(body, &i, 4) else { return nil }
                out.append(Character(s))
            case "U":
                guard let s = hexScalar(body, &i, 8) else { return nil }
                out.append(Character(s))
            default:
                return nil
            }
        }
        return out
    }

    private static func hexScalar(
        _ s: String, _ i: inout String.Index, _ n: Int
    ) -> Unicode.Scalar? {
        var v: UInt32 = 0
        for _ in 0 ..< n {
            guard i != s.endIndex, let d = s[i].hexDigitValue else { return nil }
            v = v * 16 + UInt32(d)
            i = s.index(after: i)
        }
        return Unicode.Scalar(v)
    }

    /// Serialize slots to TOML the Rust `toml` crate parses back into
    /// `Config` (scalars then one `[table]` per present token slot).
    public static func serialize(_ slots: TokenSlots) -> String {
        var out = ""
        if let s = slots.refreshToken {
            out += "refresh_token = \(encode(s))\n"
        }
        if let s = slots.tenantID {
            out += "tenant_id = \(encode(s))\n"
        }
        if let s = slots.regionGtms {
            out += "region_gtms = \(encode(s))\n"
        }
        table(&out, name: "access_token", slots.accessToken)
        table(&out, name: "skype_token", slots.skypeToken)
        table(&out, name: "graph_token", slots.graphToken)
        table(&out, name: "ic3_token", slots.ic3Token)
        table(&out, name: "recorder_token", slots.recorderToken)
        return out
    }

    private static func table(
        _ out: inout String, name: String, _ tok: StoredTokenValue?
    ) {
        guard let tok else { return }
        out += "[\(name)]\n"
        out += "token = \(encode(tok.token))\n"
        if let exp = tok.expiresAt {
            out += "expires_at = \(exp)\n"
        }
    }

    /// TOML basic-string encoding (JSON-compatible escaping).
    static func encode(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x00 ..< 0x20, 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}

// MARK: - Persistent store (keychain-primary + TOML write-through)

// swiftlint:disable:next type_name
/// Production store: keychain blob first, TOML fallback + re-import on
/// every (size, mtime) change (same fingerprint rule as Rust
/// `load_cached_for`, so Rust saves show up on the next Swift read).
/// Every save writes both (TOML 0600, atomic rename = mtime bump, so
/// Rust reads stay fresh for the STAY-36).
public final class PersistentTokenStore: TokenStore, @unchecked Sendable {
    private struct Fingerprint: Equatable {
        let size: UInt64
        let mtime: Date
    }

    private let blob: any TokenStore
    private let configDir: URL
    private let now: @Sendable () -> UInt64
    private let lock = NSLock()
    private var lastSeen: [String: Fingerprint?] = [:]

    /// - Parameter blob: keychain in production, memory in tests.
    /// - Parameter configDir: nil = real `ost::config` dir; tests inject tmp.
    public init(
        blob: any TokenStore,
        configDir: URL? = nil,
        now: (@Sendable () -> UInt64)? = nil
    ) throws {
        self.blob = blob
        if let configDir {
            self.configDir = configDir
        } else {
            self.configDir = try TomlConfig.defaultDir()
        }
        self.now = now ?? { TokenStatus.nowSecs() }
    }

    private func fileURL(profile: String) -> URL {
        configDir.appendingPathComponent(TomlConfig.fileName(profile: profile))
    }

    private func fingerprint(profile: String) -> Fingerprint? {
        let path = fileURL(profile: profile).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return Fingerprint(size: size, mtime: mtime)
    }

    public func load(profile: String) -> TokenSlots {
        let name = TomlConfig.normalize(profile)
        let fp = fingerprint(profile: name)
        lock.lock()
        let seen = lastSeen[name] ?? nil
        lock.unlock()
        if fp != seen {
            // TOML changed (or first sight): import wins, keychain follows.
            let imported = (try? readTOML(profile: name)) ?? TokenSlots()
            try? blob.save(imported, profile: name)
            lock.lock()
            lastSeen[name] = fp
            lock.unlock()
            return imported
        }
        let cached = blob.load(profile: name)
        if !cached.hasAnything, fp != nil,
           let fresh = try? readTOML(profile: name), fresh.hasAnything
        {
            // Blob lost (fresh keychain) but TOML has data: one-time import.
            try? blob.save(fresh, profile: name)
            return fresh
        }
        return cached
    }

    private func readTOML(profile: String) throws -> TokenSlots {
        let url = fileURL(profile: profile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return TokenSlots()
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try TokenTOML.parse(text)
    }

    public func save(_ slots: TokenSlots, profile: String) throws {
        let name = TomlConfig.normalize(profile)
        // TOML first: write-through failure must fail loudly (STAY-36 ride
        // the TOML), and only then does the blob follow.
        try writeTOML(slots, profile: name)
        try blob.save(slots, profile: name)
        lock.lock()
        lastSeen[name] = fingerprint(profile: name)
        lock.unlock()
    }

    private func writeTOML(_ slots: TokenSlots, profile: String) throws {
        let dir = configDir
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let url = fileURL(profile: profile)
        let data = Data(TokenTOML.serialize(slots).utf8)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            throw TokenStoreError.io("toml write failed: \(error)")
        }
    }

    public func clear(profile: String) throws {
        let name = TomlConfig.normalize(profile)
        try blob.clear(profile: name)
        if name.compare(
            TomlConfig.defaultProfile, options: .caseInsensitive
        ) == .orderedSame {
            // Default keeps a cleared file (matches Rust sign-out).
            try writeTOML(TokenSlots.cleared(), profile: name)
        } else if FileManager.default.fileExists(
            atPath: fileURL(profile: name).path
        ) {
            do {
                try FileManager.default.removeItem(at: fileURL(profile: name))
            } catch {
                throw TokenStoreError.io("toml delete failed: \(error)")
            }
        }
        lock.lock()
        lastSeen[name] = fingerprint(profile: name)
        lock.unlock()
    }

    public func status(profile: String) -> StatusResponse {
        TokenStatus.summarize(load(profile: profile), now: now())
    }
}
