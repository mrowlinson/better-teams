// ScreenShareSource.swift — P4 split: verbatim move from ScreenShare.swift.

/// What the user picked in the system picker. The SCContentFilter itself
/// is engine-owned (SCKit types never enter the pure model).
public struct ScreenShareSource: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case display
        case window
        case app
    }

    public let id: String
    public let kind: Kind
    /// Human size tag from the picked content rect (e.g. "1920×1080").
    public let name: String

    public init(id: String, kind: Kind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}
