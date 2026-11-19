// PhoneSettings.swift — PHONEUI lane: Teams Phone surfaces (dial pad,
// voicemail, call forwarding, delegates).
//
// Probe baseline (tmp/pstnprobe/REPORT.md): this tenant carries SPE_E3
// only — no MCOEV (Phone System), no MCOPSTN, no E.164 DID. Every live
// calling path is therefore disabled-with-reason until PSTN-TRIAL proves
// a licence + DID. Trial-only rule: zero live writes from this lane;
// the demo fakes below are the only interactive path.
//
// Graph map (tmp/phoneui/ENDPOINTS.md): delegates ride the beta call
// delegation APIs (wired here behind the CalendarGraph seam, stub-tested,
// never called live without a licence + CallDelegation scope). Forwarding
// and voicemail have NO delegated Graph endpoint — Teams client /
// Set-CsUserCallingSettings only — so they are demo-fake only.
//
// Trial update (PSTN-TRIAL R0, tmp/pstntrial/licences.json): the trial
// tenant carries ENTERPRISEPREMIUM with MCOEV + MCOMEETADV provisioned
// (Success) and NO MCOPSTN* plan. Dial stays disabled — now with the
// calling-plan reason (PhoneLicence.callingPlanNote) instead of only the
// generic licence reason. Voicemail/forwarding stay demo-only (no
// delegated endpoint); delegates stay scope-gated (CallDelegation.*).
import Foundation

// MARK: - Endpoint map (paths + scopes; host lives in CalendarGraph)

/// Teams Phone Graph surface. The beta delegation endpoints are the only
/// ones wired (PhoneGraph below); forwarding/voicemail/PSTN setup have no
/// delegated Graph shape and stay demo-only until PSTN-TRIAL says otherwise.
public enum PhoneGraphEndpoints {
    /// GET list / POST add own delegates (CallDelegation.Read / ReadWrite).
    public static let delegates = "/me/communications/callSettings/delegates"
    /// GET people who made me their delegate (CallDelegation.Read).
    public static let delegators = "/me/communications/callSettings/delegators"
    /// DELETE one delegate (CallDelegation.ReadWrite).
    public static func delegate(id: String) -> String { delegates + "/" + id }
    public static let delegatesReadScope = "CallDelegation.Read"
    public static let delegatesWriteScope = "CallDelegation.ReadWrite"
}

// MARK: - Dial pad (pure logic; views + guards drive this)

/// Dial-pad entry rules: E.164-ish digits, `+` only leading, `*`/`#` kept
/// for service codes, 15 digits max (E.164). Formatting chars are ignored.
public enum DialPad {
    public static let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]

    /// Canonical entry: kept characters in order, at most one leading `+`.
    public static func normalize(_ raw: String) -> String {
        var out = ""
        var digits = 0
        for ch in raw {
            if ch == "+" {
                if out.isEmpty { out.append(ch) }
            } else if ch.isNumber {
                guard digits < 15 else { continue }
                out.append(ch)
                digits += 1
            } else if ch == "*" || ch == "#" {
                out.append(ch)
            }
        }
        return out
    }

    /// Dialable: at least 3 dial characters (`*`/`#` alone never dial).
    public static func isDialable(_ entry: String) -> Bool {
        let n = normalize(entry)
        return n.filter(\.isNumber).count >= 3
    }
}

// MARK: - Forwarding

/// Forwarding target (Teams client names; admin path is
/// Set-CsUserCallingSettings).
public enum CallForwardingMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case voicemail
    case singleTarget
    case myDelegates
    case group

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: "Off"
        case .voicemail: "Voicemail"
        case .singleTarget: "Forward to number"
        case .myDelegates: "My delegates"
        case .group: "Call group"
        }
    }

    /// True when the mode needs a dialable target number.
    public var needsTarget: Bool { self == .singleTarget || self == .group }
}

/// Own forwarding choice. No Graph write shape exists — demo fake only.
public struct CallForwardingSettings: Equatable, Sendable {
    public var mode: CallForwardingMode
    public var target: String
    public var simultaneousRing: Bool

    public init(mode: CallForwardingMode = .off, target: String = "", simultaneousRing: Bool = false) {
        self.mode = mode
        self.target = target
        self.simultaneousRing = simultaneousRing
    }

    public static let off = CallForwardingSettings()

    /// Nil = valid; otherwise the user-facing problem.
    public func validate() -> String? {
        guard mode.needsTarget else { return nil }
        guard DialPad.isDialable(target) else { return "Enter a phone number to forward to." }
        return nil
    }

    public func summary() -> String {
        switch mode {
        case .off: "Off"
        case .voicemail: "Forward to voicemail"
        case .singleTarget: "Forward to \(DialPad.normalize(target))"
        case .myDelegates: "Ring my delegates"
        case .group: "Ring call group"
        }
    }
}

// MARK: - Voicemail

public enum VoicemailGreeting: String, CaseIterable, Identifiable, Sendable {
    case standard
    case custom
    case outOfOffice

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: "Standard"
        case .custom: "Custom recording"
        case .outOfOffice: "Out of office"
        }
    }
}

/// Greeting choice. No delegated Graph read/write — demo fake only.
public struct VoicemailSettings: Equatable, Sendable {
    public var greeting: VoicemailGreeting
    public var greetingText: String

    public init(greeting: VoicemailGreeting = .standard, greetingText: String = "") {
        self.greeting = greeting
        self.greetingText = greetingText
    }
}

/// One demo mailbox message (no Graph voicemail read exists).
public struct VoicemailMessage: Equatable, Identifiable, Sendable {
    public let id: String
    public let callerName: String
    public let at: Date
    public let durationSecs: Int
    public var isRead: Bool
    public let transcript: String?

    public init(id: String, callerName: String, at: Date, durationSecs: Int, isRead: Bool = false,
                transcript: String? = nil) {
        self.id = id
        self.callerName = callerName
        self.at = at
        self.durationSecs = durationSecs
        self.isRead = isRead
        self.transcript = transcript
    }
}

// MARK: - Delegates

/// One call delegate (Graph `delegationSettings` shape, beta).
public struct CallDelegate: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let email: String?

    public init(id: String, displayName: String, email: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.email = email
    }

    static func parse(_ obj: [String: Any]) -> CallDelegate? {
        guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
        let name = (obj["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let email = (obj["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CallDelegate(id: id, displayName: name, email: email?.isEmpty == true ? nil : email)
    }

    static func parseList(_ data: Data) -> [CallDelegate]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["value"] as? [[String: Any]]
        else { return nil }
        return rows.compactMap(parse)
    }
}

// MARK: - Licence capability (PSTN-TRIAL R1)

/// Teams Phone capability parsed from Graph licence shapes
/// (`subscribedSkus` part numbers + `licenseDetails` service plans).
/// Plans decide — a part number alone never implies capability.
public struct PhoneLicence: Equatable, Sendable {
    public var hasPhoneSystem: Bool
    public var hasCallingPlan: Bool

    public init(hasPhoneSystem: Bool = false, hasCallingPlan: Bool = false) {
        self.hasPhoneSystem = hasPhoneSystem
        self.hasCallingPlan = hasCallingPlan
    }

    public static let none = PhoneLicence()

    /// Phone System = MCOEV plan; Calling Plan = any MCOPSTN* plan
    /// (MCOPSTN1/2/5/6 domestic/international variants).
    public static func parse(servicePlanNames: [String]) -> PhoneLicence {
        PhoneLicence(hasPhoneSystem: servicePlanNames.contains("MCOEV"),
                     hasCallingPlan: servicePlanNames.contains { $0.hasPrefix("MCOPSTN") })
    }

    public var canDialPSTN: Bool { hasPhoneSystem && hasCallingPlan }

    public static let callingPlanReason =
        "Teams Phone is on this account, but outbound calling needs a Calling Plan — Teams-to-Teams only for now."

    /// Non-nil only for the trial shape (Phone System without a calling
    /// plan): the dial pad stays disabled, with this reason under the
    /// generic licence reason. Nil covers both other cases — no licence
    /// (generic reason already shown) and full capability (no reason).
    public var callingPlanNote: String? {
        guard hasPhoneSystem, !hasCallingPlan else { return nil }
        return Self.callingPlanReason
    }
}

// MARK: - API seam (DemoChannelMembers precedent)

/// Every live-calling control without a proven licence throws
/// `needsLicence` with the user-facing reason.
public enum PhoneAPIError: Error, Equatable {
    case needsLicence(String)
    case failed(String)

    public var message: String {
        switch self {
        case .needsLicence(let r): r
        case .failed(let m): m
        }
    }
}

/// Phone settings source. Sync throws (the blocking-FFI shape); stores
/// run these off-main via `Task.blocking`.
public protocol PhoneAPI: Sendable {
    func forwarding() throws -> CallForwardingSettings
    func saveForwarding(_ settings: CallForwardingSettings) throws
    func voicemailSettings() throws -> VoicemailSettings
    func saveVoicemail(_ settings: VoicemailSettings) throws
    func voicemails() throws -> [VoicemailMessage]
    func markHeard(id: String) throws
    func delegates() throws -> [CallDelegate]
    func addDelegate(email: String) throws -> CallDelegate
    func removeDelegate(id: String) throws
}

/// Live source: no licence, no scopes, no DID — every call throws the
/// licence reason. PhoneGraph (below) holds the real endpoint shapes for
/// PSTN-TRIAL; nothing here calls it until then.
public struct UnavailablePhoneAPI: PhoneAPI {
    public init() {}
    public func forwarding() throws -> CallForwardingSettings { throw PhoneAPIError.needsLicence(PhoneStore.liveReason) }
    public func saveForwarding(_ settings: CallForwardingSettings) throws {
        throw PhoneAPIError.needsLicence(PhoneStore.liveReason)
    }
    public func voicemailSettings() throws -> VoicemailSettings { throw PhoneAPIError.needsLicence(PhoneStore.liveReason) }
    public func saveVoicemail(_ settings: VoicemailSettings) throws {
        throw PhoneAPIError.needsLicence(PhoneStore.liveReason)
    }
    public func voicemails() throws -> [VoicemailMessage] { throw PhoneAPIError.needsLicence(PhoneStore.liveReason) }
    public func markHeard(id: String) throws { throw PhoneAPIError.needsLicence(PhoneStore.liveReason) }
    public func delegates() throws -> [CallDelegate] { throw PhoneAPIError.needsLicence(PhoneStore.liveReason) }
    public func addDelegate(email: String) throws -> CallDelegate {
        throw PhoneAPIError.needsLicence(PhoneStore.liveReason)
    }
    public func removeDelegate(id: String) throws { throw PhoneAPIError.needsLicence(PhoneStore.liveReason) }
}

/// Seeded in-memory fake (demo). Western demo names (repo rule).
/// @unchecked: every read/write of state holds `lock`.
public final class DemoPhoneAPI: PhoneAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var forwardingValue = CallForwardingSettings(mode: .voicemail)
    private var voicemailValue = VoicemailSettings(greeting: .standard)
    private var messages: [VoicemailMessage]
    private var people: [CallDelegate]
    private var counter = 0

    public init() {
        let base = Date(timeIntervalSince1970: 1_764_000_000)
        messages = [
            VoicemailMessage(id: "demo-vm-1", callerName: "Megan Harper", at: base,
                             durationSecs: 42, transcript: "Hi, calling about the site visit — call me back when you can."),
            VoicemailMessage(id: "demo-vm-2", callerName: "Tom Becker", at: base - 3600 * 5,
                             durationSecs: 18, isRead: true),
            VoicemailMessage(id: "demo-vm-3", callerName: "Ava Lindqvist", at: base - 86400,
                             durationSecs: 65, transcript: "Quick update on the schedule — nothing urgent."),
        ]
        people = [
            CallDelegate(id: "demo-d-1", displayName: "Laura Bennett", email: "laura@example.com"),
            CallDelegate(id: "demo-d-2", displayName: "James Carter", email: "james@example.com"),
        ]
    }

    public func forwarding() throws -> CallForwardingSettings {
        lock.lock(); defer { lock.unlock() }
        return forwardingValue
    }
    public func saveForwarding(_ settings: CallForwardingSettings) throws {
        lock.lock(); defer { lock.unlock() }
        forwardingValue = settings
    }
    public func voicemailSettings() throws -> VoicemailSettings {
        lock.lock(); defer { lock.unlock() }
        return voicemailValue
    }
    public func saveVoicemail(_ settings: VoicemailSettings) throws {
        lock.lock(); defer { lock.unlock() }
        voicemailValue = settings
    }
    public func voicemails() throws -> [VoicemailMessage] {
        lock.lock(); defer { lock.unlock() }
        return messages.sorted { $0.at > $1.at }
    }
    public func markHeard(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].isRead = true
    }
    public func delegates() throws -> [CallDelegate] {
        lock.lock(); defer { lock.unlock() }
        return people
    }
    public func addDelegate(email: String) throws -> CallDelegate {
        lock.lock(); defer { lock.unlock() }
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        counter += 1
        let name = clean.split(separator: "@").first.map(String.init) ?? clean
        let d = CallDelegate(id: "demo-d-added-\(counter)", displayName: name, email: clean)
        people.append(d)
        return d
    }
    public func removeDelegate(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        people.removeAll { $0.id == id }
    }
}

// MARK: - Graph client (delegates only; CalendarGraph seam, stub-tested)

/// Beta call-delegation reads/writes. Never constructed live in this lane
/// (no licence, no CallDelegation scope — allowlist status `blocked`);
/// PSTN-TRIAL owns first live proof.
public struct PhoneGraph: Sendable {
    var graph: CalendarGraph

    init(http: any CalendarHTTP, token: @escaping @Sendable () throws -> String) {
        graph = CalendarGraph(http: http, token: token)
    }

    /// Signed-in profile, URLSession transport (PSTN-TRIAL only).
    public static func production() -> PhoneGraph {
        PhoneGraph(http: URLSessionCalendarHTTP()) {
            try CoreReads.graphToken(
                profile: CoreLocal.activeProfileID(), code: "phone", ctx: CoreReads.production())
        }
    }

    /// List own delegates (GET beta delegates; unknown shape → nil).
    public func fetchDelegates() throws -> [CallDelegate] {
        let data = try mapped { try graph.request("GET", CalendarGraph.betaBase + PhoneGraphEndpoints.delegates) }
        guard let list = CallDelegate.parseList(data) else {
            throw CoreCallError.failed("phone: unreadable delegates reply")
        }
        return list
    }

    /// Add a delegate by email (POST beta delegates).
    @discardableResult
    public func addDelegate(email: String) throws -> CallDelegate {
        let data = try mapped {
            try graph.request("POST", CalendarGraph.betaBase + PhoneGraphEndpoints.delegates,
                              json: ["email": email])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = CallDelegate.parse(obj)
        else {
            throw CoreCallError.failed("phone: unreadable add-delegate reply")
        }
        return d
    }

    /// Remove a delegate (DELETE beta delegates/{id}).
    public func removeDelegate(id: String) throws {
        try mapped {
            try graph.request("DELETE", CalendarGraph.betaBase + PhoneGraphEndpoints.delegate(id: CalendarGraph.encode(id)))
        }
    }

    /// A 403 is the missing-scope capability message (the Teams token has
    /// no CallDelegation.* — pstnprobe + graph-allowlist pin this).
    @discardableResult
    private func mapped(_ work: () throws -> Data) throws -> Data {
        do {
            return try work()
        } catch let e as CoreCallError {
            if case .failed(let msg) = e, msg.contains(" 403") {
                throw CoreCallError.failed("phone: not allowed — CallDelegation.Read is not granted.")
            }
            throw e
        }
    }
}

// MARK: - Store (Calls section source)

/// Phone settings + mailbox + delegates (MainActor; blocking calls run
/// off-main via the sync API seam, same contract as `CoreReads`).
@MainActor
public final class PhoneStore: ObservableObject {
    /// Shown on every live control that cannot work without a licence.
    public static let liveReason = "Calling needs a Teams Phone licence — ask your admin."

    @Published public private(set) var forwarding = CallForwardingSettings.off
    @Published public private(set) var voicemail = VoicemailSettings()
    @Published public private(set) var messages: [VoicemailMessage] = []
    @Published public private(set) var people: [CallDelegate] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    /// Trial-proven capability (PSTN-TRIAL R1). Default `.none` preserves
    /// the generic-reason behavior until a lane sets the proven shape.
    @Published public private(set) var licence = PhoneLicence.none

    public func setLicence(_ l: PhoneLicence) { licence = l }

    public let isDemo: Bool
    private let api: any PhoneAPI
    /// Park/queue source (PHONE-PLUS R1): demo fake or licence-gated
    /// unavailable, same pattern as `api`.
    private let parkApi: any ParkQueueAPI

    /// Nonisolated so views can take a default in their (nonisolated)
    /// inits (PresenceStore precedent); all members stay main-actor-isolated.
    public nonisolated init(demo: Bool, api: (any PhoneAPI)? = nil,
                            parkApi: (any ParkQueueAPI)? = nil) {
        isDemo = demo
        self.api = api ?? (demo ? DemoPhoneAPI() : UnavailablePhoneAPI())
        self.parkApi = parkApi ?? (demo ? DemoParkQueueAPI() : UnavailableParkQueueAPI())
    }

    public var unreadCount: Int { messages.filter { !$0.isRead }.count }

    /// Test seam: adopt demo state without I/O.
    public func adopt(forwarding: CallForwardingSettings, voicemail: VoicemailSettings,
                      messages: [VoicemailMessage], people: [CallDelegate]) {
        self.forwarding = forwarding
        self.voicemail = voicemail
        self.messages = messages
        self.people = people
        error = nil
    }

    // MARK: park + queues (PHONE-PLUS R1)

    @Published public private(set) var parkedCalls: [ParkedCall] = []
    @Published public private(set) var queues: [CallQueue] = []
    @Published public private(set) var attendants: [AutoAttendant] = []
    /// refreshPlus gate (see method; independent of `loading`).
    private var plusLoading = false

    /// Test seam: adopt park/queue demo state without I/O.
    public func adoptPlus(parked: [ParkedCall], queues: [CallQueue], attendants: [AutoAttendant]) {
        self.parkedCalls = parked
        self.queues = queues
        self.attendants = attendants
        error = nil
    }

    /// Refresh park/queue demo state. Live never fetches (no licence, no
    /// policy, no Graph shape) — views show the reasons instead.
    /// Own gate (not the shared `loading` flag: `refresh()` may already
    /// hold it when the sheet appears and both must complete).
    public func refreshPlus() {
        guard isDemo, !plusLoading else { return }
        plusLoading = true
        let parkApi = self.parkApi
        Task {
            do {
                let p = try await Task.blocking { try parkApi.parked() }.value
                let q = try await Task.blocking { try parkApi.queues() }.value
                let a = try await Task.blocking { try parkApi.attendants() }.value
                self.parkedCalls = p
                self.queues = q
                self.attendants = a
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
            self.plusLoading = false
        }
    }

    public func parkCall(name: String) {
        guard isDemo else { return }
        let parkApi = self.parkApi
        Task {
            do {
                let c = try await Task.blocking { try parkApi.park(name: name) }.value
                self.parkedCalls.insert(c, at: 0)
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    public func pickupCall(code: String) {
        guard isDemo else { return }
        let parkApi = self.parkApi
        Task {
            do {
                let c = try await Task.blocking { try parkApi.pickup(code: code) }.value
                self.parkedCalls.removeAll { $0.id == c.id }
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    /// Refresh from the source. Live never fetches (no licence) — views
    /// show `liveReason` instead of calling this.
    public func refresh() {
        guard isDemo, !loading else { return }
        loading = true
        let api = self.api
        Task {
            do {
                let fwd = try await Task.blocking { try api.forwarding() }.value
                let vm = try await Task.blocking { try api.voicemailSettings() }.value
                let msgs = try await Task.blocking { try api.voicemails() }.value
                let folks = try await Task.blocking { try api.delegates() }.value
                self.forwarding = fwd
                self.voicemail = vm
                self.messages = msgs
                self.people = folks
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
            self.loading = false
        }
    }

    public func saveForwarding(_ settings: CallForwardingSettings) {
        guard isDemo else { return }
        let api = self.api
        Task {
            do {
                try await Task.blocking { try api.saveForwarding(settings) }.value
                self.forwarding = settings
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    public func saveVoicemail(_ settings: VoicemailSettings) {
        guard isDemo else { return }
        let api = self.api
        Task {
            do {
                try await Task.blocking { try api.saveVoicemail(settings) }.value
                self.voicemail = settings
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    public func markHeard(id: String) {
        guard isDemo else { return }
        let api = self.api
        Task {
            do {
                try await Task.blocking { try api.markHeard(id: id) }.value
                if let i = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[i].isRead = true
                }
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    public func addDelegate(email: String) {
        guard isDemo else { return }
        let api = self.api
        Task {
            do {
                let d = try await Task.blocking { try api.addDelegate(email: email) }.value
                self.people.append(d)
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    public func removeDelegate(id: String) {
        guard isDemo else { return }
        let api = self.api
        Task {
            do {
                try await Task.blocking { try api.removeDelegate(id: id) }.value
                self.people.removeAll { $0.id == id }
                self.error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}

// MARK: - Call park / pickup (PHONE-PLUS R1)
//
// Endpoint map (R0, docs): NO Graph endpoint exists for parking or
// picking up a call — delegated or application. Park/retrieve is a Teams
// client feature; the admin path is Teams PowerShell (call-park policy
// cmdlets) and the caller must be an Enterprise Voice user covered by a
// call-park policy. There is no Graph scope to request, so the live
// surface stays disabled until a licence + policy is proven — same
// licence-gated pattern as the PHONEUI tabs above. Demo fake only.

/// One parked call (demo shape; no Graph read exists).
public struct ParkedCall: Equatable, Identifiable, Sendable {
    public let id: String
    public let code: String
    public let parkedFor: String
    public let at: Date

    public init(id: String, code: String, parkedFor: String, at: Date) {
        self.id = id
        self.code = code
        self.parkedFor = parkedFor
        self.at = at
    }
}

/// Pickup-code rules: Teams announces a numeric code; the retriever dials
/// it. Digits only, 2–8 long.
public enum CallParkCode {
    public static func normalize(_ raw: String) -> String {
        String(raw.filter(\.isNumber).prefix(8))
    }

    public static func isRetrievable(_ raw: String) -> Bool {
        let n = normalize(raw)
        return n.count >= 2 && n.count <= 8 && n.allSatisfy(\.isNumber)
    }
}

// MARK: - Call queues / auto attendants (PHONE-PLUS R1)
//
// Endpoint map (R0, docs): NO Graph endpoint exists for listing or
// managing call queues or auto attendants (MS Q&A confirms; the admin
// path is Teams PowerShell queue/attendant cmdlets). Licence story: Teams
// Phone System plus resource accounts. Same pattern: demo browse only,
// live disabled with the reason.

/// One call queue (demo shape; no Graph read exists).
public struct CallQueue: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let agentCount: Int
    public let routing: String

    public init(id: String, name: String, agentCount: Int, routing: String) {
        self.id = id
        self.name = name
        self.agentCount = agentCount
        self.routing = routing
    }

    static func parse(_ obj: [String: Any]) -> CallQueue? {
        guard let id = obj["id"] as? String, !id.isEmpty,
              let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        let agents = obj["agentCount"] as? Int ?? 0
        let routing = (obj["routing"] as? String) ?? ""
        return CallQueue(id: id, name: name, agentCount: max(0, agents), routing: routing)
    }

    static func parseList(_ data: Data) -> [CallQueue]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["value"] as? [[String: Any]]
        else { return nil }
        return rows.compactMap(parse)
    }
}

/// One auto attendant (demo shape; no Graph read exists).
public struct AutoAttendant: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let greeting: String

    public init(id: String, name: String, greeting: String) {
        self.id = id
        self.name = name
        self.greeting = greeting
    }

    static func parse(_ obj: [String: Any]) -> AutoAttendant? {
        guard let id = obj["id"] as? String, !id.isEmpty,
              let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        let greeting = (obj["greeting"] as? String) ?? ""
        return AutoAttendant(id: id, name: name, greeting: greeting)
    }

    static func parseList(_ data: Data) -> [AutoAttendant]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["value"] as? [[String: Any]]
        else { return nil }
        return rows.compactMap(parse)
    }
}

// MARK: - Park/queue API seam (DemoChannelMembers precedent)

/// Park/queue source. Sync throws (the blocking-FFI shape); stores run
/// these off-main via `Task.blocking`, same contract as `PhoneAPI`.
public protocol ParkQueueAPI: Sendable {
    func parked() throws -> [ParkedCall]
    func park(name: String) throws -> ParkedCall
    func pickup(code: String) throws -> ParkedCall
    func queues() throws -> [CallQueue]
    func attendants() throws -> [AutoAttendant]
}

/// Live source: no licence, no policy, no Graph shape — every call throws
/// the licence reason.
public struct UnavailableParkQueueAPI: ParkQueueAPI {
    public init() {}
    public func parked() throws -> [ParkedCall] { throw PhoneAPIError.needsLicence(PhoneStore.parkReason) }
    public func park(name: String) throws -> ParkedCall { throw PhoneAPIError.needsLicence(PhoneStore.parkReason) }
    public func pickup(code: String) throws -> ParkedCall { throw PhoneAPIError.needsLicence(PhoneStore.parkReason) }
    public func queues() throws -> [CallQueue] { throw PhoneAPIError.needsLicence(PhoneStore.queuesReason) }
    public func attendants() throws -> [AutoAttendant] { throw PhoneAPIError.needsLicence(PhoneStore.queuesReason) }
}

/// Seeded in-memory fake (demo). Western demo names (repo rule).
/// @unchecked: every read/write of state holds `lock`.
public final class DemoParkQueueAPI: ParkQueueAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ParkedCall]
    private var queuesValue: [CallQueue]
    private var attendantsValue: [AutoAttendant]
    private var counter = 0

    public init() {
        let base = Date(timeIntervalSince1970: 1_764_000_000)
        calls = [
            ParkedCall(id: "demo-park-1", code: "731", parkedFor: "Megan Harper", at: base),
            ParkedCall(id: "demo-park-2", code: "4528", parkedFor: "Tom Becker", at: base - 900),
        ]
        queuesValue = [
            CallQueue(id: "demo-q-1", name: "Support", agentCount: 4, routing: "Round robin"),
            CallQueue(id: "demo-q-2", name: "Sales", agentCount: 2, routing: "Attendant routing"),
        ]
        attendantsValue = [
            AutoAttendant(id: "demo-aa-1", name: "Main", greeting: "Thanks for calling — press 1 for Support, 2 for Sales."),
            AutoAttendant(id: "demo-aa-2", name: "After hours", greeting: "Our offices are closed — please leave a message."),
        ]
    }

    public func parked() throws -> [ParkedCall] {
        lock.lock(); defer { lock.unlock() }
        return calls.sorted { $0.at > $1.at }
    }

    public func park(name: String) throws -> ParkedCall {
        lock.lock(); defer { lock.unlock() }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PhoneAPIError.failed("Enter a name to park the call for.") }
        counter += 1
        let code = String(700 + counter * 7)
        let c = ParkedCall(id: "demo-park-added-\(counter)", code: code, parkedFor: clean, at: Date())
        calls.append(c)
        return c
    }

    public func pickup(code: String) throws -> ParkedCall {
        lock.lock(); defer { lock.unlock() }
        let want = CallParkCode.normalize(code)
        guard CallParkCode.isRetrievable(want) else {
            throw PhoneAPIError.failed("Enter the numeric pickup code announced when the call was parked.")
        }
        guard let i = calls.firstIndex(where: { $0.code == want }) else {
            throw PhoneAPIError.failed("No parked call answers to that code.")
        }
        return calls.remove(at: i)
    }

    public func queues() throws -> [CallQueue] {
        lock.lock(); defer { lock.unlock() }
        return queuesValue
    }

    public func attendants() throws -> [AutoAttendant] {
        lock.lock(); defer { lock.unlock() }
        return attendantsValue
    }
}

// MARK: - PhoneStore plus (park + queues state)

extension PhoneStore {
    /// Shown on the live Park tab (no Graph endpoint; needs Enterprise
    /// Voice + a call-park policy as well as the licence).
    public static let parkReason =
        "Call park needs a Teams Phone licence and a call park policy — ask your admin."
    /// Shown on the live Queues tab (no Graph endpoint; admin-provisioned
    /// queues/attendants).
    public static let queuesReason =
        "Call queues and auto attendants need a Teams Phone licence — ask your admin."
}
