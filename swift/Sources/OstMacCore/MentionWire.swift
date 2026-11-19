// MentionWire.swift — COMPOSER-B (C1b): broadcast @mention compose entities.
//
// The picker already offers thread people as plain `@Name ` text (the
// send path is untouched). Broadcast specials need wire entities to
// notify: `@channel` / `@team` / `@everyone` resolve here (pure,
// unit-tested) to official mention spans + a `properties.mentions`
// JSON-string entity (ECHO-FIX: raw arrays are dropped at write).
// Person mentions need member MRIs the composer cannot mint, so they
// stay plain text and never appear here (documented limit, reported
// in the lane REPORT).
import Foundation

/// One resolved broadcast mention for the send path (Codable: encoded
/// straight into the `mentions_json` FFI param).
public struct WireMentionRef: Sendable, Equatable, Codable {
    /// Literal token as typed (`@channel`).
    public let token: String
    /// Broadcast identity (`0` — the observed broadcast id).
    public let id: String
    /// Display text (`channel` / `team` / `Everyone`, fixture spellings).
    public let display: String
    /// `mentionType` (`channel` / `team` / `everyone`).
    public let kind: String
    /// Entity `mri` (the conversation id for broadcasts, stamped at the
    /// send wire; empty until stamped — the key is then omitted).
    public let mri: String

    public init(token: String, id: String, display: String, kind: String, mri: String = "") {
        self.token = token
        self.id = id
        self.display = display
        self.kind = kind
        self.mri = mri
    }

    /// Copy with the entity `mri` filled when still empty (a caller-set
    /// mri — future person mentions — always wins).
    public func with(mri: String) -> WireMentionRef {
        guard self.mri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        return WireMentionRef(token: token, id: id, display: display, kind: kind, mri: mri)
    }

    /// JSON array for the `mentions_json` FFI param (never fails: `[]`
    /// on any encoding surprise — a dropped entity beats a failed send).
    public static func json(for refs: [WireMentionRef]) -> String {
        guard !refs.isEmpty else { return "[]" }
        guard let data = try? JSONEncoder().encode(refs),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }
}

/// Broadcast specials offered by the mention picker.
public enum MentionWire {
    public struct Special: Sendable, Equatable {
        public let token: String
        public let ref: WireMentionRef
    }

    public static let channel = Special(
        token: "@channel",
        ref: WireMentionRef(token: "@channel", id: "0", display: "channel", kind: "channel"))
    public static let team = Special(
        token: "@team",
        ref: WireMentionRef(token: "@team", id: "0", display: "team", kind: "team"))
    public static let everyone = Special(
        token: "@everyone",
        ref: WireMentionRef(token: "@everyone", id: "0", display: "Everyone", kind: "everyone"))

    /// Offered specials: team/channel only make sense in channels;
    /// everywhere else only @everyone broadcasts.
    public static func specials(channel: Bool) -> [Special] {
        channel ? [self.channel, self.team, self.everyone] : [self.everyone]
    }

    /// Picker display names for the offered specials
    /// (`channel`, `team`, `Everyone`).
    public static func displays(channel: Bool) -> [String] {
        specials(channel: channel).map(\.ref.display)
    }

    /// True when a picker row name is a broadcast special (rows render a
    /// megaphone instead of a person avatar). One leading `@` is stripped
    /// (`Mentions.bareName` precedent — mined `<at>@Name</at>` text).
    public static func isSpecialDisplay(_ name: String) -> Bool {
        var b = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if b.hasPrefix("@") { b.removeFirst() }
        return b == "channel" || b == "team" || b == "everyone"
    }

    /// Resolve whole-token specials in `body` to wire refs, in first-
    /// appearance order, deduped. Same bounds as the Rust substitution
    /// (start/whitespace/punctuation edges, case-insensitive), so Swift
    /// and Rust agree on what tags — only offered kinds resolve, so a
    /// typed `@channel` in a 1:1 stays plain text like before.
    public static func resolve(in body: String, channel: Bool) -> [WireMentionRef] {
        let offered = specials(channel: channel).sorted { $0.token.count > $1.token.count }
        let lower = body.lowercased()
        var out: [WireMentionRef] = []
        var seen: Set<String> = []
        var searchFrom = lower.startIndex
        // Walk `@` hits; each hit tries the offered tokens longest-first.
        while let at = lower[searchFrom...].firstIndex(of: "@") {
            var hit: Special?
            for s in offered where lower[at...].hasPrefix(s.token) {
                hit = s
                break
            }
            if let hit {
                let end = lower.index(at, offsetBy: hit.token.count)
                let prevOK: Bool = {
                    guard at != lower.startIndex else { return true }
                    let c = lower[lower.index(before: at)]
                    return !c.isLetter && !c.isNumber && c != "_"
                }()
                let nextOK: Bool = {
                    guard end != lower.endIndex else { return true }
                    let c = lower[end]
                    return !c.isLetter && !c.isNumber && c != "_"
                }()
                if prevOK, nextOK, !seen.contains(hit.token) {
                    seen.insert(hit.token)
                    out.append(hit.ref)
                }
                searchFrom = end
            } else {
                searchFrom = lower.index(after: at)
            }
        }
        return out
    }
}
