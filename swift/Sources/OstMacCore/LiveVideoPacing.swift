// LiveVideoPacing.swift — P4 split: verbatim move from LiveVideoModel.swift.

/// Idle poll pacing: first miss waits the base tick, then backs off to the
/// 1s ceiling; any AU resets to the base tick. Pure (unit-tested).
public enum LiveVideoPacing {
    public static let baseMs: UInt64 = 250
    public static let maxMs: UInt64 = 1000

    public static func delayMs(nilStreak: Int) -> UInt64 {
        min(baseMs << min(max(nilStreak, 0), 2), maxMs)
    }
}
