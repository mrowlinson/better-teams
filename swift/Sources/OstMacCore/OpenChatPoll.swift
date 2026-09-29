// OpenChatPoll.swift — §106 (SENDFIX): fallback poll for the open chat.
//
// Live push (Trouter) is the fast path for new messages, but push can go
// silent (no chat events reach the endpoint; the owner's reply never
// showed). While a chat is open and a window is on screen, its newest
// page is re-read quietly on an adaptive cadence: fast right after
// activity (open, focus, own send, an arrival), slower as it goes quiet.
// Hidden/minimized = no polling (focus polls at once). The refresh it
// drives is diffed (`mergedNewest`): nothing flashes, nothing clears.
import Foundation

/// Cadence by time since the chat's last activity.
public struct OpenChatPollPolicy: Sendable, Equatable {
    /// Interval while the chat is hot (≤ `hotWindow` since activity).
    public var hot: TimeInterval = 2
    /// Interval while warm (≤ `warmWindow`).
    public var warm: TimeInterval = 5
    /// Interval once quiet.
    public var idle: TimeInterval = 15
    public var hotWindow: TimeInterval = 60
    public var warmWindow: TimeInterval = 300

    public init() {}

    public func interval(sinceActivity quiet: TimeInterval) -> TimeInterval {
        if quiet < hotWindow { return hot }
        if quiet < warmWindow { return warm }
        return idle
    }
}

/// Poll scheduler (clock injectable; tests drive it).
@MainActor
public final class OpenChatPoller {
    public let policy: OpenChatPollPolicy
    private let now: () -> Date
    public private(set) var lastPoll: Date?
    public private(set) var lastActivity: Date

    public init(policy: OpenChatPollPolicy = OpenChatPollPolicy(), now: @escaping () -> Date = Date.init) {
        self.policy = policy
        self.now = now
        self.lastActivity = now()
    }

    /// Something happened in the open chat (open, send, arrival, focus):
    /// back to the fast cadence. `pollNow` makes the next check due.
    public func noteActivity(pollNow: Bool = false) {
        lastActivity = now()
        if pollNow { lastPoll = nil }
    }

    /// Whether a poll is due now; marks it fired when true. Never while
    /// no chat is open, no window is visible, or a load/poll is running.
    public func shouldPoll(chatOpen: Bool, visible: Bool, busy: Bool) -> Bool {
        guard chatOpen, visible, !busy else { return false }
        let t = now()
        let interval = policy.interval(sinceActivity: t.timeIntervalSince(lastActivity))
        if let last = lastPoll, t.timeIntervalSince(last) < interval { return false }
        lastPoll = t
        return true
    }
}
