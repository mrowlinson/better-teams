// ContactStore.swift — contact hover/full card state: a name→person
// directory learned from rosters and directory hits, and a card cache
// with in-flight dedupe. Loads run detached (blocking Graph reads).
import Foundation

// MARK: - Directory (name → person)

/// Maps display names to people. Most surfaces only carry a name
/// (message senders, 1:1 chat titles), so ids are learned from anything
/// that carries both (rosters, directory hits, MRI resolves). A name
/// seen with two different ids is ambiguous and never resolves.
@MainActor
public final class ContactDirectory {
    public typealias Searcher = @Sendable (String) throws -> [TeamMember]

    private var byName: [String: ContactRef] = [:]
    private var ambiguous: Set<String> = []
    /// Names already searched (hit or miss) — one directory query per
    /// name per session.
    private var searched: Set<String> = []
    private var searching: [String: Task<ContactRef?, Never>] = [:]
    private let searcher: Searcher?

    /// `searcher` resolves an unknown name (exact, unique display-name
    /// match); nil disables network resolution (tests, demo).
    public nonisolated init(searcher: Searcher? = nil) {
        self.searcher = searcher
    }

    /// Production directory search (core people search).
    public nonisolated static func liveSearcher() -> Searcher {
        { name in try RustCore.peopleSearch(query: name, limit: 5).people }
    }

    public func learn(name: String, userID: String?, email: String?) {
        let ref = ContactRef(name: name, userID: userID, email: email)
        guard ref.graphKey != nil else { return }
        let k = Self.norm(name)
        guard !k.isEmpty, !ambiguous.contains(k) else { return }
        if let old = byName[k], old.graphKey?.lowercased() != ref.graphKey?.lowercased() {
            // Same name, different person: keep neither.
            if old.userID != nil, ref.userID != nil {
                byName[k] = nil
                ambiguous.insert(k)
            }
            return
        }
        byName[k] = ref
    }

    public func learn(_ members: [TeamMember]) {
        for m in members { learn(name: m.displayName, userID: m.userId, email: m.email) }
    }

    public func learn(_ members: [ChatMember]) {
        for m in members { learn(name: m.displayName, userID: m.userId ?? m.mri, email: m.email) }
    }

    /// Known person for a name (sync; no network).
    public func ref(named name: String) -> ContactRef? { byName[Self.norm(name)] }

    /// A ref with an id when one is known, else the name-only ref.
    public func enrich(_ ref: ContactRef) -> ContactRef {
        ref.graphKey != nil ? ref : (self.ref(named: ref.name) ?? ref)
    }

    /// Known person, else one directory search (exact unique match).
    public func resolve(name: String) async -> ContactRef? {
        let k = Self.norm(name)
        if let hit = byName[k] { return hit }
        guard let searcher, !k.isEmpty, !ambiguous.contains(k) else { return nil }
        if let running = searching[k] { return await running.value }
        guard !searched.contains(k) else { return nil }
        searched.insert(k)
        let task = Task.blocking(priority: .utility) { () -> ContactRef? in
            guard let people = try? searcher(name) else { return nil }
            let exact = people.filter { Self.norm($0.displayName) == k }
            guard exact.count == 1, let m = exact.first else { return nil }
            let ref = ContactRef(name: m.displayName, userID: m.userId, email: m.email)
            return ref.graphKey == nil ? nil : ref
        }
        searching[k] = task
        let found = await task.value
        searching[k] = nil
        if let found { learn(name: found.name, userID: found.userID, email: found.email) }
        return found.flatMap { _ in byName[k] }
    }

    nonisolated static func norm(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Card store

/// Cards by person key. `load` dedupes in-flight work and serves cached
/// cards for `ttl`; failures keep any stale card (non-critical path).
@MainActor
public final class ContactStore: ObservableObject {
    public typealias Loader = @Sendable (ContactRef, _ org: Bool) throws -> ContactCard

    public enum Phase: Equatable { case idle, loading, failed(String) }

    @Published public private(set) var cards: [String: ContactCard] = [:]
    @Published public private(set) var phases: [String: Phase] = [:]
    /// Keys with a forced reload running (a card's Retry).
    @Published public private(set) var retrying: Set<String> = []

    public let directory: ContactDirectory
    /// App presence cache: fills the card when Graph presence is denied.
    public weak var presence: PresenceStore?
    /// Seconds a loaded card is served without reloading.
    public var ttl: TimeInterval = 600
    public var now: () -> Date = { Date() }

    private let loader: Loader
    private var loadedAt: [String: Date] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    public nonisolated init(directory: ContactDirectory = ContactDirectory(),
                            loader: @escaping Loader = { try ContactReads.card(for: $0, org: $1) }) {
        self.directory = directory
        self.loader = loader
    }

    /// Demo store: canned people, abstract org, no network.
    public nonisolated static func demo() -> ContactStore {
        let dir = ContactDirectory()
        let store = ContactStore(directory: dir) { ref, org in
            guard let card = ContactDemo.card(for: ref, org: org) else {
                throw CoreCallError.failed("contact: not in the demo directory")
            }
            return card
        }
        return store
    }

    /// Demo: seed the directory with the canned people (+ "Me").
    public func seedDemo() {
        for r in ContactDemo.refs { directory.learn(name: r.name, userID: r.userID, email: r.email) }
        directory.learn(name: "Me", userID: "demo-u-me", email: "me@example.com")
    }

    public func card(for ref: ContactRef) -> ContactCard? {
        cards[directory.enrich(ref).key]
    }

    /// True while a forced reload of this person's card is running.
    public func isRetrying(_ ref: ContactRef) -> Bool { retrying.contains(directory.enrich(ref).key) }

    public func phase(for ref: ContactRef) -> Phase {
        phases[directory.enrich(ref).key] ?? .idle
    }

    /// Presence for the card: the app's presence cache (unified
    /// presence: availability, note, out of office) for that id, else
    /// the card's own Graph presence when the tenant allows it.
    public func presence(for ref: ContactRef) -> ContactPresence? {
        let r = directory.enrich(ref)
        let id = cards[r.key]?.profile.id ?? r.userID
        if let id, let peer = presence?.peers[id] ?? presence?.peers[id.lowercased()] {
            return peer.contactPresence
        }
        return cards[r.key]?.presence
    }

    /// Fetch (and keep polling) one person's presence for an open card;
    /// the card redraws when it lands.
    private func refreshPresence(_ id: String) {
        guard let presence, presence.batchFetcher != nil else { return }
        Task { [weak self] in
            await presence.refreshPeers(ids: [id])
            self?.objectWillChange.send()
        }
    }

    /// Load (or refresh) a card. `org` also fetches manager chain and
    /// direct reports (full card). Resolves name-only refs first.
    /// `force` skips the cache (a card's Retry for a failed section).
    public func load(_ ref: ContactRef, org: Bool = false, force: Bool = false) {
        let initial = directory.enrich(ref)
        let key = initial.key
        if !force, let card = cards[key], let at = loadedAt[key], now().timeIntervalSince(at) < ttl,
           card.orgLoaded || !org {
            return
        }
        if inFlight[key] != nil { return }
        if force { retrying.insert(key) }
        if cards[key] == nil { phases[key] = .loading }
        let loader = self.loader
        inFlight[key] = Task { [weak self] in
            guard let self else { return }
            var target = initial
            if target.graphKey == nil, let found = await self.directory.resolve(name: target.name) {
                target = found
            }
            guard target.graphKey != nil || ContactDemo.isDemoName(target.name) else {
                self.finish(key: key, result: .failure(CoreCallError.failed("No directory entry for this name.")))
                return
            }
            let resolved = target
            let result = await Task.blocking(priority: .userInitiated) {
                Result { try loader(resolved, org) }
            }.value
            self.finish(key: key, alias: resolved.key, result: result)
        }
    }

    private func finish(key: String, alias: String? = nil, result: Result<ContactCard, Error>) {
        inFlight[key] = nil
        retrying.remove(key)
        switch result {
        case .success(var card):
            // Keep org rows from an earlier full load when this was a hover load.
            if !card.orgLoaded, let old = cards[key], old.orgLoaded {
                card.managers = old.managers; card.reports = old.reports; card.orgLoaded = true
                if card.sharedFiles == nil { card.sharedFiles = old.sharedFiles }
                if card.about == nil { card.about = old.about }
                if card.linkedIn == nil { card.linkedIn = old.linkedIn }
                // Sections only the full load reads keep their earlier failure.
                for part in [ContactCardPart.organization, .files, .about] {
                    if let why = old.failures[part] { card.failures[part] = why }
                }
            }
            if let name = card.profile.displayName {
                directory.learn(name: name, userID: card.profile.id, email: card.profile.email)
            }
            for k in Set([key, alias ?? key, card.ref.key]) {
                cards[k] = card
                loadedAt[k] = now()
                phases[k] = .idle
            }
            refreshPresence(card.profile.id)
        case .failure(let error):
            let message: String
            if case CoreCallError.failed(let m) = error { message = m } else { message = String(describing: error) }
            if cards[key] == nil { phases[key] = .failed(Self.friendly(message)) } else { phases[key] = .idle }
        }
    }

    /// Error text without codes/URLs (Graph failure strings carry both).
    static func friendly(_ message: String) -> String {
        if message.contains("HTTP 404") { return "This person isn't in the directory." }
        if message.contains("HTTP 403") || message.contains("401") { return "The directory didn't allow this lookup." }
        if message.hasPrefix("No directory entry") { return message }
        return "Couldn't load this contact."
    }

    /// Adopt a card without core (tests, previews).
    public func adopt(_ card: ContactCard, for ref: ContactRef) {
        let k = directory.enrich(ref).key
        cards[k] = card
        cards[card.ref.key] = card
        loadedAt[k] = now()
        phases[k] = .idle
    }
}

// MARK: - Demo directory

/// Canned people for --demo (same ids as DemoData/DemoChatRoster).
/// Abstract org: the owner leads; Megan manages Tom and Ava.
public enum ContactDemo {
    struct Entry {
        let profile: ContactProfile
        let presence: ContactPresence
        let managerID: String?
        let timeZone: String
    }

    static let entries: [Entry] = [
        Entry(profile: ContactProfile(
                id: "demo-u-me", displayName: DemoData.ownerDisplayName, jobTitle: "Head of Product",
                department: "Product", officeLocation: "London · 4th floor", mail: "me@example.com",
                businessPhones: ["+44 20 7946 0100"], city: "London", country: "United Kingdom",
                companyName: "Example Ltd", imAddresses: ["me@example.com"]),
              presence: ContactPresence(availability: "Available", activity: "Available"),
              managerID: nil, timeZone: "Europe/London"),
        Entry(profile: ContactProfile(
                id: "demo-u-megan", displayName: "Megan Harper", jobTitle: "Engineering Manager",
                department: "Engineering", officeLocation: "London · 3rd floor", mail: "megan@example.com",
                businessPhones: ["+44 20 7946 0142"], mobilePhone: "+44 7700 900142", city: "London",
                country: "United Kingdom", companyName: "Example Ltd", imAddresses: ["megan@example.com"]),
              presence: ContactPresence(availability: "Away", activity: "Away",
                                        statusMessage: "Back after lunch"),
              managerID: "demo-u-me", timeZone: "Europe/London"),
        Entry(profile: ContactProfile(
                id: "demo-u-tom", displayName: "Tom Becker", jobTitle: "Senior Software Engineer",
                department: "Engineering", officeLocation: "Berlin · Remote", mail: "tom@example.com",
                businessPhones: ["+49 30 901820"], city: "Berlin", country: "Germany",
                companyName: "Example Ltd", imAddresses: ["tom@example.com"]),
              presence: ContactPresence(availability: "Away", activity: "OutOfOffice", outOfOffice: true,
                                        outOfOfficeNote: "Out until Monday. Megan Harper covers releases."),
              managerID: "demo-u-megan", timeZone: "Europe/Berlin"),
        Entry(profile: ContactProfile(
                id: "demo-u-ava", displayName: "Ava Lindqvist", jobTitle: "Product Designer",
                department: "Design", officeLocation: "Stockholm · 2nd floor", mail: "ava@example.com",
                businessPhones: ["+46 8 555 0199"], city: "Stockholm", country: "Sweden",
                companyName: "Example Ltd", imAddresses: ["ava@example.com"]),
              presence: ContactPresence(availability: "Busy", activity: "InACall",
                                        statusMessage: "Heads down on the launch review until 3 pm"),
              managerID: "demo-u-megan", timeZone: "Europe/Stockholm"),
    ]

    static func entry(for ref: ContactRef) -> Entry? {
        if let id = ref.userID, let e = entries.first(where: { $0.profile.id == id }) { return e }
        let n = ContactDirectory.norm(ref.name)
        if n == "me" { return entries.first }
        return entries.first { ContactDirectory.norm($0.profile.displayName ?? "") == n }
    }

    static func isDemoName(_ name: String) -> Bool { entry(for: ContactRef(name: name)) != nil }

    /// IANA zone for a demo person (local-time line).
    public static func timeZone(for id: String) -> TimeZone? {
        entries.first { $0.profile.id == id }.flatMap { TimeZone(identifier: $0.timeZone) }
    }

    static func person(_ e: Entry) -> ContactPerson {
        ContactPerson(id: e.profile.id, displayName: e.profile.displayName ?? "", jobTitle: e.profile.jobTitle,
                      mail: e.profile.mail)
    }

    /// Demo calendar: 9–5:30 in their zone; busy people until the next
    /// full hour, everyone else free until then.
    static func schedule(for e: Entry, now: Date) -> ContactSchedule {
        let hour = Calendar(identifier: .gregorian).dateInterval(of: .hour, for: now)?.end ?? now
        let state: ContactSchedule.State = e.presence.outOfOffice ? .outOfOffice
            : e.presence.availability == "Busy" ? .busy : .free
        return ContactSchedule(timeZoneID: e.timeZone, workStart: "09:00:00", workEnd: "17:30:00",
                               state: state, until: state == .outOfOffice ? nil : hour)
    }

    /// Demo shared files (example.com links, never real documents).
    static func files(for e: Entry) -> [ContactSharedFile] {
        guard e.profile.id != "demo-u-me" else { return [] }
        let base = e.profile.id.replacingOccurrences(of: "demo-u-", with: "")
        let day: TimeInterval = 86_400
        let anchor = Date(timeIntervalSince1970: 1_790_000_000)
        return [
            ContactSharedFile(id: base + "-plan", title: "Launch plan.docx", type: "Word",
                              webURL: URL(string: "https://example.com/files/\(base)/launch-plan"),
                              sharedAt: anchor),
            ContactSharedFile(id: base + "-metrics", title: "Weekly metrics.xlsx", type: "Excel",
                              webURL: URL(string: "https://example.com/files/\(base)/metrics"),
                              sharedAt: anchor.addingTimeInterval(-3 * day)),
        ]
    }

    /// Demo Profile tab (fixed dates, generic skills).
    static func about(for e: Entry) -> ContactAbout? {
        let hired = Date(timeIntervalSince1970: 1_600_000_000)
        switch e.profile.id {
        case "demo-u-megan":
            return ContactAbout(aboutMe: "Leads the platform team. Happy to talk release planning any time.",
                                hireDate: hired, skills: ["Release planning", "Swift", "Hiring"],
                                schools: ["University of Leeds"], responsibilities: ["Platform roadmap"])
        case "demo-u-ava":
            return ContactAbout(hireDate: hired.addingTimeInterval(400 * 86_400),
                                skills: ["Interaction design", "Prototyping"], interests: ["Typography"])
        default: return nil
        }
    }

    public static func card(for ref: ContactRef, org: Bool, now: Date = Date()) -> ContactCard? {
        guard let e = entry(for: ref) else { return nil }
        var card = ContactCard(profile: e.profile, presence: e.presence)
        card.schedule = schedule(for: e, now: now)
        if org {
            card.sharedFiles = files(for: e)
            card.about = about(for: e)
            card.linkedIn = ContactLinkedIn(bound: false)
            var chain: [ContactPerson] = []
            var next = e.managerID
            while let id = next, let m = entries.first(where: { $0.profile.id == id }) {
                chain.append(person(m)); next = m.managerID
            }
            card.managers = chain
            card.reports = entries.filter { $0.managerID == e.profile.id }.map(person)
                .sorted { $0.displayName < $1.displayName }
            card.orgLoaded = true
        }
        return card
    }

    /// Every demo person (directory seeding).
    public static var refs: [ContactRef] {
        entries.map { ContactRef(name: $0.profile.displayName ?? "", userID: $0.profile.id, email: $0.profile.mail) }
    }
}
