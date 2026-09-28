// CallDirection.swift — P4 split: verbatim move from CallHistory.swift.

/// Direction of a finished call. Raw values are the CallInfo `dir`
/// vocabulary plus `missed` (incoming, never connected).
public enum CallDirection: String, Codable, Sendable, Equatable {
    case missed
    case incoming = "in"
    case outgoing = "out"

    /// SF Symbol for the recents row (missed renders in danger red).
    public var systemImage: String {
        switch self {
        case .missed: "phone.arrow.down.left.fill"
        case .incoming: "phone.arrow.down.left"
        case .outgoing: "phone.arrow.up.right"
        }
    }

    /// VoiceOver + Diagnostics word.
    public var label: String {
        switch self {
        case .missed: "Missed"
        case .incoming: "Incoming"
        case .outgoing: "Outgoing"
        }
    }
}
