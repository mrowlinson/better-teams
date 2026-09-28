// AvLevel.swift — P4 split: verbatim move from AvPanelView.swift.

/// dBFS -> meter fraction.
public enum AvLevel {
    /// Map dBFS (-60..0) onto 0..1, clamped. -50 dB and below reads empty.
    public static func fraction(db: Double) -> Double {
        min(1, max(0, (db + 50) / 50))
    }
}
