// ScreenShareSession.swift — P4 split: verbatim move from ScreenShare.swift.

/// Pure session state machine: transitions only, no ScreenCaptureKit.
/// The engine (ScreenShareModel) drives these from picker/stream callbacks.
public struct ScreenShareSession: Equatable, Sendable {
    public private(set) var phase: ScreenSharePhase = .idle
    public private(set) var source: ScreenShareSource?
    public private(set) var lastError: String?

    public init() {}

    /// User tapped Share: the picker opens. False unless idle/failed (retry).
    @discardableResult
    public mutating func beginPick() -> Bool {
        guard phase == .idle || phase == .failed else { return false }
        phase = .picking
        lastError = nil
        return true
    }

    /// Picker delivered a choice: stream bring-up starts. False unless picking
    /// (stray re-picks while live are ignored — stop, then re-share).
    @discardableResult
    public mutating func didPick(_ source: ScreenShareSource) -> Bool {
        guard phase == .picking else { return false }
        self.source = source
        phase = .starting
        return true
    }

    /// Picker dismissed with no choice: back to idle (keeps the prior source).
    public mutating func didCancelPick() {
        guard phase == .picking else { return }
        phase = .idle
    }

    /// Stream started: live. False unless starting.
    @discardableResult
    public mutating func didStart() -> Bool {
        guard phase == .starting else { return false }
        phase = .live
        lastError = nil
        return true
    }

    /// Anything failed: failed + detail. No-op when idle.
    public mutating func didFail(_ detail: String) {
        guard phase != .idle else { return }
        phase = .failed
        lastError = detail
    }

    /// User tapped Stop: teardown starts. False unless live/starting
    /// (a stop mid-bring-up is honored when the start lands).
    @discardableResult
    public mutating func beginStop() -> Bool {
        guard phase == .live || phase == .starting else { return false }
        phase = .stopping
        return true
    }

    /// Stream stopped: idle, source kept for one-tap re-share. False unless
    /// stopping.
    @discardableResult
    public mutating func didStop() -> Bool {
        guard phase == .stopping else { return false }
        phase = .idle
        lastError = nil
        return true
    }
}
