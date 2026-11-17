// MeetingRosterEvent.swift — P4 split: verbatim move from MeetingChat.swift.
import Foundation

/// One participant snapshot from the live feed (core `roster[]`).
/// `speaking`/`muted`/`present`/`handRaised`/`isPresenter` are nil
/// when the frame said nothing about that axis (the store keeps the
/// last-known value). `name` is "" on speaker-only markers (the store
/// keeps the roster name). The live feed never sets hand/role yet
/// (owner live test pending); local actions and demo seeds do.
public struct MeetingRosterEvent: Decodable, Sendable, Equatable {
    public let meetingID: String
    public let id: String
    public let name: String
    public let speaking: Bool?
    public let muted: Bool?
    public let present: Bool?
    public let handRaised: Bool?
    public let isPresenter: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, speaking, muted, present, handRaised, isPresenter
        case meetingID = "meeting_id"
    }

    /// Host-side construction (tests, mock feeds).
    public init(
        meetingID: String = "", id: String, name: String,
        speaking: Bool? = nil, muted: Bool? = nil, present: Bool? = nil,
        handRaised: Bool? = nil, isPresenter: Bool? = nil
    ) {
        self.meetingID = meetingID
        self.id = id
        self.name = name
        self.speaking = speaking
        self.muted = muted
        self.present = present
        self.handRaised = handRaised
        self.isPresenter = isPresenter
    }

    /// True when this event belongs to the given meeting. Empty never
    /// matches (unattributed frames apply to the open roster instead).
    public func isFor(meetingID id: String?) -> Bool {
        guard !meetingID.isEmpty else { return false }
        return id.map { $0 == meetingID } ?? false
    }
}
