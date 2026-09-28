// RelativeTime.swift — the one shared 60 s relative-time ticker
// (UI-SPEC R7; one of the two files allowed a Timer).
//
// Under `--evidence` the clock is pinned to the demo epoch so captures
// are deterministic.
import Foundation
import Observation

@Observable
@MainActor
public final class RelativeClock {
    public static let shared = RelativeClock()

    public private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pinned = false

    private init() {}

    /// Starts the minute ticker (idempotent).
    public func start() {
        guard timer == nil, !pinned else { return }
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { RelativeClock.shared.now = Date() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Evidence: freeze at `date`.
    public func pin(_ date: Date) {
        pinned = true
        timer?.invalidate()
        timer = nil
        now = date
    }
}
