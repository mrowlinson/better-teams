// GhostMode.swift — f1-ghost lane: read-privacy controls.
//
// Ghost mode suppresses the user's OWN outbound Teams signals while
// on: read-receipt PUTs (consumption horizon) and presence writes.
// Incoming receipts/presence still render (peer paths never gated);
// local unread badges still clear on open (accept-3 choice (i) —
// UnreadStore has no ghost seam by design); presence ghost is a pure
// freeze — enabling writes nothing, the last server value lingers
// (accept-4 choice (ii), no Offline mask). Other clients (phone/web)
// still mark read — this client only.
//
// One master toggle + two independent sub-toggles (receipts,
// presence). Master off forces both signals live regardless of
// sub-toggle positions. Toggles persist per-field (QuietHours
// precedent); suppressed/held counters are session-only and surface
// in Diagnostics ONLY. Gates live in the owning stores (ReceiptStore,
// PresenceStore, PresenceScheduleStore) behind an injected GhostStore
// reference — never a global — so tests pin zero-send/zero-set via
// the same injected-transport seams.
import Foundation

/// Ghost-mode state: master + per-signal toggles + session counters.
@MainActor
public final class GhostStore: ObservableObject {
    public nonisolated static let masterKey = "ghostMode.master"
    public nonisolated static let receiptsKey = "ghostMode.suppressReceipts"
    public nonisolated static let presenceKey = "ghostMode.suppressPresence"

    private let defaults: UserDefaults

    /// Master switch: off forces both signals live (subs ignored).
    @Published public var master = false {
        didSet { defaults.set(master, forKey: Self.masterKey) }
    }
    /// Suppress own read-receipt PUTs (applies only under master).
    @Published public var suppressReceipts = false {
        didSet { defaults.set(suppressReceipts, forKey: Self.receiptsKey) }
    }
    /// Suppress own presence writes (applies only under master).
    @Published public var suppressPresence = false {
        didSet { defaults.set(suppressPresence, forKey: Self.presenceKey) }
    }
    /// Session read-receipt sends suppressed (never persisted;
    /// Diagnostics only).
    @Published public private(set) var suppressedReceipts = 0
    /// Session presence sets held (never persisted; Diagnostics only).
    @Published public private(set) var heldPresence = 0

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let master = defaults.object(forKey: Self.masterKey) != nil
            ? defaults.bool(forKey: Self.masterKey)
            : false
        let receipts = defaults.object(forKey: Self.receiptsKey) != nil
            ? defaults.bool(forKey: Self.receiptsKey)
            : false
        let presence = defaults.object(forKey: Self.presenceKey) != nil
            ? defaults.bool(forKey: Self.presenceKey)
            : false
        _master = Published(initialValue: master)
        _suppressReceipts = Published(initialValue: receipts)
        _suppressPresence = Published(initialValue: presence)
        _suppressedReceipts = Published(initialValue: 0)
        _heldPresence = Published(initialValue: 0)
    }

    /// True when own read-receipt sends must be suppressed.
    public var shouldSuppressReceipts: Bool { master && suppressReceipts }

    /// True when own presence writes must be held.
    public var shouldSuppressPresence: Bool { master && suppressPresence }

    /// Count one suppressed read-receipt send (the send stays
    /// retryable — `sent[]` does NOT advance, same rule as failure).
    public func noteSuppressedReceipt() {
        suppressedReceipts += 1
    }

    /// Count one held presence set (manual AND scheduled sets are
    /// dropped, never replayed — no stale Busy after the user picked
    /// Available).
    public func noteHeldPresence() {
        heldPresence += 1
    }

    /// Clear session counters (sign-out). Toggles persist.
    public func clear() {
        suppressedReceipts = 0
        heldPresence = 0
    }
}
