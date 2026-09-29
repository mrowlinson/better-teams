// AccountCoreRunner.swift — gap-g2: profile-aware core calls.
//
// The Rust core serves ONE active profile (global); the Swift side
// holds N accounts. Main-window stores call `RustCore.*` direct (nil
// account = active, unchanged). Account-window graphs stamp their
// account id + inject a runner that flip-flops the global around each
// blocking call. Two pieces:
//
//   AccountCoreRunner — runs one blocking op under an account. The
//     default (DirectAccountCoreRunner) runs it straight through; the
//     App injects a flip-flop (feed pause + gated flip, see
//     AppState.AccountWindowRunner) for inactive-account graphs.
//   AccountProfileGate — serializes every profile mutation (switches
//     via AccountStore.profileSet, relaunch restore) against every
//     flip-flop, and records the active profile so flip-backs land on
//     the CURRENT active even when a switch interleaves mid-op.
//
// Locking: one NSLock, held across flip+op+unflip. Ops run off-main
// (the stores call inside Task.blocking); switches block MainActor
// only while an op is in flight (one blocking read, ~a second worst
// case). The gate never hops to MainActor, so no deadlock.
import Foundation

/// Runs one blocking core op under an account profile. Sync —
/// callers invoke it inside their off-main detached closures.
public protocol AccountCoreRunner: Sendable {
    func run<T>(_ op: () throws -> T, accountID: String?) throws -> T
}

/// Default runner: the op runs direct (active profile, zero flips).
/// Main-window stores keep this forever.
public struct DirectAccountCoreRunner: AccountCoreRunner {
    public init() {}

    public func run<T>(_ op: () throws -> T, accountID: String?) throws -> T {
        try op()
    }
}

/// Recording runner (tests): notes every account id it ran under.
public final class RecordingAccountCoreRunner: AccountCoreRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _accounts: [String?] = []

    public init() {}

    public var accounts: [String?] {
        lock.lock(); defer { lock.unlock() }
        return _accounts
    }

    public func run<T>(_ op: () throws -> T, accountID: String?) throws -> T {
        lock.lock()
        _accounts.append(accountID)
        lock.unlock()
        return try op()
    }
}

/// Serializes profile flips + inactive-profile ops. `flip` is the raw
/// `RustCore.profileSet` (injected so tests run flip-free).
/// @unchecked: every read/write of the two vars holds `lock`.
public final class AccountProfileGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active: String?
    private var lastFlipErrorValue: String?

    public init() {}

    /// Seed the recorded active profile (App init, from the restored
    /// AccountStore — the one truth the gate can't read itself).
    public func seed(_ accountID: String) {
        lock.lock(); defer { lock.unlock() }
        active = accountID
    }

    /// Recorded active profile (nil until seeded).
    public var activeID: String? {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// Last flip failure (Diagnostics; cleared on the next success).
    public var lastFlipError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastFlipErrorValue
    }

    /// Account-switch write: flip the core global + record it. A failed
    /// flip records nothing (the core is still on the old profile, so
    /// the record stays true). Returns the flip response (AccountStore
    /// profileSet shape).
    @discardableResult
    public func setActive(
        _ accountID: String, flip: (String) throws -> ProfileResponse
    ) throws -> ProfileResponse {
        lock.lock(); defer { lock.unlock() }
        let out: ProfileResponse
        do {
            out = try flip(accountID)
        } catch {
            lastFlipErrorValue = String(describing: error)
            throw error
        }
        active = accountID
        lastFlipErrorValue = nil
        return out
    }

    /// Run one op under `accountID`: direct when it is nil/blank, the
    /// recorded active, or the gate is unseeded (fail-open = today's
    /// behavior); otherwise flip there, run, flip back. The flip-back
    /// target is read under the same lock, so a switch that lands
    /// mid-op still restores the CURRENT active. A failed flip-back
    /// retries once, then records the desync (the op's own result or
    /// error still returns — the caller owns it).
    public func run<T>(
        under accountID: String?, _ op: () throws -> T,
        flip: (String) throws -> ProfileResponse
    ) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let target = (accountID ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !target.isEmpty, let back = active, target != back else {
            return try op()
        }
        do {
            _ = try flip(target)
        } catch {
            lastFlipErrorValue = String(describing: error)
            throw error
        }
        do {
            let out = try op()
            flipBack(to: back, flip: flip)
            return out
        } catch {
            flipBack(to: back, flip: flip)
            throw error
        }
    }

    /// Flip-back with one retry. Must hold `lock`.
    private func flipBack(
        to back: String, flip: (String) throws -> ProfileResponse
    ) {
        do {
            _ = try flip(back)
            lastFlipErrorValue = nil
        } catch {
            do {
                _ = try flip(back)
                lastFlipErrorValue = nil
            } catch {
                lastFlipErrorValue = String(describing: error)
            }
        }
    }
}
