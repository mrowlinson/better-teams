// RemoteImagePhase.swift — P4 split: verbatim move from RemoteImage.swift.

/// Load state for one bubble image. Plain enum keeps the state machine
/// testable without views.
public enum RemoteImagePhase: Sendable, Equatable {
    case loading
    case loaded
    case failed(String)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.loaded, .loaded): return true
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}
