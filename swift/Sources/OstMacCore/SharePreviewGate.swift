// SharePreviewGate.swift — P4 split: verbatim move from ScreenShare.swift.
import Dispatch
import Foundation

/// Preview-publish gate: the first frame publishes immediately, then at
/// most every 250ms (4Hz). Counters stay exact — the sink coalesces the
/// frames between ticks. Pure (unit-tested).
public enum SharePreviewGate {
    public static let minIntervalMs: UInt64 = 250

    public static func shouldPublish(nowMs: UInt64, lastMs: UInt64?) -> Bool {
        guard let lastMs else { return true }
        return nowMs &- lastMs >= minIntervalMs
    }

    static func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}
