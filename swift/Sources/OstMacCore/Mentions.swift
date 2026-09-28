// Mentions.swift — om-rules lane: Teams mention parsing + matching.
//
// Port of TeamsNotifier's TeamsCore/Mentions.swift, adapted for OstMac:
// - Live path is content-only: the core ships unstripped `raw` HTML but
//   no `properties` dict, so the authoritative properties parse is kept
//   for future use while matching runs on markup mining.
// - Besides TeamsNotifier's `<span itemtype="...Mention">` fallback, the
//   miner also reads `<at …>Name</at>` tags (the shape OstMac observes on
//   the wire; see MessageRender.mentions(fromRaw:)).
import Foundation

/// One parsed mention: positional index plus whatever identity the markup
/// carried (content-mined mentions have no MRI — display-name matching
/// covers them via the name-backup gate).
public struct Mention: Sendable, Equatable {
    /// Positional index matching the content span's itemid.
    public let id: String
    public let mri: String?
    public let mentionType: String?
    public let displayName: String

    public init(id: String, mri: String?, mentionType: String? = nil, displayName: String) {
        self.id = id
        self.mri = mri
        self.mentionType = mentionType
        self.displayName = displayName
    }
}

public enum Mentions {
    // MARK: Parse

    /// Never throws: bad data yields an empty list.
    public static func parse(properties: Any?, content: String) -> [Mention] {
        let fromProps = parseFromProperties(properties)
        if !fromProps.isEmpty { return fromProps }
        return parse(content: content)
    }

    /// Content-only parse (the OstMac live path): Mention spans plus
    /// `<at>` tags. Never throws.
    public static func parse(content: String) -> [Mention] {
        parseFromContent(content) + parseAtTags(content)
    }

    /// `properties` may be a dict or a JSON string of one; `mentions` may be
    /// an array or a JSON string of one (both shapes observed on the wire).
    public static func parseFromProperties(_ properties: Any?) -> [Mention] {
        guard let record = jsonRecord(properties),
              let raw = jsonArray(record["mentions"])
        else { return [] }
        var out: [Mention] = []
        for entry in raw {
            guard let item = entry as? [String: Any] else { continue }
            let id: String?
            if let s = item["itemid"] as? String { id = s } else if let n = item["itemid"] as? Int { id = String(n) } else if let n = item["itemid"] as? Double { id = String(Int(n)) } else { id = nil }
            guard let id else { continue }
            out.append(Mention(
                id: id,
                mri: item["mri"] as? String,
                mentionType: (item["mentionType"] as? String) ?? (item["type"] as? String),
                displayName: (item["displayName"] as? String) ?? ""
            ))
        }
        return out
    }

    /// Content-span fallback. Matches `<span ... itemtype="...Mention..."
    /// ... itemid="N">Name</span>` regardless of attribute order.
    public static func parseFromContent(_ content: String) -> [Mention] {
        var out: [Mention] = []
        let pattern = #"<span\b[^>]*itemtype=["'][^"']*Mention[^"']*["'][^>]*>(.*?)</span>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = content as NSString
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range(at: 0))
            guard let idRe = try? NSRegularExpression(pattern: #"itemid=["']([^"']*)["']"#, options: .caseInsensitive),
                  let idM = idRe.firstMatch(in: whole, range: NSRange(location: 0, length: (whole as NSString).length))
            else { continue }
            let id = (whole as NSString).substring(with: idM.range(at: 1))
            let inner = ns.substring(with: m.range(at: 1))
            out.append(Mention(id: id, mri: nil, displayName: stripInline(inner)))
        }
        return out
    }

    /// `<at …>Name</at>` fallback (the shape OstMac observes on the wire).
    /// The id attribute is optional here: matching only reads mri/type/
    /// displayName, so a missing id synthesizes a positional one rather
    /// than dropping a real mention.
    public static func parseAtTags(_ content: String) -> [Mention] {
        var out: [Mention] = []
        let pattern = #"<at\b[^>]*>(.*?)</at>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = content as NSString
        let matches = re.matches(in: content, range: NSRange(location: 0, length: ns.length))
        for (i, m) in matches.enumerated() {
            let whole = ns.substring(with: m.range(at: 0))
            var id: String?
            if let idRe = try? NSRegularExpression(pattern: #"\bid=["']([^"']*)["']"#, options: .caseInsensitive),
               let idM = idRe.firstMatch(in: whole, range: NSRange(location: 0, length: (whole as NSString).length))
            {
                id = (whole as NSString).substring(with: idM.range(at: 1))
            }
            let inner = ns.substring(with: m.range(at: 1))
            out.append(Mention(id: id ?? "at-\(i)", mri: nil, displayName: stripInline(inner)))
        }
        return out
    }

    // MARK: Classify

    /// Owner mention? MRI match preferred (config carries owner MRI,
    /// learned from the Graph /me id as `8:orgid:{oid}`). Display-name
    /// match is the backup when protocol data lacks an MRI
    /// (content-mining path), unless `matchByName` is false (IDs only).
    /// Mined inner text often carries the `@` prefix (`<at>@Me</at>`,
    /// the shape core ships) — one leading `@` is stripped before the
    /// name compare, so `@Me` matches owner `Me`.
    /// Live Mention spans sometimes split one person across adjacent
    /// parts (`Rowlinson,` + `Michael`): when no single part matches,
    /// contiguous name-eligible runs are compared token-wise,
    /// order-insensitive (`Last, First` vs `First Last`) and
    /// punctuation-tolerant, so the full owner name still hits.
    public static func mentionsOwner(_ mentions: [Mention], ownerMRI: String?, ownerDisplayName: String, matchByName: Bool = true) -> Bool {
        let wantName = ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var eligibleRuns: [[String]?] = []
        eligibleRuns.reserveCapacity(mentions.count)
        for m in mentions {
            if let ownerMRI, !ownerMRI.isEmpty, let mri = m.mri, !mri.isEmpty {
                if mri.caseInsensitiveCompare(ownerMRI) == .orderedSame { return true }
                // MRI present but different: not owner; do not name-match,
                // and break any split-name run (nil = run boundary).
                eligibleRuns.append(nil)
                continue
            }
            if matchByName, !wantName.isEmpty, bareName(m.displayName).lowercased() == wantName {
                return true
            }
            let tokens = matchByName ? nameTokens(m.displayName) : []
            eligibleRuns.append(tokens.isEmpty ? nil : tokens)
        }
        if matchByName {
            let wantTokens = nameTokens(ownerDisplayName)
            if !wantTokens.isEmpty, joinedRunMatches(eligibleRuns, wantTokens: wantTokens) {
                return true
            }
        }
        return false
    }

    /// Lowercased, punctuation-tolerant word tokens for split-name
    /// matching: `@` sigil stripped, commas/periods trimmed per word
    /// (`Rowlinson,` -> `rowlinson`), empties dropped.
    static func nameTokens(_ displayName: String) -> [String] {
        bareName(displayName).lowercased().split(whereSeparator: \.isWhitespace).compactMap { word in
            let t = word.trimmingCharacters(in: .punctuationCharacters)
            return t.isEmpty ? nil : t
        }
    }

    /// True when some contiguous run of per-part token lists covers
    /// exactly the owner tokens (order-insensitive multiset compare,
    /// so `Last, First` spans match a `First Last` owner). Runs are
    /// maximal nil-delimited segments; windows stop at the owner token
    /// count, so unrelated neighboring mentions never join the match.
    static func joinedRunMatches(_ runs: [[String]?], wantTokens: [String]) -> Bool {
        let want = wantTokens.sorted()
        var run: [[String]] = []
        func scan(_ run: [[String]]) -> Bool {
            for start in run.indices {
                var acc: [String] = []
                for parts in run[start...] {
                    acc.append(contentsOf: parts)
                    if acc.count > want.count { break }
                    if acc.count == want.count, acc.sorted() == want { return true }
                }
            }
            return false
        }
        for entry in runs {
            guard let tokens = entry else {
                if !run.isEmpty, scan(run) { return true }
                run = []
                continue
            }
            run.append(tokens)
        }
        return !run.isEmpty && scan(run)
    }

    /// Channel-wide mention? Matches mentionType tag values Teams uses for
    /// @channel/@team blasts, plus display-name spellings as fallback
    /// (one leading `@` stripped, same as the owner gate).
    /// Protocol data varies here; both signals are checked explicitly.
    public static func mentionsChannelOrEveryone(_ mentions: [Mention]) -> Bool {
        for m in mentions {
            if let t = m.mentionType?.lowercased(),
               t == "channel" || t == "everyone" || t == "team" || t == "channelmessage"
            { return true }
            let n = bareName(m.displayName).lowercased()
            if n == "channel" || n == "everyone" || n == "team" { return true }
        }
        return false
    }

    /// Display name for matching: trimmed, one leading `@` stripped
    /// (mined `<at>@Name</at>` inner text carries the sigil; the owner
    /// name never does). Empty stays empty (never matches).
    public static func bareName(_ displayName: String) -> String {
        var n = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasPrefix("@") { n.removeFirst() }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Inline text

    /// Strip tags + decode entities for mention inner text (mirrors
    /// TeamsNotifier HTML.strip; tag stripping reuses MessageRender).
    static func stripInline(_ html: String) -> String {
        decodeEntities(MessageRender.stripTags(html)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var r = s
        let named: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ]
        for (e, c) in named { r = r.replacingOccurrences(of: e, with: c) }
        return decodeNumericEntities(r)
    }

    /// `&#123;` / `&#x1F;` -> scalar, best-effort single pass. Unparseable
    /// sequences pass through untouched.
    static func decodeNumericEntities(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", s[i...].hasPrefix("&#") {
                if let semi = s[i...].firstIndex(of: ";") {
                    let body = s[s.index(i, offsetBy: 2)..<semi]
                    var value: UInt32?
                    if body.hasPrefix("x") || body.hasPrefix("X") {
                        value = UInt32(body.dropFirst(), radix: 16)
                    } else {
                        value = UInt32(body, radix: 10)
                    }
                    if let v = value, let scalar = Unicode.Scalar(v) {
                        out.append(Character(scalar))
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    // MARK: JSON helpers

    static func jsonRecord(_ value: Any?) -> [String: Any]? {
        if let s = value as? String {
            guard let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return nil }
            return o
        }
        return value as? [String: Any]
    }

    static func jsonArray(_ value: Any?) -> [Any]? {
        if let s = value as? String {
            guard let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [Any]
            else { return nil }
            return o
        }
        return value as? [Any]
    }
}

extension RealtimeMessage {
    /// Mentions mined from the unstripped body (Mention spans + `<at>`
    /// tags). The core ships no `properties` dict, so MRI-carrying
    /// properties mentions are unavailable on this path — display-name
    /// matching covers the mined ones via the name-backup gate.
    public var mentions: [Mention] {
        Mentions.parse(content: raw ?? "")
    }
}

extension ChatMessage {
    /// Mentions mined from the unstripped body (same live path as
    /// `RealtimeMessage.mentions`: `MessageInfo.raw` from core, Mention
    /// spans + `<at>` tags, display-name matching). Nil/blank raw (old
    /// payloads, local echoes) yields no mentions — never scan `content`
    /// here (the bubble's `@token` fallback is render-only).
    public var mentions: [Mention] {
        Mentions.parse(content: raw ?? "")
    }

    /// True when this bubble mentions `ownName` (display-name backup;
    /// MRI-carrying properties are unavailable on the live path).
    /// Blank own names never match.
    public func mentionsOwner(ownName: String?) -> Bool {
        guard let own = ownName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !own.isEmpty
        else { return false }
        return Mentions.mentionsOwner(mentions, ownerMRI: nil, ownerDisplayName: own)
    }
}
