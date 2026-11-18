// UnifiedSourceSpec.swift — P3 split: verbatim move from UnifiedFiles.swift.
import Foundation

/// One conversation leg to aggregate (chats + channels; the drive leg
/// needs no spec — it is the signed-in user's recents).
public struct UnifiedSourceSpec: Equatable, Sendable, Codable {
    public let kind: UnifiedFileSource
    public let id: String
    public let name: String
    /// Owning team for channel legs (launch-r2: lets core skip the
    /// channel→team scan). Nil for chats and unknown teams.
    public let teamID: String?

    public init(kind: UnifiedFileSource, id: String, name: String, teamID: String? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.teamID = teamID
    }
}
