// PrivacyStore.swift — C6 SERVER-STATE (SET-10 remainder): standalone
// outbound-signal toggles.
//
// Ghost mode's sub-toggles only bite under its master switch; these two
// stand alone (Teams Settings ▸ Privacy parity): "Send read receipts"
// and "Broadcast my presence" each default ON (current behavior, byte
// identical when untouched) and each gate its sender independently of
// ghost. OFF drops the signal the same way a ghost hold does: the
// receipt position stays unsent (retryable on re-enable), a manual
// presence set never happens (no echo, no schedule pause). Toggles
// persist per-field (QuietHours/Ghost precedent); nothing here counts.
// Incoming receipts/presence still render (peer paths never gated).
import Combine
import Foundation

/// Standalone privacy toggles: receipt sending + presence broadcast.
@MainActor
public final class PrivacyStore: ObservableObject {
    public nonisolated static let receiptsKey = "privacy.sendReadReceipts"
    public nonisolated static let presenceKey = "privacy.broadcastPresence"

    private let defaults: UserDefaults

    /// Send own read positions (consumption horizon). OFF = never send.
    @Published public var sendReadReceipts = true {
        didSet { defaults.set(sendReadReceipts, forKey: Self.receiptsKey) }
    }
    /// Publish own presence (manual sets). OFF = sets never happen.
    @Published public var broadcastPresence = true {
        didSet { defaults.set(broadcastPresence, forKey: Self.presenceKey) }
    }

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let receipts = defaults.object(forKey: Self.receiptsKey) != nil
            ? defaults.bool(forKey: Self.receiptsKey)
            : true
        let presence = defaults.object(forKey: Self.presenceKey) != nil
            ? defaults.bool(forKey: Self.presenceKey)
            : true
        _sendReadReceipts = Published(initialValue: receipts)
        _broadcastPresence = Published(initialValue: presence)
    }
}
