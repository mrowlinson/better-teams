// MeetingRosterStore.swift — P4 split: verbatim move from MeetingChat.swift.
import Combine
import Foundation

/// Single-meeting roster, updated in place by participant id.
/// Main-actor (SwiftUI-owned).
@MainActor
public final class MeetingRosterStore: ObservableObject {
    /// Rows in join order; updates never reorder (in-place upsert).
    @Published public private(set) var participants: [MeetingParticipant] = []
    /// Attributed meeting id, or nil while only unattributed frames
    /// have landed.
    @Published public private(set) var meetingID: String?

    /// Nonisolated so views can take a default in their (nonisolated)
    /// inits; all members stay main-actor-isolated.
    public nonisolated init() {}

    /// Upsert one snapshot by id (new ids append, known ids merge in
    /// place — name only when non-empty, axes only when non-nil).
    /// Empty ids are ignored (nothing to attribute). `present == false`
    /// removes the row (unknown leaves are a no-op). `speaking == true`
    /// solos: every other row clears (dominant-speaker semantics).
    /// A non-empty meeting id for another meeting resets the roster
    /// first (single-meeting model, like the single-call slot).
    public func ingest(_ event: MeetingRosterEvent) {
        guard !event.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !event.meetingID.isEmpty, let cur = meetingID, cur != event.meetingID {
            participants = []
        }
        if !event.meetingID.isEmpty { meetingID = event.meetingID }
        if event.present == false {
            participants.removeAll { $0.id == event.id }
            return
        }
        if participants.contains(where: { $0.id == event.id }) {
            for i in participants.indices where participants[i].id == event.id {
                if !event.name.isEmpty { participants[i].name = event.name }
                if let m = event.muted { participants[i].muted = m }
                participants[i].present = true
            }
            if let s = event.speaking { applySpeaking(id: event.id, speaking: s) }
        } else {
            participants.append(MeetingParticipant(
                id: event.id,
                name: event.name.isEmpty ? "?" : event.name,
                speaking: false,
                muted: event.muted ?? false,
                present: true))
            if let s = event.speaking { applySpeaking(id: event.id, speaking: s) }
        }
    }

    public func ingest(_ events: [MeetingRosterEvent]) {
        for e in events { ingest(e) }
    }

    /// Speaking rows (usually one — dominant speaker).
    public var speaking: [MeetingParticipant] {
        participants.filter(\.speaking)
    }

    /// Live row count (Diagnostics counter source).
    public var activeCount: Int { participants.count }

    /// Speaking rows (Diagnostics counter source).
    public var speakingCount: Int { speaking.count }

    /// Muted rows (Diagnostics counter source).
    public var mutedCount: Int { participants.filter(\.muted).count }

    /// The meeting ended: every row stops speaking (last-known roster
    /// stays visible; the persisted thread keeps the history).
    public func noteMeetingEnded() {
        for i in participants.indices { participants[i].speaking = false }
    }

    /// Adopt rows without the feed (tests, previews, demo).
    public func adopt(_ list: [MeetingParticipant], meetingID: String? = nil) {
        participants = list
        self.meetingID = meetingID
    }

    /// Seed offline demo state (shot hook: --show-meeting).
    public func seedDemo() {
        adopt(MeetingDemo.participants, meetingID: MeetingDemo.threadID)
    }

    /// Drop everything after sign-out (fail closed).
    public func clear() {
        participants = []
        meetingID = nil
    }

    /// Speaking solo: true lights this row and clears the rest; false
    /// clears this row only.
    private func applySpeaking(id: String, speaking: Bool) {
        for i in participants.indices {
            if participants[i].id == id {
                participants[i].speaking = speaking
            } else if speaking {
                participants[i].speaking = false
            }
        }
    }
}
