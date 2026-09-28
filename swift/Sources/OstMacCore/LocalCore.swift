// LocalCore.swift — R12 ffi-move-now B0: version/init/status/profileActive
// moved from Rust FFI to Swift (pure/local reads; no network).
//
// profile_set deliberately stays FFI: it is the sole writer of the Rust
// active-profile global, and every profile-agnostic Rust path (whoami,
// chats, trouter, …) still reads that global. Moving it now would freeze
// those followers on "default" and silently break multi-account.
import Foundation

/// Swift-native implementations of the moved B0 symbols. Same JSON
/// envelopes as the old FFI (decoded through `decodeOrThrow`, so error
/// surfacing is unchanged).
public enum CoreLocal {
    /// Matches the retired Rust `VERSION_C` (single source of truth now).
    public static let versionString = "1.0.0"

    public static func version() -> String { versionString }

    /// No tokio runtime left to build on this path; always usable.
    public static func initialize() -> Int32 { 0 }

    /// Auth status for the persisted active account (the value App and
    /// AccountStore keep in sync with the core via profile_set).
    public static func status(
        defaults: UserDefaults = .standard,
        configDir: URL? = nil
    ) throws -> StatusResponse {
        try status(profile: activeProfileID(defaults: defaults), configDir: configDir)
    }

    /// Auth status for one account profile (no active switch).
    public static func status(profile: String, configDir: URL? = nil) throws -> StatusResponse {
        let dir = try configDir ?? TomlConfig.defaultDir()
        let json = TomlConfig.statusJSON(
            profile: profile, configDir: dir, now: TomlConfig.nowSecs()
        )
        return try decodeOrThrow(StatusResponse.self, from: Data(json.utf8))
    }

    /// Persisted active profile id (what profile_set last synced).
    public static func profileActive(
        defaults: UserDefaults = .standard
    ) throws -> ProfileResponse {
        let json = try statusJSONData(["ok": true, "profile": activeProfileID(defaults: defaults)])
        return try decodeOrThrow(ProfileResponse.self, from: json)
    }

    static func activeProfileID(defaults: UserDefaults = .standard) -> String {
        TomlConfig.normalize(defaults.string(forKey: AccountStore.activeKey) ?? "")
    }

    static func statusJSONData(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }
}

/// Token-file reader matching `ost::config` semantics (normalize, sanitize,
/// per-profile path, TOML-subset parse of machine-written config files,
/// 5-minute expiry skew). Unknown keys are ignored like serde; malformed
/// files and wrong-typed known keys yield the `config_load` envelope.
enum TomlConfig {
    static let bundleID = "com.teams-cli.teams-cli"
    static let defaultProfile = "default"
    static let expirySkew: UInt64 = 300
    static let tokenTables: Set<String> = [
        "access_token", "skype_token", "graph_token", "ic3_token", "recorder_token",
    ]

    struct Slot {
        var hasToken = false
        var expiresAt: UInt64?
    }

    struct Snapshot {
        var refreshPresent = false
        var regionPresent = false
        var slots: [String: Slot] = [:]
    }

    static func nowSecs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }

    /// Trimmed id, or `default` when blank (matches `normalize_profile`).
    static func normalize(_ profile: String) -> String {
        let t = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? defaultProfile : t
    }

    /// Filename-safe id: ASCII alphanumerics + `._-` kept, the rest `_`,
    /// capped at 64 chars, never empty (matches `sanitize_profile`; note
    /// ASCII-only, unlike `AccountProfile.sanitized`).
    static func sanitize(_ profile: String) -> String {
        var out = ""
        out.reserveCapacity(64)
        for s in profile.unicodeScalars.prefix(64) {
            let v = s.value
            let ok = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A) || v == 0x2E || v == 0x5F || v == 0x2D
            out.append(Character(ok ? s : UnicodeScalar("_")))
        }
        return out.isEmpty ? "_" : out
    }

    /// `config.toml` for default (any case), else `config-<id>.toml`.
    static func fileName(profile: String) -> String {
        let name = normalize(profile)
        if name.compare(defaultProfile, options: .caseInsensitive) == .orderedSame {
            return "config.toml"
        }
        return "config-\(sanitize(name)).toml"
    }

    /// `~/Library/Application Support/com.teams-cli.teams-cli`
    /// (matches `directories::ProjectDirs("com","teams-cli","teams-cli")`).
    static func defaultDir() throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw CoreCallError.failed("config_load: no application-support dir")
        }
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    static func expired(_ expiresAt: UInt64?, now: UInt64) -> Bool {
        guard let exp = expiresAt else { return false }
        return now + expirySkew >= exp
    }

    static func statusJSON(profile: String, configDir: URL, now: UInt64) -> String {
        let path = configDir.appendingPathComponent(fileName(profile: profile))
        let snap: Snapshot
        if !FileManager.default.fileExists(atPath: path.path) {
            snap = Snapshot()
        } else if let text = try? String(contentsOf: path, encoding: .utf8),
            let parsed = try? parse(text)
        {
            snap = parsed
        } else {
            return errJSON(code: "config_load", detail: "failed to load config file")
        }
        let slot: (String) -> [String: Bool] = { name in
            let s = snap.slots[name] ?? Slot()
            return ["present": s.hasToken, "expired": s.hasToken && expired(s.expiresAt, now: now)]
        }
        // `expired` is false when absent (matches the Rust slot closure).
        let obj: [String: Any] = [
            "ok": true,
            "signed_in": (snap.slots["access_token"]?.hasToken ?? false)
                && !expired(snap.slots["access_token"]?.expiresAt, now: now),
            "tokens": [
                "aad": slot("access_token"),
                "refresh_present": snap.refreshPresent,
                "graph": slot("graph_token"),
                "ic3": slot("ic3_token"),
                "recorder": slot("recorder_token"),
                "skype": slot("skype_token"),
                "region_gtms_present": snap.regionPresent,
            ] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return errJSON(code: "config_load", detail: "failed to encode status")
        }
        return json
    }

    static func errJSON(code: String, detail: String) -> String {
        "{\"ok\":false,\"error\":\"\(code)\",\"detail\":\"\(detail)\"}"
    }

    // MARK: - TOML subset parser

    enum Value {
        case string
        case int(UInt64)
        case other
    }

    struct Syntax: Error {
        let msg: String
    }

    static func parse(_ text: String) throws -> Snapshot {
        var snap = Snapshot()
        var table: String?
        var seenTables = Set<String>()
        var seenKeys = Set<String>()
        var valuePaths = Set<String>()
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        // NOTE: "\r\n" is ONE grapheme cluster in Swift, so Character-wise
        // splitting never sees a lone LF inside CRLF. Normalize first, then
        // reject any bare CR (the `toml` crate errors on those too).
        let norm = body.replacingOccurrences(of: "\r\n", with: "\n")
        if norm.unicodeScalars.contains(where: { $0.value == 0x0D }) {
            throw Syntax(msg: "bare CR")
        }
        for rawLine in norm.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("[") {
                guard t.hasSuffix("]") else { throw Syntax(msg: "bad table") }
                let name = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, validBare(name, dotted: true) else {
                    throw Syntax(msg: "bad table name")
                }
                guard !seenTables.contains(name), !valuePaths.contains(name) else {
                    throw Syntax(msg: "duplicate table")
                }
                seenTables.insert(name)
                table = name
                continue
            }
            guard let eq = indexOfEquals(t) else { throw Syntax(msg: "no =") }
            let rawKey = String(t[t.startIndex ..< eq]).trimmingCharacters(in: .whitespaces)
            let rawVal = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty, !rawVal.isEmpty else { throw Syntax(msg: "empty key/value") }
            let segments = try parseKey(rawKey)
            var parents = table.map { [$0] } ?? []
            parents.append(contentsOf: segments.dropLast())
            let key = segments.last!
            let fullPath = (parents + [key]).joined(separator: ".")
            guard !seenKeys.contains(fullPath) else { throw Syntax(msg: "duplicate key") }
            // Value/table conflicts (Rust errors on redefinition).
            if !parents.isEmpty {
                for i in 1 ... parents.count {
                    let prefix = parents.prefix(i).joined(separator: ".")
                    if valuePaths.contains(prefix) { throw Syntax(msg: "redefine") }
                }
            }
            if seenTables.contains(fullPath) || valuePaths.contains(fullPath) {
                throw Syntax(msg: "redefine")
            }
            seenKeys.insert(fullPath)
            valuePaths.insert(fullPath)
            let val = try parseValue(rawVal, lenient: !isKnown(parents: parents, key: key))
            try apply(&snap, parents: parents, key: key, val: val)
        }
        for name in seenTables where tokenTables.contains(name) {
            guard snap.slots[name]?.hasToken == true else {
                throw Syntax(msg: "token table without token")
            }
        }
        return snap
    }

    static func isKnown(parents: [String], key: String) -> Bool {
        if parents.isEmpty {
            return key == "refresh_token" || key == "tenant_id" || key == "region_gtms"
                || tokenTables.contains(key)
        }
        if parents.count == 1, tokenTables.contains(parents[0]) {
            return key == "token" || key == "expires_at"
        }
        return false
    }

    static func apply(_ snap: inout Snapshot, parents: [String], key: String, val: Value) throws {
        if parents.isEmpty {
            switch key {
            case "refresh_token":
                guard case .string = val else { throw Syntax(msg: "refresh_token type") }
                snap.refreshPresent = true
            case "region_gtms":
                guard case .string = val else { throw Syntax(msg: "region_gtms type") }
                snap.regionPresent = true
            case "tenant_id":
                guard case .string = val else { throw Syntax(msg: "tenant_id type") }
            default:
                if tokenTables.contains(key) { throw Syntax(msg: "token table shape") }
            }
            return
        }
        guard parents.count == 1, tokenTables.contains(parents[0]) else { return }
        var slot = snap.slots[parents[0]] ?? Slot()
        switch key {
        case "token":
            guard case .string = val else { throw Syntax(msg: "token type") }
            slot.hasToken = true
        case "expires_at":
            guard case let .int(n) = val else { throw Syntax(msg: "expires_at type") }
            slot.expiresAt = n
        default:
            break
        }
        snap.slots[parents[0]] = slot
    }

    /// Cut at the first `#` outside quotes.
    static func stripComment(_ line: String) -> String {
        var basic = false
        var literal = false
        var escaped = false
        for (i, ch) in line.enumerated() {
            if basic {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" {
                    basic = false
                }
                continue
            }
            if literal {
                if ch == "'" { literal = false }
                continue
            }
            if ch == "\"" { basic = true } else if ch == "'" { literal = true } else if ch == "#" {
                return String(line.prefix(i))
            }
        }
        return line
    }

    /// Index of the first `=` outside quotes.
    static func indexOfEquals(_ line: String) -> String.Index? {
        var basic = false
        var literal = false
        var escaped = false
        var i = line.startIndex
        while i != line.endIndex {
            let ch = line[i]
            if basic {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" {
                    basic = false
                }
            } else if literal {
                if ch == "'" { literal = false }
            } else if ch == "\"" { basic = true } else if ch == "'" { literal = true } else if ch == "=" {
                return i
            }
            i = line.index(after: i)
        }
        return nil
    }

    static func validBare(_ s: String, dotted: Bool) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s {
            let v = ch.unicodeScalars.first!.value
            let ok = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A) || v == 0x5F || v == 0x2D
                || (dotted && v == 0x2E)
            if !ok { return false }
        }
        return true
    }

    /// Bare, quoted, or dotted key → path segments.
    static func parseKey(_ raw: String) throws -> [String] {
        var segments: [String] = []
        var current = ""
        var i = raw.startIndex
        func flush() throws {
            let c = current.trimmingCharacters(in: .whitespaces)
            guard validBare(c, dotted: false) else { throw Syntax(msg: "bad key") }
            segments.append(c)
            current = ""
        }
        while i != raw.endIndex {
            let ch = raw[i]
            if ch == "." {
                try flush()
            } else if ch == "\"" || ch == "'" {
                let quote = ch
                var j = raw.index(after: i)
                var closed = false
                var val = ""
                while j != raw.endIndex {
                    let c = raw[j]
                    if quote == "\"", c == "\\" {
                        let n = raw.index(after: j)
                        guard n != raw.endIndex else { throw Syntax(msg: "bad escape") }
                        val.append(c)
                        val.append(raw[n])
                        j = raw.index(after: n)
                        continue
                    }
                    if c == quote {
                        closed = true
                        j = raw.index(after: j)
                        break
                    }
                    val.append(c)
                    j = raw.index(after: j)
                }
                guard closed else { throw Syntax(msg: "unterminated key") }
                if quote == "\"", !validEscapes(val) { throw Syntax(msg: "bad escape") }
                current += val
                i = j
                continue
            } else {
                current.append(ch)
            }
            i = raw.index(after: i)
        }
        try flush()
        return segments
    }

    static func parseValue(_ raw: String, lenient: Bool) throws -> Value {
        if raw.hasPrefix("\"\"\"") || raw.hasPrefix("'''") {
            throw Syntax(msg: "multiline unsupported")
        }
        if raw.hasPrefix("\"") {
            let (rest, ok) = scanBasic(raw)
            guard ok, rest.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Syntax(msg: "bad string")
            }
            return .string
        }
        if raw.hasPrefix("'") {
            guard let end = raw.dropFirst().firstIndex(of: "'") else {
                throw Syntax(msg: "unterminated string")
            }
            let rest = raw[raw.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty else { throw Syntax(msg: "trailing") }
            guard !containsBareControl(String(raw[raw.index(after: raw.startIndex) ..< end])) else {
                throw Syntax(msg: "control in string")
            }
            return .string
        }
        if raw.hasPrefix("[") || raw.hasPrefix("{") {
            // Arrays/inline tables only occur on ignored (unknown) keys in
            // real files; accept when balanced, else syntax error.
            guard lenient, balanced(raw) else { throw Syntax(msg: "bad composite") }
            return .other
        }
        if let n = parseInt(raw) { return .int(n) }
        if raw == "true" || raw == "false" { return .other }
        if isFloat(raw) || isDatetime(raw) || isIntSyntax(raw) {
            guard lenient else { throw Syntax(msg: "scalar type") }
            return .other
        }
        throw Syntax(msg: "bad scalar")
    }

    /// Raw C0 controls (except tab) and DEL are illegal in TOML strings.
    static func containsBareControl(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: {
            ($0.value < 0x20 && $0.value != 0x09) || $0.value == 0x7F
        })
    }

    /// Scan a basic string from the opening quote; returns (remainder, valid).
    static func scanBasic(_ raw: String) -> (Substring, Bool) {
        var i = raw.index(after: raw.startIndex)
        var body = ""
        while i != raw.endIndex {
            let ch = raw[i]
            if ch == "\\" {
                let n = raw.index(after: i)
                guard n != raw.endIndex else { return (raw[...], false) }
                body.append(ch)
                body.append(raw[n])
                i = raw.index(after: n)
                continue
            }
            if ch == "\"" {
                return (raw[raw.index(after: i)...],
                    validEscapes(body) && !containsBareControl(body))
            }
            if ch == "\n" { return (raw[...], false) }
            body.append(ch)
            i = raw.index(after: i)
        }
        return (raw[...], false)
    }

    static func validEscapes(_ body: String) -> Bool {
        var i = body.startIndex
        while i != body.endIndex {
            let ch = body[i]
            i = body.index(after: i)
            guard ch == "\\" else { continue }
            guard i != body.endIndex else { return false }
            let e = body[i]
            i = body.index(after: i)
            switch e {
            case "\"", "\\", "b", "f", "n", "r", "t":
                break
            case "u":
                guard hexRun(body, &i, 4) else { return false }
            case "U":
                guard hexRun(body, &i, 8) else { return false }
            default:
                return false
            }
        }
        return true
    }

    static func hexRun(_ s: String, _ i: inout String.Index, _ n: Int) -> Bool {
        for _ in 0 ..< n {
            guard i != s.endIndex, s[i].isHexDigit else { return false }
            i = s.index(after: i)
        }
        return true
    }

    static func balanced(_ raw: String) -> Bool {
        var depth = 0
        var basic = false
        var literal = false
        var escaped = false
        for ch in raw {
            if basic {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" {
                    basic = false
                }
                continue
            }
            if literal {
                if ch == "'" { literal = false }
                continue
            }
            switch ch {
            case "\"": basic = true
            case "'": literal = true
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth == 0 { return true }
                if depth < 0 { return false }
            default: break
            }
        }
        return false
    }

    static func parseInt(_ raw: String) -> UInt64? {
        var s = raw
        if s.hasPrefix("+") { s = String(s.dropFirst()) }
        let negative = s.hasPrefix("-")
        if negative { s = String(s.dropFirst()) }
        let digits: String
        let radix: Int
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            digits = String(s.dropFirst(2)); radix = 16
        } else if s.hasPrefix("0o") || s.hasPrefix("0O") {
            digits = String(s.dropFirst(2)); radix = 8
        } else if s.hasPrefix("0b") || s.hasPrefix("0B") {
            digits = String(s.dropFirst(2)); radix = 2
        } else {
            digits = s; radix = 10
        }
        guard !digits.isEmpty, !digits.hasPrefix("_"), !digits.hasSuffix("_"),
            !digits.contains("__")
        else { return nil }
        let stripped = digits.replacingOccurrences(of: "_", with: "")
        guard !stripped.isEmpty, stripped.allSatisfy({ $0.isHexDigit || radix < 16 }) else {
            return nil
        }
        guard let magnitude = UInt64(stripped, radix: radix) else { return nil }
        if negative {
            guard magnitude <= 1 else { return nil }
            // Negative or huge: only 0/-0/-1 could map; Rust u64 fails otherwise.
            return magnitude == 0 ? 0 : nil
        }
        return magnitude
    }

    static func isFloat(_ raw: String) -> Bool {
        let s = raw.hasPrefix("+") || raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
        if s == "inf" || s == "nan" { return true }
        // mantissa [. frac] [exp]; at least one of frac/exp required.
        var i = s.startIndex
        guard i != s.endIndex, s[i].isNumber else { return false }
        while i != s.endIndex, s[i].isNumber || s[i] == "_" { i = s.index(after: i) }
        var hasFracOrExp = false
        if i != s.endIndex, s[i] == "." {
            hasFracOrExp = true
            i = s.index(after: i)
            guard i != s.endIndex, s[i].isNumber else { return false }
            while i != s.endIndex, s[i].isNumber || s[i] == "_" { i = s.index(after: i) }
        }
        if i != s.endIndex, s[i] == "e" || s[i] == "E" {
            hasFracOrExp = true
            i = s.index(after: i)
            if i != s.endIndex, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
            guard i != s.endIndex, s[i].isNumber else { return false }
            while i != s.endIndex, s[i].isNumber || s[i] == "_" { i = s.index(after: i) }
        }
        return hasFracOrExp && i == s.endIndex
    }

    /// Valid TOML int shape (value may exceed u64 or be negative —
    /// unknown keys accept those; known keys already took the u64 path).
    static func isIntSyntax(_ raw: String) -> Bool {
        var s = raw
        if s.hasPrefix("+") || s.hasPrefix("-") { s = String(s.dropFirst()) }
        let digits: String
        let allowed: (Character) -> Bool
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            digits = String(s.dropFirst(2)); allowed = { $0.isHexDigit || $0 == "_" }
        } else if s.hasPrefix("0o") || s.hasPrefix("0O") {
            digits = String(s.dropFirst(2)); allowed = { ("0" ... "7").contains($0) || $0 == "_" }
        } else if s.hasPrefix("0b") || s.hasPrefix("0B") {
            digits = String(s.dropFirst(2)); allowed = { $0 == "0" || $0 == "1" || $0 == "_" }
        } else {
            digits = s; allowed = { $0.isNumber || $0 == "_" }
        }
        guard !digits.isEmpty, digits.allSatisfy(allowed),
            !digits.hasPrefix("_"), !digits.hasSuffix("_"), !digits.contains("__")
        else { return false }
        return digits.contains(where: { $0 != "_" })
    }

    static func isDatetime(_ raw: String) -> Bool {
        guard raw.count >= 8 else { return false }
        let prefix8 = String(raw.prefix(8))
        let isDate = prefix8.prefix(4).allSatisfy(\.isNumber)
            && prefix8.dropFirst(4).first == "-"
            && prefix8.dropFirst(5).prefix(2).allSatisfy(\.isNumber)
        let prefix3 = String(raw.prefix(3))
        let isTime = prefix3.prefix(2).allSatisfy(\.isNumber) && prefix3.suffix(1) == ":"
        return isDate || isTime
    }
}
