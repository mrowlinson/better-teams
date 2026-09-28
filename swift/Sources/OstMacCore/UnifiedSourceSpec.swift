// UnifiedSourceSpec.swift — P3 split: verbatim move from UnifiedFiles.swift.
import Foundation

/// One conversation leg to aggregate (chats + channels; the drive leg
/// needs no spec — it is the signed-in user's recents).
public struct UnifiedSourceSpec: Equatable, Sendable, Codable {
    public let kind: UnifiedFileSource
    public let id: String
    public let name: String

    public init(kind: UnifiedFileSource, id: String, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }
}
