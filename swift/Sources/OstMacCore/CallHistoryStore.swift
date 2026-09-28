// CallHistoryStore.swift — P4 split: verbatim move from CallHistory.swift.
import Combine
import Foundation

/// Local recents: UserDefaults JSON array, newest first, capped.
@MainActor
public final class CallHistoryStore: ObservableObject {
    /// Newest first. Published for the window; Diagnostics reads counts.
    @Published public private(set) var records: [CallRecord] = []
    /// Redial seam (AppState: place on the record's thread). Injectable
    /// so tests assert the action without the call slot.
    public var onRedial: ((CallRecord) -> Void)?
    /// Record hook (e1-activity: missed calls land in the feed).
    /// Fires once per finalized record, after persistence.
    public var onRecord: ((CallRecord) -> Void)?

    public nonisolated static let defaultsKey = "omCallHistoryV1"
    /// Per-account key (d1-accounts): default keeps the legacy key.
    nonisolated public static func key(for accountID: String) -> String {
        AccountProfile.key(defaultsKey, for: accountID)
    }
    public static let maxRecords = 100

    private let defaults: UserDefaults
    private let key: String
    private var pending: [String: PendingCall] = [:]
    /// Finalized ids (session exactly-once; seeded from loaded records).
    private var recordedIDs: Set<String> = []

    public init(
        defaults: UserDefaults = .standard,
        key: String = CallHistoryStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
        let loaded = Self.load(defaults: defaults, key: key)
        records = loaded
        recordedIDs = Set(loaded.map(\.id))
    }

    // MARK: - Counts (Diagnostics only)

    public var totalCount: Int { records.count }
    public var missedCount: Int { records.filter(\.isMissed).count }
    public var isEmpty: Bool { records.isEmpty }

    // MARK: - Feeds

    /// Slot snapshot hook (CallStore.$call sink): active states refresh
    /// the pending entry, ended/failed finalizes it, nil finalizes all
    /// pending (demo end + slot-clear paths).
    public func noteActiveCall(_ call: CallInfo?, at now: Date = Date()) {
        guard let call else {
            for id in pending.keys { finalize(id: id, snapshot: nil, at: now) }
            return
        }
        if call.isActive {
            var p = pending[call.id] ?? PendingCall(
                peer: call.peer, peerName: call.peerName,
                thread: call.thread, dir: call.dir,
                ringingAt: stampOr(call.startedAt, now))
            p.peer = call.peer.isEmpty ? p.peer : call.peer
            p.peerName = call.peerName.isEmpty ? p.peerName : call.peerName
            p.thread = call.thread.isEmpty ? p.thread : call.thread
            if !call.dir.isEmpty { p.dir = call.dir }
            if call.state == "connected", p.connectedAt == nil {
                p.connectedAt = now
            }
            pending[call.id] = p
            return
        }
        if call.state == "ended" || call.state == "failed" {
            finalize(id: call.id, snapshot: call, at: now)
        }
    }

    /// Feed event hook (RealtimeFeed.onCall): incoming opens pending,
    /// end/rejected finalize it. Events without pending are ignored
    /// (the slot snapshot carries the authoritative close).
    public func noteEvent(_ event: CallEvent, at now: Date = Date()) {
        switch event.kind {
        case "incoming":
            if pending[event.callID] == nil {
                pending[event.callID] = PendingCall(
                    peer: event.peer, peerName: event.peerName,
                    thread: "", dir: "in", ringingAt: now)
            }
        case "end", "rejected":
            if pending[event.callID] != nil {
                finalize(id: event.callID, snapshot: nil, at: now)
            }
        default:
            break
        }
    }

    // MARK: - Actions

    /// Redial hook: fires the handler (no-op when unset). Callers gate
    /// on `canRedial` — threadless rows can't place.
    public func redial(_ record: CallRecord) {
        onRedial?(record)
    }

    /// Pure redial gate: the record carries a placeable thread id.
    nonisolated public static func canRedial(_ record: CallRecord) -> Bool {
        !record.thread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func canRedial(_ record: CallRecord) -> Bool {
        Self.canRedial(record)
    }

    /// Drop every record (in-flight pending survives: the live call
    /// still lands when it ends). Persists immediately.
    public func clear() {
        let ids = Set(records.map(\.id))
        records = []
        recordedIDs.subtract(ids)
        save()
    }

    /// Offline demo recents (missed + in + out, one threadless row).
    /// In-memory only — demo never touches the persisted list. Times are
    /// fixed offsets from the top of the current hour, not from the
    /// launch second, so two launches (light + dark evidence) show the
    /// same times.
    public func seedDemo(now date: Date = Date()) {
        let now = UInt64(date.timeIntervalSince1970) / 3600 * 3600
        records = [
            CallRecord(
                id: "demo-missed", direction: .missed,
                peer: "8:orgid:demo-missed", peerName: "Garcia, Maria",
                startedAt: now - 900, endedAt: now - 870),
            CallRecord(
                id: "demo-in", direction: .incoming,
                peer: "8:orgid:demo", peerName: "Doe, Jane",
                thread: "19:demo@thread.v2",
                startedAt: now - 7200, endedAt: now - 6943,
                durationSecs: 257),
            CallRecord(
                id: "demo-out", direction: .outgoing,
                peer: "8:orgid:demo-carr", peerName: "Carr, Tom",
                thread: "19:demo-carr@thread.v2",
                startedAt: now - 96_000, endedAt: now - 95_372,
                durationSecs: 628),
        ]
        recordedIDs = Set(records.map(\.id))
    }

    // MARK: - Internals

    /// Append the finished record for `id`, exactly once. Prefers the
    /// pending entry (has the connect mark); falls back to the slot
    /// snapshot (relaunch-then-end edge: unobserved leg, 0 duration).
    private func finalize(id: String, snapshot: CallInfo?, at now: Date) {
        guard !recordedIDs.contains(id) else {
            pending.removeValue(forKey: id)
            return
        }
        let p = pending.removeValue(forKey: id)
        let dir = p?.dir ?? snapshot?.dir ?? ""
        let connected = p?.connectedAt != nil
        let direction: CallDirection =
            dir == "in" ? (connected ? .incoming : .missed) : .outgoing
        let started: UInt64 = {
            if let p { return UInt64(p.ringingAt.timeIntervalSince1970) }
            if let s = snapshot, s.startedAt > 0 { return s.startedAt }
            return UInt64(now.timeIntervalSince1970)
        }()
        let ended = UInt64(now.timeIntervalSince1970)
        let duration: UInt64 = {
            guard connected, let at = p?.connectedAt else { return 0 }
            return UInt64(max(0, now.timeIntervalSince(at)))
        }()
        let record = CallRecord(
            id: id, direction: direction,
            peer: p?.peer ?? snapshot?.peer ?? "",
            peerName: p?.peerName ?? snapshot?.peerName ?? "",
            thread: p?.thread ?? snapshot?.thread ?? "",
            startedAt: started, endedAt: max(ended, started),
            durationSecs: duration)
        recordedIDs.insert(id)
        records.removeAll { $0.id == id }
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            let dropped = records.suffix(from: Self.maxRecords)
            recordedIDs.subtract(dropped.map(\.id))
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
        onRecord?(record)
    }

    private func stampOr(_ unix: UInt64, _ fallback: Date) -> Date {
        unix > 0
            ? Date(timeIntervalSince1970: TimeInterval(unix)) : fallback
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }

    static func load(defaults: UserDefaults, key: String) -> [CallRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CallRecord].self, from: data)) ?? []
    }

    // MARK: - Empty-state copy (moved verbatim from CallHistoryView.swift
    // in the scratch-ui rebuild; pinned by CallHistoryTests).

    /// Empty-state copy (single source; the store tests pin it).
    public static let emptyImage = "phone"
    public static let emptyTitle = "No recent calls"
    public static let emptyMessage =
        "Calls you make or receive will appear here with names, times, and durations."
}
