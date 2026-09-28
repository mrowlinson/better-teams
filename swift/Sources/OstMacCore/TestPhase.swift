// TestPhase.swift — P4 split: verbatim move from AvPanelView.swift.

/// Test-button lifecycle.
public enum TestPhase: Equatable, Sendable {
    case idle
    case running
    case done
    case failed

    public var isRunning: Bool { self == .running }
}
