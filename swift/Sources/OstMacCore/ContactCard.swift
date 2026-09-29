// ContactCard.swift — contact hover card + full contact card data
// (Graph read-only): people refs, profile/org/presence models, and the
// Graph reads behind them. Blocking reads: call off the main thread.
import Foundation

// MARK: - Person reference

/// Who a name/avatar on screen points at. `userID` is an AAD object id,
/// an orgid MRI or a UPN; `email` is the fallback Graph key. A ref with
/// neither is resolved by display name through the directory.
public struct ContactRef: Hashable, Sendable {
    public let name: String
    public let userID: String?
    public let email: String?

    public init(name: String, userID: String? = nil, email: String? = nil) {
        self.name = name
        let id = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userID = (id?.isEmpty ?? true) ? nil : id.map { Mri.oid(from: $0) ?? $0 }
        let mail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = (mail?.isEmpty ?? true) ? nil : mail
    }

    /// The Graph `/users/{key}` key (object id, else email), if known.
    public var graphKey: String? { userID ?? email }

    /// Stable cache key: the Graph key, else the lowercased name.
    public var key: String { graphKey.map { "id:" + $0.lowercased() } ?? "name:" + name.lowercased() }

    /// Sheet-argument form (`SheetRequest.arg`): name, id, email joined by
    /// U+001F. A bare name decodes as a name-only ref.
    public var encoded: String { [name, userID ?? "", email ?? ""].joined(separator: "\u{1F}") }

    public init?(encoded: String) {
        let parts = encoded.components(separatedBy: "\u{1F}")
        guard let name = parts.first, !name.isEmpty else { return nil }
        self.init(name: name, userID: parts.count > 1 ? parts[1] : nil, email: parts.count > 2 ? parts[2] : nil)
    }
}

// MARK: - Models

/// Graph `user` projection for the card (`ContactReads.profileSelect`).
public struct ContactProfile: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String?
    public var givenName: String?
    public var surname: String?
    public var jobTitle: String?
    public var department: String?
    public var officeLocation: String?
    public var mail: String?
    public var userPrincipalName: String?
    public var businessPhones: [String]?
    public var mobilePhone: String?
    public var city: String?
    public var state: String?
    public var country: String?
    public var companyName: String?
    /// Teams chat (SIP) addresses; the card's "Chat" field.
    public var imAddresses: [String]?

    public init(id: String, displayName: String? = nil, givenName: String? = nil, surname: String? = nil,
                jobTitle: String? = nil, department: String? = nil, officeLocation: String? = nil,
                mail: String? = nil, userPrincipalName: String? = nil, businessPhones: [String]? = nil,
                mobilePhone: String? = nil, city: String? = nil, state: String? = nil,
                country: String? = nil, companyName: String? = nil, imAddresses: [String]? = nil) {
        self.id = id; self.displayName = displayName; self.givenName = givenName; self.surname = surname
        self.jobTitle = jobTitle; self.department = department; self.officeLocation = officeLocation
        self.mail = mail; self.userPrincipalName = userPrincipalName; self.businessPhones = businessPhones
        self.mobilePhone = mobilePhone; self.city = city; self.state = state; self.country = country
        self.companyName = companyName; self.imAddresses = imAddresses
    }

    /// The "Chat" field: the first chat address, else the sign-in name.
    public var chatAddress: String? {
        imAddresses?.lazy.compactMap(\.nonBlank).first ?? userPrincipalName?.nonBlank
    }

    /// Email for display/actions: `mail`, else the UPN when it is an address.
    public var email: String? {
        if let m = mail?.nonBlank { return m }
        if let u = userPrincipalName?.nonBlank, u.contains("@"), !u.contains("#EXT#") { return u }
        return nil
    }

    /// First business phone, else mobile.
    public var workPhone: String? { businessPhones?.lazy.compactMap(\.nonBlank).first }

    /// "City, State, Country" from whichever parts are set.
    public var location: String? {
        let parts = [city, state, country].compactMap { $0?.nonBlank }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "Title · Department" subtitle.
    public var subtitle: String? {
        let parts = [jobTitle, department].compactMap { $0?.nonBlank }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One person in the org chain (manager or direct report).
public struct ContactPerson: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let jobTitle: String?
    public let mail: String?

    public init(id: String, displayName: String, jobTitle: String? = nil, mail: String? = nil) {
        self.id = id; self.displayName = displayName; self.jobTitle = jobTitle; self.mail = mail
    }

    public var ref: ContactRef { ContactRef(name: displayName, userID: id, email: mail) }
}

/// Graph `presence` with the status note (`statusMessage`).
public struct ContactPresence: Sendable, Equatable {
    public let availability: String
    public let activity: String
    /// Plain-text status note (HTML stripped); nil when unset or expired.
    public let statusMessage: String?
    public let outOfOffice: Bool
    /// Automatic-reply text while out of office (unified presence).
    public let outOfOfficeNote: String?

    public init(availability: String, activity: String, statusMessage: String? = nil, outOfOffice: Bool = false,
                outOfOfficeNote: String? = nil) {
        self.availability = availability; self.activity = activity
        self.statusMessage = statusMessage; self.outOfOffice = outOfOffice
        self.outOfOfficeNote = outOfOfficeNote
    }

    public var status: PresenceStatus? { PresenceStatus.from(availability: availability) }
    public var label: String { PresenceFormat.label(availability: availability, activity: activity) }
}

/// A card section whose read can fail on its own (§GRAPH2).
public enum ContactCardPart: String, Sendable, Hashable, CaseIterable {
    /// Manager chain + direct reports.
    case organization
    /// Zone, working hours, free/busy.
    case schedule
    /// Files shared with the signed-in user.
    case files
    /// Profile tab (about me, skills…).
    case about
}

/// Everything one card shows. Org fields are empty until `orgLoaded`.
public struct ContactCard: Sendable, Equatable {
    public var profile: ContactProfile
    public var presence: ContactPresence?
    /// Nearest manager first.
    public var managers: [ContactPerson]
    public var reports: [ContactPerson]
    public var orgLoaded: Bool
    /// Zone, working hours and free/busy now (calendar free/busy query);
    /// nil when the calendar didn't answer for this person.
    public var schedule: ContactSchedule?
    /// Files this person shared with the signed-in user (full card only;
    /// nil = not loaded or not readable, [] = none).
    public var sharedFiles: [ContactSharedFile]?
    /// Profile tab (about me, birthday, skills…; full card only).
    public var about: ContactAbout?
    /// LinkedIn tab (persona card service; full card only).
    public var linkedIn: ContactLinkedIn?
    /// Sections whose read failed, with UI text (no URL, code or id). A
    /// part listed here is unknown, not empty: the card shows the reason
    /// and a Retry instead of an absent section (FAIL is not ABSENCE).
    public var failures: [ContactCardPart: String]

    public init(profile: ContactProfile, presence: ContactPresence? = nil, managers: [ContactPerson] = [],
                reports: [ContactPerson] = [], orgLoaded: Bool = false, schedule: ContactSchedule? = nil,
                sharedFiles: [ContactSharedFile]? = nil, about: ContactAbout? = nil,
                linkedIn: ContactLinkedIn? = nil, failures: [ContactCardPart: String] = [:]) {
        self.profile = profile; self.presence = presence; self.managers = managers
        self.reports = reports; self.orgLoaded = orgLoaded
        self.schedule = schedule; self.sharedFiles = sharedFiles
        self.about = about; self.linkedIn = linkedIn; self.failures = failures
    }

    public var ref: ContactRef {
        ContactRef(name: profile.displayName ?? "", userID: profile.id, email: profile.email)
    }
}

// MARK: - Graph reads

/// Graph reads for the card: GET `/users/{key}` ($select), `/presence`,
/// `/manager` (walked up), `/directReports`. Pure parsers are separate
/// so tests pin them without network.
public enum ContactReads {
    public static let profileSelect = [
        "id", "displayName", "givenName", "surname", "jobTitle", "department", "officeLocation",
        "mail", "userPrincipalName", "businessPhones", "mobilePhone", "city", "state", "country",
        "companyName", "imAddresses",
    ].joined(separator: ",")
    static let personSelect = "id,displayName,jobTitle,mail"
    /// Manager chain depth (Teams shows a handful of levels).
    public static let managerDepth = 5
    static let reportLimit = 50

    /// Graph path segment for a user key (oid / UPN / email).
    static func userPath(_ key: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return "/users/" + (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)
    }

    // MARK: parsers

    static func parseProfile(_ data: Data) throws -> ContactProfile {
        try JSONDecoder().decode(ContactProfile.self, from: data)
    }

    private struct PersonPayload: Decodable {
        let id: String
        let displayName: String?
        let jobTitle: String?
        let mail: String?
    }

    private struct PeoplePayload: Decodable { let value: [PersonPayload] }

    static func parsePerson(_ data: Data) -> ContactPerson? {
        guard let p = try? JSONDecoder().decode(PersonPayload.self, from: data) else { return nil }
        return ContactPerson(id: p.id, displayName: p.displayName ?? "", jobTitle: p.jobTitle?.nonBlank,
                             mail: p.mail?.nonBlank)
    }

    /// A directory list page. Throws when the answer is not a people list
    /// (an unreadable answer must not read as "no people").
    static func decodePeople(_ data: Data) throws -> [ContactPerson] {
        let page = try JSONDecoder().decode(PeoplePayload.self, from: data)
        return page.value.compactMap { p in
            guard let name = p.displayName?.nonBlank else { return nil }
            return ContactPerson(id: p.id, displayName: name, jobTitle: p.jobTitle?.nonBlank, mail: p.mail?.nonBlank)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private struct PresencePayload: Decodable {
        struct Note: Decodable {
            struct Body: Decodable { let content: String? }
            let message: Body?
            let expiryDateTime: Stamp?
        }
        struct Stamp: Decodable { let dateTime: String? }
        struct OOF: Decodable { let isOutOfOffice: Bool? }
        let availability: String
        let activity: String
        let statusMessage: Note?
        let outOfOfficeSettings: OOF?
    }

    static func parsePresence(_ data: Data, now: Date = Date()) -> ContactPresence? {
        guard let p = try? JSONDecoder().decode(PresencePayload.self, from: data) else { return nil }
        var note = p.statusMessage?.message?.content.map(plainText)?.nonBlank
        if let raw = p.statusMessage?.expiryDateTime?.dateTime, let expiry = graphDate(raw), expiry < now {
            note = nil
        }
        return ContactPresence(availability: p.availability, activity: p.activity, statusMessage: note,
                               outOfOffice: p.outOfOfficeSettings?.isOutOfOffice ?? false)
    }

    /// Graph `dateTimeTimeZone.dateTime` (UTC, fractional seconds optional).
    static func graphDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// Status notes are HTML; keep the text.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// UI text for a failed section read: no URL, status code or id (Graph
    /// failure strings carry all three).
    static func failureReason(_ error: Error) -> String {
        let raw: String = if case CoreCallError.failed(let m) = error { m } else { String(describing: error) }
        if raw.contains("HTTP 403") || raw.contains("401") { return "The directory didn\u{2019}t allow this." }
        if raw.contains("HTTP 404") { return "The directory has no entry for this." }
        if raw.contains("HTTP 5") { return "Teams had a problem answering this." }
        if error is DecodingError || raw.contains("unreadable") { return "Teams answered in a form this app can\u{2019}t read." }
        return "Couldn\u{2019}t reach Teams for this."
    }

    // MARK: fetches (blocking)

    /// The card for one user. Profile is required (throws); presence and
    /// org are best-effort (a denied read leaves that part empty).
    static func card(key: String, org: Bool, token: String, http: any ReadFetcher,
                     post: ContactExtrasReads.Poster? = nil, lokiToken: String? = nil,
                     presence: ((String) -> ContactPresence?)? = nil,
                     now: Date = Date()) throws -> ContactCard {
        let base = userPath(key)
        let profile = try parseProfile(
            CoreReads.graphGET(base + "?$select=" + profileSelect, code: "contact", token: token, http: http))
        let userBase = userPath(profile.id)
        var card = ContactCard(profile: profile)
        // GRAPHSWEEP: no Graph `/users/{id}/presence` (Presence.Read.All is
        // not on the Teams token — it was a guaranteed 403 per session);
        // presence comes from the Teams presence service (`presence`).
        if let presence { card.presence = presence(profile.id) }
        if org {
            let (chain, chainError) = managerChain(of: profile.id, token: token, http: http)
            card.managers = chain
            var orgError = chainError
            do {
                card.reports = try decodePeople(CoreReads.graphGET(
                    userBase + "/directReports?$select=\(personSelect)&$top=\(reportLimit)",
                    code: "contact", token: token, http: http))
            } catch {
                orgError = orgError ?? error
            }
            if let orgError { card.failures[.organization] = failureReason(orgError) }
            card.orgLoaded = true
        }
        if let mail = profile.email {
            if let post {
                do { card.schedule = try ContactExtrasReads.schedule(mail: mail, token: token, post: post, now: now) }
                catch { card.failures[.schedule] = failureReason(error) }
            }
            if org {
                do { card.sharedFiles = try ContactExtrasReads.files(mail: mail, token: token, http: http) }
                catch { card.failures[.files] = failureReason(error) }
            }
        }
        if org {
            do { card.about = try ContactExtrasReads.about(id: profile.id, token: token, http: http) }
            catch { card.failures[.about] = failureReason(error) }
            if let lokiToken {
                card.linkedIn = ContactExtrasReads.linkedIn(id: profile.id, mail: profile.email ?? "",
                                                            token: lokiToken, http: http)
            }
        }
        return card
    }

    /// Walks `/manager` up to `managerDepth` levels. A 404 (no manager) or
    /// an empty answer ends the chain (top of the org); any other failure
    /// ends it too but is returned so the card can say the chain is
    /// unknown rather than showing it as complete.
    static func managerChain(of id: String, token: String,
                             http: any ReadFetcher) -> (chain: [ContactPerson], error: Error?) {
        var chain: [ContactPerson] = []
        var current = id
        while chain.count < managerDepth {
            let data: Data
            do {
                data = try CoreReads.graphGET(
                    userPath(current) + "/manager?$select=\(personSelect)", code: "contact", token: token, http: http)
            } catch {
                if case CoreCallError.failed(let m) = error, m.contains("HTTP 404") { break }
                return (chain, error)
            }
            guard let m = parsePerson(data), !m.displayName.isEmpty,
                  !chain.contains(where: { $0.id == m.id }), m.id != id
            else { break }
            chain.append(m)
            current = m.id
        }
        return (chain, nil)
    }

    /// Production entry point (keychain token, URLSession).
    public static func card(for ref: ContactRef, org: Bool) throws -> ContactCard {
        guard let key = ref.graphKey else { throw CoreCallError.failed("contact: no id for this person") }
        let ctx = try CoreReads.production()
        let token = try CoreReads.graphToken(profile: CoreLocal.activeProfileID(), code: "contact", ctx: ctx)
        // LinkedIn lookup rides the persona card service's own token
        // (best-effort: no token = no LinkedIn tab data).
        let loki = org ? (try? RustCore.tokenForScope(profile: CoreLocal.activeProfileID(),
                                                           scopes: ContactExtrasReads.lokiResource))?.token : nil
        return try card(key: key, org: org, token: token, http: ctx.http, post: ContactExtrasReads.livePoster,
                        lokiToken: loki, presence: { id in
                            // Best-effort like the org sections: the card's dot also reads the app's
                            // presence cache, so a failed read here leaves only the note/OOO unset.
                            try? SyncBridge.run { try await UnifiedPresence.fetch(ids: [id])[id] }
                        })
    }
}

// MARK: - Token claims (local decode only)

/// Reads a JWT's payload claims locally (no network, no verification).
/// Used for the token's expiry; never log the token or its claims.
enum GraphTokenClaims {
    static func decode(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

/// Tiny lock-protected Bool (static flags touched off-main).
final class ContactLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return raw }
        set { lock.lock(); raw = newValue; lock.unlock() }
    }
}

extension String {
    /// Nil when empty/whitespace.
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
