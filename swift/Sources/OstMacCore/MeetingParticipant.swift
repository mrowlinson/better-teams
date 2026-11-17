// MeetingParticipant.swift — P4 split: verbatim move from MeetingChat.swift.

/// One roster row: identity + live speaking/mute state + C2b
/// signaling axes (hand raised, presenter role). The live feed does
/// not carry hand/role yet (owner live test pending): they arrive via
/// local actions and demo seeds, never the network.
public struct MeetingParticipant: Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var speaking: Bool
    public var muted: Bool
    public var present: Bool
    public var handRaised: Bool
    public var isPresenter: Bool

    public init(id: String, name: String, speaking: Bool = false, muted: Bool = false, present: Bool = true,
                handRaised: Bool = false, isPresenter: Bool = false) {
        self.id = id
        self.name = name
        self.speaking = speaking
        self.muted = muted
        self.present = present
        self.handRaised = handRaised
        self.isPresenter = isPresenter
    }
}
