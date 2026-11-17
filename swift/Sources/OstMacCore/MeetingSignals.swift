// MeetingSignals.swift — C2b roster signaling (hand, meeting
// reactions, participant actions). Local state only: the Teams call
// protocol carries no wire endpoint for any of these in this codebase
// (core exposes roster poll, video subscribe, self mute, and lobby
// admit/deny — nothing for hand/reactions/spotlight/mute-others/
// remove/make-presenter), so every send path below is demo/evidence
// only and stays disabled in live calls until the owner live test
// (Q-meetvideo-test) proves the signaling. REPORT.md marks each path
// unit/demo-verified vs live-unproven.
import Foundation
import Observation

/// Meeting reaction (an emoji burst during the call, not a message
/// reaction). Teams meeting set.
public struct MeetingReaction: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let emoji: String
    public let sender: String

    public init(emoji: String, sender: String) {
        id = UUID()
        self.emoji = emoji
        self.sender = sender
    }
}

/// The meeting reactions teams clients can send mid-call.
public enum MeetingReactionSet {
    public static let emojis = ["👍", "❤️", "👏", "😂", "🎉", "😮"]

    public static func isSupported(_ emoji: String) -> Bool { emojis.contains(emoji) }
}

/// Recent meeting reactions, newest at the end, capped so a long
/// meeting cannot grow the log. Unsupported/blank emoji never enter.
public struct MeetingReactionLog: Equatable, Sendable {
    /// Reactions kept.
    public static let maxLines = 20
    /// Reactions the stage overlay shows (the newest few).
    public static let shownLines = 6

    public private(set) var lines: [MeetingReaction] = []

    public init() {}

    public init(lines: [MeetingReaction]) {
        self.lines = Array(lines.suffix(Self.maxLines))
    }

    public mutating func append(emoji: String, sender: String) {
        let e = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !s.isEmpty, MeetingReactionSet.isSupported(e) else { return }
        lines.append(MeetingReaction(emoji: e, sender: s))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    public mutating func clear() { lines.removeAll() }

    /// What the stage overlay shows: the newest reactions.
    public var recent: [MeetingReaction] { Array(lines.suffix(Self.shownLines)) }
}

/// Signaling is unimplemented: the action has local state only and no
/// wire to the other side yet.
public struct MeetingSignalError: Error, Equatable, Sendable {
    public let action: String

    public static func liveUnproven(_ action: String) -> MeetingSignalError { .init(action: action) }
}

extension MeetingSignalError: LocalizedError {
    public var errorDescription: String? {
        "Live signaling for \(action) is not built yet (owner live test pending)."
    }
}

/// Participant-action seam: mute someone else, remove them, or make
/// them a presenter. The core has no endpoint for any of these, so
/// live calls get `NoParticipantControl` (every op throws
/// `liveUnproven`) and demo/evidence gets `DemoParticipantControl`
/// (applies to the demo roster in memory). Views disable the actions
/// while the control is `NoParticipantControl`. Main-actor: both
/// controls touch the main-actor roster store.
@MainActor
public protocol MeetingParticipantControl: Sendable {
    func muteOthers(id: String, in roster: MeetingRosterStore) throws
    func remove(id: String, in roster: MeetingRosterStore) throws
    func makePresenter(id: String, in roster: MeetingRosterStore) throws
}

/// Live control: no wire yet, every op throws.
public struct NoParticipantControl: MeetingParticipantControl {
    public init() {}

    public func muteOthers(id _: String, in _: MeetingRosterStore) throws {
        throw MeetingSignalError.liveUnproven("mute others")
    }

    public func remove(id _: String, in _: MeetingRosterStore) throws {
        throw MeetingSignalError.liveUnproven("remove participant")
    }

    public func makePresenter(id _: String, in _: MeetingRosterStore) throws {
        throw MeetingSignalError.liveUnproven("make presenter")
    }
}

/// Demo/evidence control: applies to the in-memory roster only.
public struct DemoParticipantControl: MeetingParticipantControl {
    public init() {}

    public func muteOthers(id: String, in roster: MeetingRosterStore) throws {
        roster.ingest(MeetingRosterEvent(id: id, name: "", muted: true))
    }

    public func remove(id: String, in roster: MeetingRosterStore) throws {
        roster.ingest(MeetingRosterEvent(id: id, name: "", present: false))
    }

    public func makePresenter(id: String, in roster: MeetingRosterStore) throws {
        roster.ingest(MeetingRosterEvent(id: id, name: "", isPresenter: true))
    }
}

/// Participant actions for one call (main actor): pending ids disable
/// their rows while the op runs; the last failure stays visible.
@Observable
@MainActor
public final class MeetingParticipantActions {
    public private(set) var pending: Set<String> = []
    public private(set) var lastError: String?
    /// False in live calls (no signaling yet): views disable the menu.
    public let enabled: Bool
    private let control: MeetingParticipantControl

    public init(control: MeetingParticipantControl, enabled: Bool) {
        self.control = control
        self.enabled = enabled
    }

    public static func live() -> MeetingParticipantActions {
        .init(control: NoParticipantControl(), enabled: false)
    }

    public static func demo() -> MeetingParticipantActions {
        .init(control: DemoParticipantControl(), enabled: true)
    }

    public func muteOthers(id: String, in roster: MeetingRosterStore) async {
        await run(id: id) { try $0.muteOthers(id: id, in: roster) }
    }

    public func remove(id: String, in roster: MeetingRosterStore) async {
        await run(id: id) { try $0.remove(id: id, in: roster) }
    }

    public func makePresenter(id: String, in roster: MeetingRosterStore) async {
        await run(id: id) { try $0.makePresenter(id: id, in: roster) }
    }

    private func run(id: String, _ op: (MeetingParticipantControl) throws -> Void) async {
        guard enabled, !pending.contains(id) else { return }
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            try op(control)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}
