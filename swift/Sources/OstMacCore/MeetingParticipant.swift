// MeetingParticipant.swift — P4 split: verbatim move from MeetingChat.swift.

/// One roster row: identity + live speaking/mute state.
public struct MeetingParticipant: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var speaking: Bool
    public var muted: Bool
    public var present: Bool

    public init(id: String, name: String, speaking: Bool = false, muted: Bool = false, present: Bool = true) {
        self.id = id
        self.name = name
        self.speaking = speaking
        self.muted = muted
        self.present = present
    }
}
