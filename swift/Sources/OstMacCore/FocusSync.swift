// FocusSync.swift — e2-attention lane: macOS Focus sync.
//
// System Focus/DND quiets the app with EXACTLY quiet-hours semantics:
// the app folds `FocusSyncStore.quietNow` into the same quiet snapshot
// the ingest path and the rules gate already read (ChatFilter reason
// "quiet-hours" is reused — ChatFilter is read-only for this lane).
//
// R1 mechanism (probed 2026-09-25, macOS 27, NO public API reads Focus
// state): best-effort parse of ~/Library/DoNotDisturb/DB/Assertions.json
// — a non-empty `storeActiveAssertionRecords` in data[0] means a Focus
// mode is active. Verified shape with Focus OFF (only invalidation
// records); the active shape is inferred from Apple's key naming and
// the parser is tolerant (missing key = inactive, never an error).
// This is a private artifact: it may move across OS releases, so every
// failure path fails OPEN (unreadable ⇒ not quiet, never stuck silent)
// and records `error` for Diagnostics. The `FocusReader` seam keeps
// tests hermetic (mock reader, never the live system in tests).
import Foundation

/// Focus-state probe: true when a system Focus mode is active.
/// Throws when the state is unreadable (store fails open).
public typealias FocusReader = @Sendable () throws -> Bool

/// Best-effort Focus-state reader (R1 mechanism + pure parser).
public enum FocusRead {
    /// Live probe: parse the system assertion store. Throws on any
    /// failure (missing file, malformed JSON) — callers fail open.
    public static func live() throws -> Bool {
        let data = try Data(contentsOf: assertionsURL)
        return try isActive(assertionsData: data)
    }

    /// Private assertion-store location (observed macOS 27).
    public static var assertionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }

    /// Pure parser: true when the store holds ≥1 active assertion.
    /// Missing `data`/key shapes mean inactive (tolerant of OS drift);
    /// only malformed JSON throws.
    public static func isActive(assertionsData: Data) throws -> Bool {
        let json = try JSONSerialization.jsonObject(with: assertionsData)
        guard let root = json as? [String: Any],
              let data = root["data"] as? [[String: Any]],
              let first = data.first
        else { return false }
        guard let active = first["storeActiveAssertionRecords"] else { return false }
        guard let list = active as? [Any] else { return false }
        return !list.isEmpty
    }
}

/// Focus-sync state. Owns the enabled toggle and the cached Focus
/// reading; the app refreshes from its 2s tick (cheap file read, at
/// most tick rate — s7-tickstorm precedent) and assigns on change only
/// (idle ticks publish nothing).
@MainActor
public final class FocusSyncStore: ObservableObject {
    public nonisolated static let enabledKey = "focusSync.enabled"

    private let defaults: UserDefaults
    private let reader: FocusReader

    @Published public var syncEnabled = true {
        didSet { defaults.set(syncEnabled, forKey: Self.enabledKey) }
    }
    /// Cached Focus reading (session-only; re-polled on tick).
    @Published public private(set) var focusActive = false
    /// Last probe failure (cleared on the next successful read).
    @Published public private(set) var error: String?

    /// Main-actor init (Swift 6): View inits are main-actor, so views
    /// can still take a default; the stored state is main-actor-isolated.
    public init(
        defaults: UserDefaults = .standard,
        reader: FocusReader? = nil
    ) {
        self.defaults = defaults
        self.reader = reader ?? { try FocusRead.live() }
        // gap-g5: default ON for fresh installs (no stored key). Stored
        // choice always wins — upgrades keep whatever the user set.
        let enabled = defaults.object(forKey: Self.enabledKey) != nil
            ? defaults.bool(forKey: Self.enabledKey)
            : true
        _syncEnabled = Published(initialValue: enabled)
        _focusActive = Published(initialValue: false)
        _error = Published(initialValue: nil)
    }

    /// True when Focus sync quiets the app (sync ON + Focus active).
    /// The app ORs this with `QuietHoursStore.isQuietNow` — identical
    /// semantics downstream (same snapshot, same reason).
    public var quietNow: Bool {
        syncEnabled && focusActive
    }

    /// Re-poll the reader. Assigns on change only (no per-tick
    /// publishes while idle). Failure fails open: cached state drops
    /// to inactive and the error is recorded (never stuck quiet).
    /// State flips and probe failures log one [focus-sync] line each
    /// (gap-g5 live-observation hook; idle ticks stay silent).
    public func refresh() {
        let reader = reader
        do {
            let active = try reader()
            if active != focusActive {
                focusActive = active
                print("[focus-sync] focusActive=\(active)")
            }
            if error != nil {
                error = nil
                print("[focus-sync] probe recovered")
            }
        } catch {
            if focusActive {
                focusActive = false
                print("[focus-sync] focusActive=false (probe failed, failing open)")
            }
            let message = String(describing: error)
            if self.error != message {
                self.error = message
                print("[focus-sync] probe error: \(message)")
            }
        }
    }
}
