// LiveVideoPacing.swift — P4 split: verbatim move from LiveVideoModel.swift.
// CALLFIX: the tick is one 30 fps frame and each tick drains the queue.
import Foundation

/// Poll pacing: while video flows the loop ticks once per 30 fps frame;
/// each miss doubles the wait up to the ceiling; any AU resets to the
/// base tick. Pure (unit-tested).
public enum LiveVideoPacing {
    public static let baseMs: UInt64 = 33
    public static let maxMs: UInt64 = 500

    public static func delayMs(nilStreak: Int) -> UInt64 {
        min(baseMs << UInt64(min(max(nilStreak, 0), 4)), maxMs)
    }
}

/// One tick of a live decoder: take every queued access unit in order
/// (a P-frame needs each reference before it, so none is skipped) and
/// keep only the newest picture for display. After a decode failure the
/// following units are skipped until a keyframe (SPS / IDR), so a broken
/// reference never smears. Pure over `poll` / `decode` (unit-tested).
public enum LiveVideoDrain {
    /// Units taken per tick at most (the core queue holds ~1 s).
    public static let maxUnits = 64

    public struct Tick<Image> {
        /// The newest decoded picture this tick (nil: nothing new).
        public var latest: Image?
        /// Units taken from the queue.
        public var units = 0
        /// Pictures decoded.
        public var decoded = 0
        /// The last decode failure this tick.
        public var error: Error?
    }

    /// The unit carries an SPS or an IDR slice: a decoder can restart there.
    public static func isKeyframe(_ nals: [Data]) -> Bool {
        nals.contains { n in n.first.map { [5, 7].contains($0 & 0x1F) } ?? false }
    }

    /// `poll` returns the next queued unit's NALs (nil when empty);
    /// `needKey` carries the skip-until-keyframe state across ticks.
    public static func run<Image>(needKey: inout Bool, poll: () throws -> [Data]?,
                                  decode: ([Data]) throws -> Image?) throws -> Tick<Image> {
        var tick = Tick<Image>()
        while tick.units < maxUnits, let nals = try poll() {
            tick.units += 1
            if needKey, !isKeyframe(nals) { continue }
            do {
                if let img = try decode(nals) {
                    tick.latest = img
                    tick.decoded += 1
                }
                needKey = false
            } catch {
                needKey = true
                tick.error = error
            }
        }
        return tick
    }
}
