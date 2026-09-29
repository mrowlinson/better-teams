// TeamsSync.swift — keeps the team/channel tree current with changes
// made elsewhere (TEAMSYNC): realtime thread updates, app activation
// and a short utility-QoS interval, with backoff on errors.
import AppKit
import Foundation

/// Drives `TeamsViewModel.sync()` so a channel deleted, renamed or
/// added in another client (or a team joined or left) lands in the
/// sidebar within seconds. Every refresh is a quiet diff-apply.
@MainActor
public final class TeamsSync {
    /// Interval while the app is frontmost.
    public nonisolated static let activeInterval: TimeInterval = 15
    /// Interval while the app is in the background.
    public nonisolated static let idleInterval: TimeInterval = 60
    /// Backoff ceiling after repeated failures.
    public nonisolated static let maxBackoff: TimeInterval = 300

    /// Pure schedule: base interval by activity, doubled per consecutive
    /// failure up to `maxBackoff`.
    public nonisolated static func delay(active: Bool, failures: Int) -> TimeInterval {
        let base = active ? activeInterval : idleInterval
        guard failures > 0 else { return base }
        let factor = pow(2.0, Double(min(failures, 8)))
        return min(base * factor, maxBackoff)
    }

    private weak var model: TeamsViewModel?
    private let isActive: @MainActor () -> Bool
    private var loop: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    /// Consecutive failed refreshes (drives backoff).
    public private(set) var failures = 0
    /// Completed refreshes (test/diagnostics counter).
    public private(set) var runs = 0
    /// Wall time of the last refresh (fetch + apply), seconds.
    public private(set) var lastLatency: TimeInterval?

    public init(
        model: TeamsViewModel,
        isActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? true }
    ) {
        self.model = model
        self.isActive = isActive
    }

    /// Start the interval loop and the activation hook. Idempotent.
    public func start() {
        guard loop == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick(after: 0) }
        }
        loop = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = Self.delay(active: self.isActive(), failures: self.failures)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { return }
                await self.runNow()
            }
        }
    }

    /// Stop the loop and the activation hook.
    public func stop() {
        loop?.cancel()
        loop = nil
        pending?.cancel()
        pending = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Debounced refresh soon (realtime burst, activation): bursts
    /// inside `after` collapse into one fetch.
    public func kick(after: TimeInterval = 0.5) {
        pending?.cancel()
        pending = Task(priority: .utility) { [weak self] in
            if after > 0 {
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            }
            if Task.isCancelled { return }
            await self?.runNow()
        }
    }

    /// One refresh now: quiet diff-apply, then ownership for new teams.
    public func runNow() async {
        guard let model else { return }
        let start = Date()
        let ok = await model.sync()
        lastLatency = Date().timeIntervalSince(start)
        runs += 1
        failures = ok ? 0 : failures + 1
        if ok { await model.refreshOwnership() }
    }
}
