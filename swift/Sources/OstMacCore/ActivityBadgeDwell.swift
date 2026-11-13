// ActivityBadgeDwell.swift — rail Activity badge dismissal by dwell.
//
// Staying on the Activity view for more than one full second (view
// selected, app active, window visible) dismisses the rail badge and
// restarts its counter (`ActivityStore.dismissBadge`). It never marks
// an item read. A shorter visit changes nothing. The clock and the
// timer are injected so tests drive time by hand.
import Foundation

@MainActor
public final class ActivityBadgeDwell {
    /// Continuous viewing needed before the badge is dismissed.
    public static let seconds: TimeInterval = 1.0

    /// Cancels a scheduled callback.
    public typealias Cancel = () -> Void
    /// Runs the callback once after the delay; returns its canceller.
    public typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Cancel

    private let now: () -> Date
    private let schedule: Scheduler
    private let count: () -> Int
    private let dismiss: () -> Void
    private var viewingSince: Date?
    private var cancelTimer: Cancel?

    public init(
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Scheduler = ActivityBadgeDwell.taskScheduler,
        badgeCount: @escaping () -> Int,
        dismiss: @escaping () -> Void
    ) {
        self.now = now
        self.schedule = schedule
        self.count = badgeCount
        self.dismiss = dismiss
    }

    /// Real timer: a main-actor Task sleeping the delay.
    public static let taskScheduler: Scheduler = { delay, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { fire() }
        }
        return { task.cancel() }
    }

    /// Viewing = Activity selected (not searching), app active, and a
    /// window on screen. The single rule the shell feeds `update`.
    public nonisolated static func isViewing(
        activitySelected: Bool, searching: Bool, appActive: Bool, windowVisible: Bool
    ) -> Bool {
        activitySelected && !searching && appActive && windowVisible
    }

    /// True while a continuous viewing stretch is open.
    public var isViewing: Bool { viewingSince != nil }

    /// Feed the current viewing state (call on every change of section,
    /// app activation, or window visibility). Leaving resets the stretch;
    /// re-entering starts a new one.
    public func update(viewing: Bool) {
        if viewing {
            if viewingSince == nil { viewingSince = now() }
            evaluate()
        } else {
            viewingSince = nil
            cancelTimer?()
            cancelTimer = nil
        }
    }

    /// The store changed (new arrivals): while a stretch is already past
    /// the dwell, they dismiss at once (no badge flashes under the
    /// viewer); inside it, the timer covers them.
    public func storeChanged() { evaluate() }

    private func evaluate() {
        guard let since = viewingSince, count() > 0 else { return }
        let elapsed = now().timeIntervalSince(since)
        if elapsed >= Self.seconds {
            cancelTimer?()
            cancelTimer = nil
            dismiss()
        } else if cancelTimer == nil {
            cancelTimer = schedule(Self.seconds - elapsed) { [weak self] in
                guard let self else { return }
                self.cancelTimer = nil
                self.evaluate()
            }
        }
    }
}
