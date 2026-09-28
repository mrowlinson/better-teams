// CameraStatsGate.swift — P4 split: verbatim move from CameraCapture.swift.
import Dispatch

/// Stats-publish gate: first stats always publish, then at most 1/s.
public enum CameraStatsGate {
    public static let minIntervalMs: UInt64 = 1000

    public static func shouldPublish(nowMs: UInt64, lastMs: UInt64?) -> Bool {
        guard let lastMs else { return true }
        return nowMs &- lastMs >= minIntervalMs
    }

    static func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}
