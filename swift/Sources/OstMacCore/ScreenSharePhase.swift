// ScreenSharePhase.swift — P4 split: verbatim move from ScreenShare.swift.

/// Share lifecycle. Failed keeps its detail in `lastError`, like CallStore.
public enum ScreenSharePhase: Equatable, Sendable {
    case idle
    /// System picker on screen, awaiting the user's choice.
    case picking
    /// Stream create/add-output/start in flight.
    case starting
    case live
    case stopping
    case failed

    public var isLive: Bool { self == .live }
    public var isBusy: Bool {
        self == .picking || self == .starting || self == .stopping
    }
}
