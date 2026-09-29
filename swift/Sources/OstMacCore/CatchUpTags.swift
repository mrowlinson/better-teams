// CatchUpTags.swift — CATCHTABS lane: Teams tag mentions (@tag) that
// include the signed-in user.
//
// The Graph tag walk (`ownerTagNames`: /me/joinedTeams, /teams/{id}/tags,
// /teams/{id}/tags/{tagId}/members) stays as a pure, injectable helper
// but production never runs it: the Teams web token lacks TeamworkTag.Read
// (live 403, GRAPHSWEEP). `load` reads the user's tags from the Teams CSA
// service instead (`ostmac_catchup_tags`, §GRAPH2). That read is wired
// but not yet proven live (needs a signed-in run), so every failure
// comes back as a `Failure` the Catch Up window shows with a Retry --
// never as an empty tag set.
import Foundation

public enum CatchUpTags {
    public static let maxTeams = 25
    public static let maxTagsPerTeam = 50
    public static let cacheTTL: TimeInterval = 24 * 3600
    static let cacheKey = "catchup.tags.cache"

    /// A tag mention names one of the user's tags. Person mentions carry
    /// an MRI; a tag arrives as `mentionType` "tag" or as a bare name.
    public static func mentionsTag(_ mentions: [Mention], ownerTags: Set<String>) -> Bool {
        guard !ownerTags.isEmpty else { return false }
        for m in mentions {
            if let t = m.mentionType?.lowercased(), t != "tag", t != "tagmention" { continue }
            if let mri = m.mri, !mri.isEmpty, m.mentionType?.lowercased() != "tag" { continue }
            let n = Mentions.bareName(m.displayName).lowercased()
            if !n.isEmpty, ownerTags.contains(n) { return true }
        }
        return false
    }

    // MARK: Graph payloads

    struct TeamsPayload: Decodable {
        struct Team: Decodable { let id: String }
        let value: [Team]
    }

    struct TagsPayload: Decodable {
        struct Tag: Decodable {
            let id: String
            let displayName: String?
        }
        let value: [Tag]
    }

    struct MembersPayload: Decodable {
        struct Member: Decodable { let userId: String? }
        let value: [Member]
    }

    /// Names (lowercased) of the tags whose members include `userID`
    /// (the Graph /me id). `get` performs one read-only Graph GET for a
    /// path (tests pass a fixture reader).
    /// Nil when the team list itself can't be read (nothing is cached).
    static func ownerTagNames(userID: String, get: (String) throws -> Data) -> Set<String>? {
        let me = userID.lowercased()
        guard !me.isEmpty,
              let teams = try? JSONDecoder().decode(TeamsPayload.self, from: get("/me/joinedTeams?$select=id"))
        else { return nil }
        var names = Set<String>()
        for team in teams.value.prefix(maxTeams) {
            guard let tags = try? JSONDecoder().decode(TagsPayload.self, from: get("/teams/\(team.id)/tags")) else { continue }
            for tag in tags.value.prefix(maxTagsPerTeam) {
                guard let name = tag.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                      let members = try? JSONDecoder().decode(
                          MembersPayload.self, from: get("/teams/\(team.id)/tags/\(tag.id)/members"))
                else { continue }
                if members.value.contains(where: { $0.userId?.lowercased() == me }) { names.insert(name.lowercased()) }
            }
        }
        return names
    }

    /// Graph object id from an owner MRI (`8:orgid:{oid}`).
    public static func userID(fromMRI mri: String?) -> String? {
        guard let mri, let r = mri.range(of: "8:orgid:") else { return nil }
        let id = String(mri[r.upperBound...])
        return id.isEmpty ? nil : id
    }

    // MARK: Cache

    struct Cached: Codable {
        var userID: String
        var names: [String]
        var fetched: Date
    }

    public static func cached(userID: String, defaults: UserDefaults, now: Date = Date()) -> Set<String>? {
        guard let data = defaults.data(forKey: cacheKey),
              let c = try? JSONDecoder().decode(Cached.self, from: data),
              c.userID == userID, now.timeIntervalSince(c.fetched) < cacheTTL
        else { return nil }
        return Set(c.names)
    }

    static func store(_ names: Set<String>, userID: String, defaults: UserDefaults, now: Date = Date()) {
        let c = Cached(userID: userID, names: names.sorted(), fetched: now)
        if let data = try? JSONEncoder().encode(c) { defaults.set(data, forKey: cacheKey) }
    }

    /// A tag read that did not produce a tag list. `message` is UI text:
    /// no URL, status code or id.
    public struct Failure: Error, Equatable, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    /// UI text for a failed tag read.
    static func failureMessage(for error: Error) -> String {
        let raw: String = if case CoreCallError.failed(let m) = error { m } else { String(describing: error) }
        let lower = raw.lowercased()
        if lower.contains("403") || lower.contains("forbidden") { return "Teams didn\u{2019}t allow reading your tags." }
        if lower.contains("401") || lower.contains("login") || lower.contains("expired") || lower.contains("no skype token") {
            return "Sign in again to read your tags."
        }
        if lower.contains("unrecognised") || lower.contains("parse") { return "Teams sent tags in a form this app can\u{2019}t read yet." }
        return "Couldn\u{2019}t read your tags from Teams."
    }

    /// Production read: the cached set (a day) or one CSA read, stored on
    /// success. An empty set means Teams answered "no tags"; a failed or
    /// unreadable read is `.failure`, never `[]`.
    public static func load(
        userID: String, defaults: UserDefaults = .standard, now: Date = Date(),
        fetch: () throws -> [String] = { try RustCore.catchUpTags() }
    ) -> Result<Set<String>, Failure> {
        if let hit = cached(userID: userID, defaults: defaults, now: now) { return .success(hit) }
        do {
            let names = Set(try fetch().map { $0.lowercased() })
            store(names, userID: userID, defaults: defaults, now: now)
            return .success(names)
        } catch {
            return .failure(Failure(message: failureMessage(for: error)))
        }
    }
}
