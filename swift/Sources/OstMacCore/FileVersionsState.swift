// FileVersionsState.swift — P3 split: verbatim move from FileVersionsView.swift.
import Foundation

/// Version-list content state.
public enum FileVersionsState: Equatable, Sendable {
    case loading
    case loaded
    case empty
    case error(String)
}
