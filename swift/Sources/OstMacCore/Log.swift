// Log.swift — NOLOAD: unified-log channels + friendly network errors.
//
// Read after the fact (zsh's builtin `log` shadows the tool; use the
// full path): /usr/bin/log show --last 30m --predicate
//   'subsystem == "dev.ostmac.OstMac" AND category == "network"'
//
// Subsystem = the bundle id; categories: network (one line per HTTP
// request from core: method, path template, status, ms), store (disk
// snapshot load/save durations) and launch (section time-to-content).
//
// Privacy: nothing user-identifying is ever interpolated. Path
// templates have every id-like segment replaced by `{id}` and the query
// dropped BEFORE they reach the logger, so they are logged `.public`;
// numbers (status, ms, counts) are public; free text (error strings
// from core carry URLs + response bodies) is `.private`. Tokens,
// message text, names and emails are never passed in at all.
import COstMac
import Foundation
import os

public enum Log {
    public static let subsystem = AppIdentity.bundleID
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let launch = Logger(subsystem: subsystem, category: "launch")
    /// §106 (SENDFIX): own-send lifecycle + open-chat delivery path
    /// (phase, route, ms, counts only — never text, names or ids).
    public static let send = Logger(subsystem: subsystem, category: "send")
    /// FIXPACK F2: pinned-message source outcomes (reason class only —
    /// never ids, names or message text).
    public static let pins = Logger(subsystem: subsystem, category: "pins")
    /// HWACCEL: one line per video codec session (hw, codec, path, size).
    public static let media = Logger(subsystem: subsystem, category: "media")

    /// Milliseconds since `start` (DispatchTime uptime).
    public static func ms(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    /// Route core's per-request observer (ost §77) into the network
    /// category. Idempotent (core keeps the first install).
    public static func installCoreObserver() {
        ostmac_set_request_log { method, url, status, ms in
            guard let method, let url else { return }
            Log.request(method: String(cString: method), url: String(cString: url),
                        status: Int(status), ms: Int(ms))
        }
    }

    /// Section time-to-content (launch category).
    public static func content(_ section: String, ms: Int, cached: Bool) {
        launch.info("content \(section, privacy: .public) \(ms, privacy: .public)ms source=\(cached ? "cache" : "network", privacy: .public)")
    }

    /// One HTTP request observed by core (network category). `url` is
    /// reduced to a redacted path template here — never logged raw.
    public static func request(method: String, url: String, status: Int, ms: Int) {
        let path = pathTemplate(url)
        if status >= 400 || status == 0 {
            network.error("\(method, privacy: .public) \(path, privacy: .public) status=\(status, privacy: .public) \(ms, privacy: .public)ms")
        } else {
            // Notice, not info: info lines are memory-only unless a fault
            // flushes them, so `log show` found nothing after the fact
            // (CHATTABS). Notice is persisted and shown by default.
            network.notice("\(method, privacy: .public) \(path, privacy: .public) status=\(status, privacy: .public) \(ms, privacy: .public)ms")
        }
    }

    /// Host + path with ids redacted, query/fragment dropped:
    /// `https://graph.microsoft.com/v1.0/teams/1a2b…/channels?x=1` →
    /// `graph.microsoft.com/v1.0/teams/{id}/channels`. Any segment that
    /// is not a plain lowercase-ish word (digits, `@`, `:`, `%`, `=`,
    /// long tokens) counts as an id.
    public static func pathTemplate(_ url: String) -> String {
        var s = Substring(url)
        if let r = s.range(of: "://") { s = s[r.upperBound...] }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = s[..<q] }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard let host = parts.first else { return "" }
        // Everything after a drive path segment (`root:`, `items/<id>:`)
        // is user content (folder / file names).
        var tainted = false
        let rest = parts.dropFirst().map { seg -> String in
            if tainted { return "{id}" }
            if seg.hasSuffix(":") { tainted = true; return "{id}" }
            return isPlainWord(seg) ? String(seg) : "{id}"
        }
        return ([String(host)] + rest).joined(separator: "/")
    }

    static func isPlainWord(_ seg: Substring) -> Bool {
        if seg.isEmpty { return true }
        if seg.count > 32 { return false }
        // API versions (`v1.0`, `v2`) are the one digit-bearing word.
        if seg.first == "v", seg.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }), seg.count > 1 {
            return true
        }
        // ASCII letters + `$ . - _ ( )` only (`$value`, `delta()`); any
        // digit, `@`, `%`, `=`, `'` or non-ASCII marks an id / name.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_$()")
        return seg.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// User-facing wording for network failures (5xx, timeouts, offline,
/// throttling). Display-only: callers that branch on raw status text
/// keep the raw string; this maps it at the last step before the UI.
public enum FriendlyError {
    public static func message(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("timed out") || s.contains("timeout") || s.contains("deadline has elapsed") {
            return "Teams took too long to respond. Try again."
        }
        if s.contains("dns error") || s.contains("connection refused") || s.contains("network is unreachable")
            || s.contains("not connected to the internet") || s.contains("tcp connect error")
            || s.contains("error sending request") || s.contains("connection reset") {
            return "Can\u{2019}t reach Microsoft Teams. Check your connection."
        }
        if let code = httpStatus(in: raw) {
            if code == 429 { return "Teams is busy right now. Try again in a moment." }
            if (500...599).contains(code) {
                return "Teams is having trouble right now (\(code)). Try again in a moment."
            }
        }
        return raw
    }

    public static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return message(m) }
        return message(String(describing: error))
    }

    /// First `HTTP nnn` status in a core error string, if any.
    public static func httpStatus(in raw: String) -> Int? {
        guard let r = raw.range(of: "HTTP ") else { return nil }
        let digits = raw[r.upperBound...].prefix(3)
        guard digits.count == 3, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}
