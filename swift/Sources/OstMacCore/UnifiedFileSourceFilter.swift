// UnifiedFileSourceFilter.swift — P3 split: verbatim move from UnifiedFiles.swift.
import Foundation

/// Source filter chips above the recents list.
public enum UnifiedFileSourceFilter: String, CaseIterable, Sendable {
    case all
    case chats
    case channels
    case drive

    public var label: String {
        switch self {
        case .all: return "All"
        case .chats: return "Chats"
        case .channels: return "Channels"
        case .drive: return "OneDrive"
        }
    }

    public func matches(_ row: UnifiedFileRow) -> Bool {
        switch self {
        case .all: return true
        case .chats: return row.source == .chat
        case .channels: return row.source == .channel
        case .drive: return row.source == .drive
        }
    }
}
