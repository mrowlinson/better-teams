// Presence.swift — om-presence lane: own status + chatmate presence.
//
// ost parity: TUI LoadPresence (own availability/activity, failure is
// non-critical) + CLI set (available/busy/dnd/away/offline). ost has no
// per-user fetch — its sidebar `online` is hardcoded false — so chatmate
// presence is a new core primitive (Graph /users/{id}/presence) behind
// the same envelope shape.
//
//   let store = PresenceStore()          // live core fetchers
//   await store.refreshOwn()             // own dot (status bar, picker)
//   store.set(status: .busy)             // own-status picker action
//   await store.refreshPeers(ids: [...]) // chatmate dots by user id
//   await store.refreshChatPeerMri(chatID: "19:..", mri: "8:orgid:..") // dots by sender MRI
// Tests inject mock fetchers (same seam as ChatListViewModel.Fetcher).
import Combine
import Foundation

/// The six settable statuses (Teams picker order; fid-presence D1/D2).
/// Codable (e2-attention): presence-schedule entries persist the target.
public enum PresenceStatus: String, CaseIterable, Codable, Sendable {
    case available, busy, dnd, brb, away, offline

    /// Picker label (Teams client strings: "Be right back", "Appear away").
    public var title: String {
        switch self {
        case .available: "Available"
        case .busy: "Busy"
        case .dnd: "Do not disturb"
        case .brb: "Be right back"
        case .away: "Appear away"
        case .offline: "Appear offline"
        }
    }

    /// Server availability the core reports back after a successful set
    /// (Teams status table: dnd → DoNotDisturb, brb → BeRightBack).
    public var availability: String {
        switch self {
        case .available: "Available"
        case .busy: "Busy"
        case .dnd: "DoNotDisturb"
        case .brb: "BeRightBack"
        case .away: "Away"
        case .offline: "Offline"
        }
    }

    /// Best-effort reverse map of a server availability to a picker row.
    /// Unknown/future values collapse to nil (picker shows no selection).
    public static func from(availability: String) -> PresenceStatus? {
        switch availability {
        case "Available": .available
        case "Busy": .busy
        case "DoNotDisturb": .dnd
        case "BeRightBack": .brb
        case "Away": .away
        case "Offline": .offline
        default: nil
        }
    }
}

/// Pure availability helpers (ost TUI rules).
public enum PresenceFormat {
    /// ost TUI `is_online`: anything but Offline/PresenceUnknown.
    public static func isOnline(availability: String) -> Bool {
        availability != "Offline" && availability != "PresenceUnknown"
    }

    /// Unknown-dot tooltip (presence-admins: "Status unknown"; D7).
    public static let unknownLabel = "Status unknown"

    /// Teams display text for one raw Graph availability/activity token.
    /// Explicit table (presence-admins strings) + generic de-camel
    /// fallback so future values never leak raw enum fragments (D6).
    public static func friendly(_ token: String) -> String {
        switch token {
        case "Available": "Available"
        case "Busy": "Busy"
        case "DoNotDisturb": "Do not disturb"
        case "Away": "Away"
        case "BeRightBack": "Be right back"
        case "Offline": "Offline"
        case "PresenceUnknown": unknownLabel
        case "InACall": "In a call"
        case "InAMeeting": "In a meeting"
        case "InAConferenceCall": "In a conference call"
        case "Presenting": "Presenting"
        case "Focusing": "Focusing"
        case "OutOfOffice": "Out of Office"
        case "OffWork": "Off work"
        case "UrgentInterruptionsOnly": "Urgent interruptions only"
        default: decamel(token)
        }
    }

    /// One-line status text (Teams roster rule: the activity text wins
    /// when it differs — "In a meeting" with a red dot — except the
    /// documented "Available, Out of Office" combo; D6).
    public static func label(availability: String, activity: String) -> String {
        if activity.isEmpty || activity.caseInsensitiveCompare(availability) == .orderedSame {
            return friendly(availability)
        }
        if availability == "Offline" { return friendly(availability) } // OffWork etc.
        if availability == "Available", activity == "OutOfOffice" {
            return "Available, Out of Office"
        }
        return friendly(activity)
    }

    /// "InACall" → "In a call": split camel humps, sentence-case.
    static func decamel(_ token: String) -> String {
        var out = ""
        out.reserveCapacity(token.count + 4)
        let chars = Array(token)
        for (i, ch) in chars.enumerated() {
            if i > 0 {
                let prev = chars[i - 1]
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if ch.isUppercase, prev.isLowercase || (prev.isUppercase && next?.isLowercase == true) {
                    out.append(" ")
                }
            }
            out.append(ch)
        }
        guard let first = out.first else { return "" }
        return String(first).uppercased() + out.dropFirst().lowercased()
    }
}

/// Own status + chatmate cache. All fetches run off-main (blocking network/FFI).
@MainActor
public final class PresenceStore: ObservableObject {
    public typealias OwnFetcher = @Sendable () throws -> PresenceResponse
    public typealias SetFetcher = @Sendable (String) throws -> PresenceResponse
    public typealias UserFetcher = @Sendable (String) throws -> UserPresenceResponse
    public typealias ResolveFetcher = @Sendable (String) throws -> ResolveMriResponse

    /// Last known own presence; nil until the first successful refresh.
    @Published public private(set) var own: PresenceResponse?
    /// Chatmate presence by user id (Entra ID or UPN).
    @Published public private(set) var peers: [String: UserPresenceResponse] = [:]
    /// Chatmate presence by 1:1 chat id (row/header dot source). Core
    /// ChatInfo carries no peer ids (ost upstream gap), so live entries
    /// land here via `refreshChatPeer` (known user id) or
    /// `refreshChatPeerMri` (sender MRI learned from the realtime feed);
    /// demo/tests adopt directly.
    @Published public private(set) var chatPeers: [String: UserPresenceResponse] = [:]
    /// Last failure (fetch or set); cleared on the next success.
    /// Like ost, presence failure is non-critical: the UI keeps stale data.
    @Published public private(set) var error: String?
    @Published public private(set) var setting = false
    /// Resolved Graph users by MRI (om-steal-ids: one resolve per mate).
    public private(set) var resolved: [String: ResolveMriResponse] = [:]
    /// Learned sender MRI by 1:1 chat id.
    public private(set) var mriByChat: [String: String] = [:]
    /// Min seconds between MRI refreshes of one chat (realtime feeds can
    /// burst; tests shrink it). Resolve cache makes repeats cheap anyway.
    public var resolveThrottle: TimeInterval = 300
    /// Manual-set hook (e2-attention): invoked synchronously by set()
    /// (the picker path). The app wires it to the presence schedule's
    /// noteManualSet (contract (i)); nil by default (no behavior change).
    public var manualSetHook: (() -> Void)?
    /// Ghost-mode gate (f1-ghost): when set and suppressing presence,
    /// `set(status:)` counts a hold and writes nothing (held sets are
    /// dropped — never replayed, never pause the schedule). Nil = live.
    public var ghost: GhostStore?

    private let ownFetcher: OwnFetcher
    private let setFetcher: SetFetcher
    private let userFetcher: UserFetcher
    private let resolveFetcher: ResolveFetcher
    private var lastResolve: [String: Date] = [:]

    // MARK: unified presence (batch + poll)

    /// Batch presence by user id (keys = ids as given). When set (live:
    /// `UnifiedPresence`), own + peer + chat reads go through it in one
    /// request instead of one Graph call per person.
    public typealias BatchFetcher = @Sendable ([String]) async throws -> [String: UserPresenceResponse]
    public var batchFetcher: BatchFetcher?
    /// Own object id (token claims) — included in every batch.
    public var ownIDProvider: (@MainActor () -> String?)?
    /// Current chat ids: 1:1 chats are pinned to their peer on each poll.
    public var chatIDsProvider: (@MainActor () -> [String])?
    /// Seconds between polls (Teams web refreshes on a similar cadence).
    public var pollInterval: TimeInterval = 60
    /// Max people kept on the poll list (most recent first out).
    public var watchLimit = 400
    /// People whose presence is wanted (cards, rosters, search), oldest first.
    public private(set) var watched: [String] = []
    /// 1:1 chat id → peer user id (row/header dot source).
    public private(set) var chatPins: [String: String] = [:]
    /// Batch requests made (tests, diagnostics).
    public private(set) var batchCount = 0
    private var pollTask: Task<Void, Never>?

    /// Nonisolated so views can take a default `PresenceStore()` in
    /// their (nonisolated) inits; all members stay main-actor-isolated.
    public nonisolated init(
        ownFetcher: @escaping OwnFetcher = { try RustCore.presence() },
        setFetcher: @escaping SetFetcher = { try RustCore.setPresence(status: $0) },
        userFetcher: @escaping UserFetcher = { try RustCore.userPresence(id: $0) },
        resolveFetcher: @escaping ResolveFetcher = { try RustCore.resolveMri(mri: $0) }
    ) {
        self.ownFetcher = ownFetcher
        self.setFetcher = setFetcher
        self.userFetcher = userFetcher
        self.resolveFetcher = resolveFetcher
    }

    /// Refresh own presence. Failure keeps the stale value (ost parity).
    public func refreshOwn() async {
        if batchFetcher != nil, let me = ownIDProvider?() {
            await fetchBatch([me])
            return
        }
        let fetcher = ownFetcher
        do {
            let resp = try await Task.blocking { try fetcher() }.value
            own = resp
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Fire-and-forget own refresh (status bar, post-gate startup).
    public func refreshOwnSoon() {
        Task { await refreshOwn() }
    }

    /// Set own status (picker action). Applies the server-echoed value.
    public func set(status: PresenceStatus) {
        // Ghost (f1-ghost): hold before the hook — a held set never
        // happened (no write, no echo, no schedule pause, no spinner).
        if let ghost, ghost.shouldSuppressPresence {
            ghost.noteHeldPresence()
            return
        }
        guard !setting else { return }
        manualSetHook?() // e2-attention: manual set (pause signal)
        setting = true
        let fetcher = setFetcher
        let want = status.rawValue
        Task {
            defer { setting = false }
            do {
                let resp = try await Task.blocking { try fetcher(want) }.value
                own = resp
                error = nil
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    /// Adopt one presence without core (tests, previews, demo).
    public func adoptOwn(_ resp: PresenceResponse) {
        own = resp
        error = nil
    }

    /// Adopt one chatmate presence without core (tests, previews, demo).
    public func adoptPeer(_ resp: UserPresenceResponse) {
        peers[resp.id] = resp
    }

    /// Pin a chatmate presence to a 1:1 chat id (row/header dot source).
    public func adoptChatPeer(chatID: String, response: UserPresenceResponse) {
        chatPeers[chatID] = response
    }

    /// Known availability for a 1:1 chat id, or nil when unknown.
    public func availabilityForChat(_ chatID: String) -> String? {
        chatPeers[chatID]?.availability
    }

    /// Fetch one chatmate by user id and pin it to a 1:1 chat id.
    /// Failure keeps the stale pin (ost non-critical rule).
    public func refreshChatPeer(chatID: String, userID: String) async {
        let fetcher = userFetcher
        do {
            let resp = try await Task.blocking { try fetcher(userID) }.value
            peers[resp.id] = resp
            chatPeers[chatID] = resp
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Refresh chatmates by user id. Unknown ids keep stale entries;
    /// per-id failure records `error` but keeps the rest.
    public func refreshPeers(ids: [String]) async {
        if batchFetcher != nil {
            watch(ids)
            await fetchBatch(ids)
            return
        }
        let fetcher = userFetcher
        for id in ids {
            do {
                let resp = try await Task.blocking { try fetcher(id) }.value
                peers[resp.id] = resp
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    /// Resolve a sender MRI to a Graph user, then fetch that user's
    /// presence and pin it to a 1:1 chat id. Non-MRIs and non-orgid
    /// forms (skypeids, visitor…) are silent no-ops — nothing to
    /// resolve. Resolves are cached per MRI; refreshes are throttled
    /// per chat. Failure keeps the stale pin (ost non-critical rule).
    public func refreshChatPeerMri(chatID: String, mri: String) async {
        guard Mri.isResolvable(mri) else { return }
        if let last = lastResolve[chatID],
           Date().timeIntervalSince(last) < resolveThrottle
        {
            return
        }
        lastResolve[chatID] = Date()
        // Unified presence keys on the MRI's object id: no directory hop.
        if batchFetcher != nil, let oid = Mri.oid(from: mri) {
            mriByChat[chatID] = mri
            chatPins[chatID] = oid
            await fetchBatch([oid])
            return
        }
        let resolve = resolveFetcher
        let fetch = userFetcher
        do {
            let user: ResolveMriResponse
            if let hit = resolved[mri] {
                user = hit
            } else {
                user = try await Task.blocking { try resolve(mri) }.value
                resolved[mri] = user
            }
            mriByChat[chatID] = mri
            let resp = try await Task.blocking { try fetch(user.id) }.value
            peers[resp.id] = resp
            chatPeers[chatID] = resp
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Adopt one MRI resolution without core (tests, previews, demo).
    public func adoptResolved(mri: String, response: ResolveMriResponse) {
        resolved[mri] = response
    }

    /// Add people to the poll list (dedup, case-insensitive; capped).
    public func watch(_ ids: [String]) {
        var seen = Set(watched.map { $0.lowercased() })
        for id in ids where !id.isEmpty && seen.insert(id.lowercased()).inserted {
            watched.append(id)
        }
        if watched.count > watchLimit { watched.removeFirst(watched.count - watchLimit) }
    }

    /// Pin every 1:1 chat to its peer (ids come from the chat id itself).
    /// Returns the peers that had no presence yet.
    @discardableResult
    public func pinOneOnOneChats(_ chatIDs: [String], ownUserID: String?) -> [String] {
        var fresh: [String] = []
        for chat in chatIDs {
            guard let peer = UnifiedPresence.peerUserID(chatID: chat, ownUserID: ownUserID) else { continue }
            if chatPins[chat] != peer { chatPins[chat] = peer }
            if chatPeers[chat] == nil { fresh.append(peer) }
        }
        return fresh
    }

    /// One poll: own + watched + every 1:1 chat peer, one batch.
    public func pollOnce() async {
        guard batchFetcher != nil else { return }
        let me = ownIDProvider?()
        if let chatIDs = chatIDsProvider?() { pinOneOnOneChats(chatIDs, ownUserID: me) }
        var ids = [String]()
        var seen = Set<String>()
        for id in [me].compactMap({ $0 }) + watched + chatPins.keys.sorted().compactMap({ chatPins[$0] })
        where seen.insert(id.lowercased()).inserted {
            ids.append(id)
        }
        guard !ids.isEmpty else { return }
        await fetchBatch(ids)
    }

    /// Poll every `pollInterval` until `stopPolling`/`clear` (first poll now).
    public func startPolling() {
        guard batchFetcher != nil, pollTask == nil else { return }
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One batch read, applied as a diff: only changed entries publish.
    func fetchBatch(_ ids: [String]) async {
        guard let batch = batchFetcher, !ids.isEmpty else { return }
        batchCount += 1
        do {
            let map = try await batch(ids)
            apply(map)
        } catch {
            self.error = String(describing: error)
        }
    }

    /// Diffed apply of one batch (keys = user ids). Unchanged values
    /// never republish; ids missing from the reply keep their last value.
    public func apply(_ map: [String: UserPresenceResponse]) {
        var nextPeers = peers
        var peersChanged = false
        for (id, r) in map where nextPeers[id] != r {
            nextPeers[id] = r
            peersChanged = true
        }
        if peersChanged { peers = nextPeers }
        var lower: [String: UserPresenceResponse] = [:]
        for (id, r) in map { lower[id.lowercased()] = r }
        var nextChats = chatPeers
        var chatsChanged = false
        for (chat, peer) in chatPins {
            guard let r = lower[peer.lowercased()], nextChats[chat] != r else { continue }
            nextChats[chat] = r
            chatsChanged = true
        }
        if chatsChanged { chatPeers = nextChats }
        if let me = ownIDProvider?(), let r = lower[me.lowercased()] {
            let mine = PresenceResponse(ok: true, availability: r.availability, activity: r.activity,
                                        statusMessage: r.statusMessage, outOfOffice: r.outOfOffice,
                                        outOfOfficeNote: r.outOfOfficeNote)
            if own != mine { own = mine }
        }
        if error != nil { error = nil }
    }

    /// Drop everything after sign-out (fail closed; stale dots vanish).
    public func clear() {
        stopPolling()
        watched = []
        chatPins = [:]
        own = nil
        peers = [:]
        chatPeers = [:]
        resolved = [:]
        mriByChat = [:]
        lastResolve = [:]
        error = nil
    }
}

