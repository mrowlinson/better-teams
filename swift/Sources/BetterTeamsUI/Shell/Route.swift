// Route.swift — one grammar for deep links, launch flags, and evidence
// (UI-SPEC §11.3). Parsing is generic (path segments + query); each
// section provider interprets its own segments.
//
//   chat/<id>?tab=files&message=<mid>   teams/<team>/<channel>?tab=posts
//   app/<appID>   call?state=prejoin    search?q=<q>&scope=all
//   signin?state=code   evidence/control   <any>?state=empty|loading|error
import Foundation

public struct Route: Equatable, Sendable {
    public var path: [String]
    public var query: [String: String]

    public init(path: [String], query: [String: String] = [:]) {
        self.path = path
        self.query = query
    }

    /// Parses `a/b?x=1&y=2` (also accepts a `betterteams://` prefix).
    /// Nil for an empty path.
    public init?(string raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("betterteams://") { s.removeFirst("betterteams://".count) }
        let parts = s.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map { $0.split(separator: "/").map { Self.decode(String($0)) } } ?? []
        guard !path.isEmpty else { return nil }
        var q: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let k = kv.first, !k.isEmpty else { continue }
                q[Self.decode(String(k))] = kv.count > 1 ? Self.decode(String(kv[1])) : ""
            }
        }
        self.path = path
        self.query = q
    }

    private static func decode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    public var head: String { path.first ?? "" }

    /// Segments after the head.
    public var tail: [String] { Array(path.dropFirst()) }

    /// The section this route lands in (nil for non-section routes:
    /// search, settings, signin, evidence).
    public var section: SectionID? {
        switch head {
        case "activity": return .activity
        case "chat": return .chat
        case "teams": return .teams
        case "calendar": return .calendar
        case "calls": return .calls
        case "files": return .files
        case "apps": return .apps
        case "call": return .call
        case "app":
            guard let id = tail.first else { return .apps }
            if let n = NativeAppID(rawValue: id) { return .native(n) }
            return .web(id)
        default: return nil
        }
    }

    /// `state=empty|loading|error` forced pane state (demo only).
    public var forcedState: ForcedPaneState? {
        query["state"].flatMap(ForcedPaneState.init(rawValue:))
    }

    /// Evidence connection state (demo only): `connection=` wins; a
    /// forced `state=error` is the offline failure, except in a web app,
    /// whose load error is that app's own ("Couldn't Load", §7.3), never
    /// the window's connection.
    public var forcedConnection: String? {
        if let c = query["connection"] { return c }
        guard forcedState == .error else { return nil }
        if case .web? = section { return nil }
        return "offline"
    }

    /// `inspector=1|<segment>`.
    public var inspector: String? { query["inspector"] }

    public var description: String {
        let p = path.joined(separator: "/")
        guard !query.isEmpty else { return p }
        return p + "?" + query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
    }
}

/// Evidence-forced pane state (R18 states on demand).
public enum ForcedPaneState: String, Sendable {
    case empty, loading, error
}
