// AccountStore.swift — d1-accounts: multi-account list, switch, remove.
//
// One VM per account (AuthViewModel(profile:)); the core holds one
// token file per profile (config-<id>.toml, "default" = legacy
// config.toml). Only the active account streams realtime; background
// accounts serve status reads + refresh without switching.
import Combine
import Foundation

/// Cross-lane per-account namespacing contract (d1-accounts design §4):
/// every per-account store appends `.<accountId>` to its UserDefaults
/// key or nests `<accountId>/` in its disk dir. Device-scoped keys
/// (`om.av.*`, picker flags) stay global.
public enum AccountProfile {
    /// Legacy single-account profile (= legacy config.toml + unmigrated keys).
    public static let defaultID = "default"

    /// UserDefaults key for one account (`base` untouched for default).
    public static func key(_ base: String, for accountID: String) -> String {
        accountID == defaultID ? base : "\(base).\(accountID)"
    }

    /// Disk dir for one account (`base` untouched for default).
    public static func dir(_ base: URL, for accountID: String) -> URL {
        accountID == defaultID ? base : base.appendingPathComponent(sanitized(accountID), isDirectory: true)
    }

    /// Flat filename-safe path segment (never empty, no separators).
    /// Same rule as the core's profile sanitize: alphanumerics +
    /// `._-` kept, the rest `_`, capped at 64 chars.
    public static func sanitized(_ id: String) -> String {
        let clean = id.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) { return String(scalar) }
            if scalar == UnicodeScalar(".") || scalar == UnicodeScalar("_")
                || scalar == UnicodeScalar("-")
            {
                return String(scalar)
            }
            return "_"
        }.joined()
        let trimmed = String(clean.prefix(64))
        return trimmed.isEmpty ? "_" : trimmed
    }

    /// Fresh profile id for add-account (stable afterwards; the token
    /// file + cache namespaces key off it permanently).
    public static func freshID() -> String {
        "acct-" + UUID().uuidString.prefix(8).lowercased()
    }
}

/// Ordered switch stages the app fills in (AccountStore runs them in
/// one MainActor transaction; each stage is sync, reloads kick async
/// work internally so the switch never blocks on network).
public struct AccountSwitchHooks {
    /// Trouter stop + event drain (before the profile flips).
    public var drainRealtime: () -> Void
    /// Conversation reset + ownership re-stamp + cache re-point.
    public var resetForAccount: (AccountRecord) -> Void
    /// Trouter start + list/conversation/teams/presence reload kick.
    public var resume: () -> Void
    /// Delete one account's namespaced caches (remove-account).
    public var removeCaches: (AccountRecord) -> Void
    /// Last account removed (re-read gate status → gate closes).
    public var emptied: () -> Void

    public init(
        drainRealtime: @escaping () -> Void = {},
        resetForAccount: @escaping (AccountRecord) -> Void = { _ in },
        resume: @escaping () -> Void = {},
        removeCaches: @escaping (AccountRecord) -> Void = { _ in },
        emptied: @escaping () -> Void = {}
    ) {
        self.drainRealtime = drainRealtime
        self.resetForAccount = resetForAccount
        self.resume = resume
        self.removeCaches = removeCaches
        self.emptied = emptied
    }
}

/// Account list + active id + per-account VMs. Persists to
/// `om.accounts.v1.*` (injected defaults; tests use a suite).
@MainActor
public final class AccountStore: ObservableObject {
    public nonisolated static let listKey = "om.accounts.v1.list"
    public nonisolated static let activeKey = "om.accounts.v1.active"

    public typealias ProfileSetFn = @Sendable (String) throws -> ProfileResponse
    public typealias SignOutFn = @Sendable (String) throws -> SignOutResponse
    public typealias MakeVM = @MainActor (String) -> AuthViewModel

    @Published public private(set) var accounts: [AccountRecord] = []
    @Published public private(set) var activeID: String?

    public private(set) var vms: [String: AuthViewModel] = [:]
    public var hooks = AccountSwitchHooks()

    private let defaults: UserDefaults
    private let profileSetFn: ProfileSetFn
    private let signOutFn: SignOutFn
    private let makeVM: MakeVM

    public var activeAccount: AccountRecord? {
        guard let id = activeID else { return nil }
        return accounts.first { $0.id == id }
    }

    public var activeVM: AuthViewModel? {
        guard let id = activeID else { return nil }
        return vm(for: id)
    }

    public init(
        defaults: UserDefaults = .standard,
        profileSet: ProfileSetFn? = nil,
        signOut: SignOutFn? = nil,
        makeVM: MakeVM? = nil
    ) {
        self.defaults = defaults
        self.profileSetFn = profileSet ?? { try RustCore.profileSet($0) }
        self.signOutFn = signOut ?? { try RustCore.signOut(profile: $0) }
        self.makeVM = makeVM ?? { AuthViewModel(profile: $0) }
        let list: [AccountRecord] =
            defaults.data(forKey: Self.listKey).flatMap {
                try? JSONDecoder().decode([AccountRecord].self, from: $0)
            } ?? []
        _accounts = Published(initialValue: list)
        let active = defaults.string(forKey: Self.activeKey)
        _activeID = Published(
            initialValue: list.contains { $0.id == active } ? active : list.first?.id)
        // VMs are created lazily via vm(for:).
    }

    /// Per-account VM, created on first use (lazy: init builds none).
    public func vm(for id: String) -> AuthViewModel {
        if let vm = vms[id] { return vm }
        let vm = makeVM(id)
        vms[id] = vm
        return vm
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: Self.listKey)
        }
        defaults.set(activeID, forKey: Self.activeKey)
    }

    /// Adopt the legacy single-account session as the default account
    /// (first launch after upgrade). No-op when accounts exist.
    public func adoptLegacy(displayName: String, upn: String? = nil, userID: String? = nil) {
        guard accounts.isEmpty else { return }
        let record = AccountRecord(
            id: AccountProfile.defaultID, displayName: displayName,
            upn: upn, userID: userID, addedAt: Date().timeIntervalSince1970)
        accounts = [record]
        activeID = record.id
        _ = vm(for: record.id)
        persist()
    }

    /// Test/evidence seam: append an account record WITHOUT flipping the core
    /// profile (`completeAdd` calls the real core). Unknown ids only; the
    /// active account is unchanged.
    public func appendRecordWithoutProfileFlip(
        profile: String, displayName: String, upn: String? = nil, userID: String? = nil
    ) {
        guard !accounts.contains(where: { $0.id == profile }) else { return }
        accounts.append(AccountRecord(
            id: profile, displayName: displayName, upn: upn,
            userID: userID, addedAt: Date().timeIntervalSince1970))
        _ = vm(for: profile)
        persist()
    }

    /// Fresh profile id for an add-account flow (VM created
    /// immediately so the sign-in UI binds to it).
    @discardableResult
    public func beginAdd() -> AuthViewModel {
        vm(for: AccountProfile.freshID())
    }

    /// Record a completed sign-in: appends the account (unknown
    /// profiles only), activates it, flips the core profile.
    /// Returns false when the core profile flip fails (record kept,
    /// active unchanged).
    @discardableResult
    public func completeAdd(
        profile: String, displayName: String, upn: String? = nil, userID: String? = nil
    ) -> Bool {
        if !accounts.contains(where: { $0.id == profile }) {
            accounts.append(AccountRecord(
                id: profile, displayName: displayName, upn: upn,
                userID: userID, addedAt: Date().timeIntervalSince1970))
        }
        _ = vm(for: profile)
        do {
            _ = try profileSetFn(profile)
        } catch {
            persist()
            return false
        }
        activeID = profile
        persist()
        refreshAll()
        return true
    }

    /// Reorder accounts (Settings ▸ Accounts drag; the account menu
    /// lists them in this order). Same offsets
    /// contract as `List.onMove`; out-of-range offsets are a no-op.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty, source.allSatisfy({ accounts.indices.contains($0) }),
              (0...accounts.count).contains(destination) else { return }
        let moving = source.map { accounts[$0] }
        var rest = accounts.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let at = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: at)
        guard rest != accounts else { return }
        accounts = rest
        persist()
    }

    /// Switch accounts in one transaction: drain realtime → flip core
    /// profile → re-stamp UI state → resume. Unknown ids and the
    /// current active id are no-ops (true). A failed core flip keeps
    /// the old account active and resumes its realtime (false).
    @discardableResult
    public func switchTo(_ id: String) -> Bool {
        guard accounts.contains(where: { $0.id == id }) else { return true }
        guard id != activeID else { return true }
        guard let record = accounts.first(where: { $0.id == id }) else { return true }
        hooks.drainRealtime()
        do {
            _ = try profileSetFn(id)
        } catch {
            hooks.resume()
            return false
        }
        activeID = id
        persist()
        hooks.resetForAccount(record)
        refreshAll()
        hooks.resume()
        return true
    }

    /// Remove one account: its core tokens/profile file go, its
    /// namespaced caches go, its VM goes. Removing the active account
    /// falls through to the next account (or clears all when last).
    /// Unknown ids are a no-op (true).
    @discardableResult
    public func removeAccount(_ id: String) -> Bool {
        guard let record = accounts.first(where: { $0.id == id }) else { return true }
        let wasActive = (id == activeID)
        if wasActive { hooks.drainRealtime() }
        do {
            _ = try signOutFn(id)
        } catch {
            if wasActive { hooks.resume() }
            return false
        }
        hooks.removeCaches(record)
        vms.removeValue(forKey: id)
        accounts.removeAll { $0.id == id }
        if wasActive {
            if let next = accounts.first {
                activeID = next.id
                // Best-effort core flip; UI still re-stamps to `next`
                // even if the flip fails (its refresh will surface it).
                _ = try? profileSetFn(next.id)
                hooks.resetForAccount(next)
                refreshAll()
                hooks.resume()
            } else {
                activeID = nil
                _ = try? profileSetFn(AccountProfile.defaultID)
                hooks.emptied()
            }
        }
        persist()
        return true
    }

    /// Refresh every account's status (pure core reads; per-account
    /// AuthState for the switcher; relaunch restore).
    public func refreshAll() {
        for vm in vms.values {
            Task { await vm.refreshStatus() }
        }
    }
}
