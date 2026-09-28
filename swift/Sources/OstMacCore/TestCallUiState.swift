// TestCallUiState.swift — P4 split: verbatim move from TestCallSettings.swift.

/// Settings test-call row state (all copy lives here, tested).
public struct TestCallUiState: Equatable, Sendable {
    public let placeLabel: String
    public let placeEnabled: Bool
    public let showEnd: Bool
    public let endEnabled: Bool
    public let status: String

    public init(
        placeLabel: String, placeEnabled: Bool, showEnd: Bool,
        endEnabled: Bool, status: String
    ) {
        self.placeLabel = placeLabel
        self.placeEnabled = placeEnabled
        self.showEnd = showEnd
        self.endEnabled = endEnabled
        self.status = status
    }
}
