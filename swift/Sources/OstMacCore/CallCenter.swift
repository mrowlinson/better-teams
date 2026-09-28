// CallCenter.swift — om-call-ux: call phase machine + ring policy.
//
// The core slot (CallInfo.state placing|ringing|connected|ended|failed)
// is signaling truth; this machine is UX truth with four phases:
//
//   idle ──invitation/placed──▶ inviting ──connected──▶ active
//     ▲                          │  │                    │
//     └── cleared ── ended ◀──────┘  └─dismiss/timeout    └─end ─▶ ended
//
// ended is terminal-but-visible: the banner hides, Diagnostics shows the
// outcome plus Clear; cleared returns to idle. A fresh invitation/place
// from ended jumps straight back to inviting.
//
// Invitations arrive on the Trouter feed: trouter_start sets
// TEAMS_MANUAL_CALLS so the core publishes the invite to event_hub
// without auto-answering, scan_events parks it in the call slot and
// emits calls[] in the typed poll, RealtimeFeed.onCall delivers it, and
// CallStore.ingest reduces it here. The UI — never the core — owns the
// accept/decline decision.
//
// Ring policy: a ring that never resolves must not trap the banner —
// dismiss() hides it on demand and checkTimeout(now:) retires it after
// timeoutSecs. Both leave the server slot alone (a late remote
// end/accept still reconciles on the next refresh); Diagnostics keeps
// the dismissed ring actionable (Accept/Decline/Recall) so dismissing
// never strands a call either.
import Foundation

/// UX call phase. Four states only — the core's placing/ringing collapse
/// to inviting, ended/failed to ended.
public enum CallPhase: String, Sendable, Equatable {
    case idle, inviting, active, ended
}

/// Machine inputs. invitation/placed/connected/remoteEnd/rejected arrive
/// from trouter CallEvents and slot reconciliation; localEnd/dismissed/
/// timedOut/cleared are local UI decisions.
public enum CallPhaseEvent: Sendable, Equatable {
    case invitation
    case placed
    case connected
    case remoteEnd
    case rejected
    case localEnd
    case dismissed
    case timedOut
    case cleared
}

/// Pure phase reducer (no clock, no store — fully unit-testable).
public enum CallPhaseReducer {
    public static func next(_ phase: CallPhase, _ event: CallPhaseEvent) -> CallPhase {
        switch (phase, event) {
        case (.idle, .invitation), (.idle, .placed):
            return .inviting
        case (.inviting, .connected):
            return .active
        case (.inviting, .remoteEnd), (.inviting, .rejected),
            (.inviting, .localEnd), (.inviting, .dismissed),
            (.inviting, .timedOut):
            return .ended
        case (.active, .remoteEnd), (.active, .rejected),
            (.active, .localEnd):
            return .ended
        // An active call is never dismissed or timed out — only an
        // explicit end (or the remote end) retires it.
        case (.ended, .cleared):
            return .idle
        case (.ended, .invitation), (.ended, .placed):
            return .inviting
        default:
            return phase // stale/foreign events never move the machine
        }
    }
}

/// Core truth → machine truth.
public enum CallPhaseMapper {
    /// Slot → phase. A nil slot is idle; unknown states stay idle
    /// (fail closed: no banner for unrecognized truth).
    public static func phase(for call: CallInfo?) -> CallPhase {
        guard let call else { return .idle }
        switch call.state {
        case "ringing", "placing": return .inviting
        case "connected": return .active
        case "ended", "failed": return .ended
        default: return .idle
        }
    }

    /// Feed event → machine event. Unknown kinds map to nil (ignored).
    public static func event(for callEvent: CallEvent) -> CallPhaseEvent? {
        switch callEvent.kind {
        case "incoming": return .invitation
        case "end": return .remoteEnd
        case "rejected": return .rejected
        default: return nil
        }
    }
}

/// Ring lifetime: the banner must never trap.
public enum CallRingPolicy {
    /// Seconds a ring may hold the banner before the timeout path
    /// retires it as a missed call. Covers slow accepts; dismiss clears
    /// it any time before that.
    public static let timeoutSecs: TimeInterval = 45

    /// True when a ring started at `startedAt` (epoch secs) has outlived
    /// `timeout`. Undated rings (startedAt 0) never auto-clear.
    public static func isExpired(
        startedAt: UInt64, now: TimeInterval,
        timeout: TimeInterval = timeoutSecs
    ) -> Bool {
        guard startedAt > 0 else { return false }
        return now - TimeInterval(startedAt) >= timeout
    }

    /// The banner shows only for live phases on a non-dismissed call.
    public static func bannerVisible(
        phase: CallPhase, call: CallInfo?, dismissedIDs: Set<String>
    ) -> Bool {
        guard let call, phase == .inviting || phase == .active else { return false }
        return !dismissedIDs.contains(call.id)
    }
}
