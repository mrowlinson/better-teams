// ScreenSharePermission.swift — P4 split: verbatim move from ScreenShare.swift.

/// Screen Recording authorization. Tri-state: unknown until probed
/// (headless/CI stays unknown — preflight never prompts, never hangs).
/// Denied is set only on failure evidence (stream start refused while
/// preflight is false), never from preflight alone — preflight cannot
/// tell not-yet-asked from denied.
public enum ScreenSharePermission: Equatable, Sendable {
    case unknown
    case authorized
    case denied

    /// Pure mapping from a preflight probe (nil = unprobed).
    public init(granted: Bool?) {
        switch granted {
        case .some(true): self = .authorized
        case .some(false): self = .denied
        case .none: self = .unknown
        }
    }

    public var isDenied: Bool { self == .denied }
    public var isAuthorized: Bool { self == .authorized }
}
