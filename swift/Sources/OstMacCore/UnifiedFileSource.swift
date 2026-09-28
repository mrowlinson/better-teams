// UnifiedFileSource.swift — P3 split: verbatim move from UnifiedFiles.swift.
import Foundation

/// Which leg a unified row came from.
public enum UnifiedFileSource: String, CaseIterable, Sendable, Codable {
    case chat
    case channel
    case drive

    public var label: String {
        switch self {
        case .chat: return "Chat"
        case .channel: return "Channel"
        case .drive: return "OneDrive"
        }
    }
}
