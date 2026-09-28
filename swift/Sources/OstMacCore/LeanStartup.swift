// LeanStartup.swift — top10-menubar: lean startup + menu-bar mode.
//
// Three pieces, all launch/menu-bar scoped:
//
// 1. ColdStart: launch-timeline probe. arm() at process entry, mark()
//    at each launch milestone; every mark logs `[coldstart] <name>
//    +<ms>ms` to stderr and report() renders the whole timeline for
//    proof/Diagnostics. noteMediaInit() counts AVFoundation/media
//    object creation so the log proves zero media work before first
//    call join.
// 2. LoginItemStore: opt-IN login item (ServiceManagement seam).
//    Default off; init never touches the service — only an explicit
//    set(_:) call registers/unregisters, so the app can never
//    re-enable itself. Settings owns the toggle.
// 3. MenuBarFormat: pure menu-bar label + unread-row math.
import Foundation
import ServiceManagement
import Combine

// MARK: - Cold-start probe

/// Launch-timeline probe. Main-thread only (all marks fire on-main);
/// the lock guards the media counter's off-main note sites.
public enum ColdStart {
    private static let lock = NSLock()
    private static var t0: UInt64?
    private static var marks: [(name: String, ms: Double)] = []
    private static var mediaInits: [String] = []

    /// Arm at process entry (first line of App.init). Re-arms clean.
    public static func arm() {
        lock.lock(); defer { lock.unlock() }
        t0 = DispatchTime.now().uptimeNanoseconds
        marks = []
        mediaInits = []
    }

    /// Tests + previews only: clear without arming.
    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        t0 = nil
        marks = []
        mediaInits = []
    }

    /// Milliseconds since arm (nil before arm).
    public static func elapsedMs() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let t0 else { return nil }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    /// Record + log one milestone. No-op before arm (never crashes
    /// previews/tests that skip arm()).
    public static func mark(_ name: String) {
        lock.lock()
        guard let t0 else { lock.unlock(); return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        marks.append((name, ms))
        lock.unlock()
        print("[coldstart] \(name) +\(String(format: "%.1f", ms))ms")
        fflush(stdout) // launch probe: crash/kill-safe line delivery
    }

    /// True once `name` has a mark (one-shot gates).
    public static func hasMarked(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return marks.contains { $0.name == name }
    }

    /// All marks in order (proof readback).
    public static func timeline() -> [(name: String, ms: Double)] {
        lock.lock(); defer { lock.unlock() }
        return marks
    }

    /// Count one media-object creation (AVCaptureSession, screen-share
    /// model, …). The launch path must reach startup-done with zero.
    public static func noteMediaInit(_ what: String) {
        lock.lock(); defer { lock.unlock() }
        mediaInits.append(what)
    }

    /// Media inits so far (launch-gate readback).
    public static func mediaInitCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return mediaInits.count
    }

    /// One line for the launch log: media work before this point.
    public static func mediaInitReport() -> String {
        lock.lock(); defer { lock.unlock() }
        if mediaInits.isEmpty { return "media.inits-before-join: 0" }
        return "media.inits-before-join: \(mediaInits.count) (\(mediaInits.joined(separator: ", ")))"
    }

    /// Full timeline + media line (proof/Diagnostics paste).
    public static func report() -> String {
        lock.lock(); defer { lock.unlock() }
        var lines = marks.map {
            "[coldstart] \($0.name) +\(String(format: "%.1f", $0.ms))ms"
        }
        lines.append(
            mediaInits.isEmpty
                ? "media.inits-before-join: 0"
                : "media.inits-before-join: \(mediaInits.count) (\(mediaInits.joined(separator: ", ")))")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Opt-in login item

/// ServiceManagement seam (the fake pins the never-re-enables contract).
public protocol LoginItemService: Sendable {
    /// True when the main-app login item is currently registered.
    func isRegistered() -> Bool
    func register() throws
    func unregister() throws
}

/// Live seam: the app's own login item (macOS 13+ API).
public struct SMLoginItemService: LoginItemService {
    public init() {}

    public func isRegistered() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// Opt-IN launch-at-login. Default off; init performs zero service
/// calls — only an explicit set(_:) (the Settings toggle) registers
/// or unregisters, so the app never re-enables itself. Failures
/// surface in `error` and the toggle stays where it was.
@MainActor
public final class LoginItemStore: ObservableObject {
    @Published public private(set) var enabled = false
    @Published public private(set) var busy = false
    @Published public private(set) var error: String?

    private let service: any LoginItemService

    /// Zero service calls (contract: never self-enables, never even reads).
    /// Nonisolated so views can take a default in their (nonisolated)
    /// inits; all members stay main-actor-isolated.
    public nonisolated init(service: (any LoginItemService)? = nil) {
        self.service = service ?? SMLoginItemService()
    }

    /// Adopt the live registration state (Settings appear, post-toggle
    /// confirm). Read-only — never registers.
    public func refresh() {
        enabled = service.isRegistered()
    }

    /// Explicit user action only. Registers on true, unregisters on
    /// false; re-reads after (a throw leaves state + surfaces error).
    public func set(_ on: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            error = nil
        } catch {
            self.error = "Login item: \(error.localizedDescription)"
        }
        enabled = service.isRegistered()
    }
}

// MARK: - Menu-bar math (pure)

/// One unread row for the menu-bar popover.
public struct MenuBarUnreadRow: Sendable, Equatable {
    public let chatID: String
    public let name: String
    public let count: Int

    public init(chatID: String, name: String, count: Int) {
        self.chatID = chatID
        self.name = name
        self.count = count
    }
}

public enum MenuBarFormat {
    /// Menu-bar label text for a total: nil at zero (dot only), else
    /// the decimal count.
    public static func labelText(forTotal total: Int) -> String? {
        total > 0 ? "\(total)" : nil
    }

    /// Top unread rows: chats with a visible badge (auto count +
    /// mark-unread overrides), highest count first, capped at `limit`.
    /// Unknown ids (counts for chats not in the list) are skipped —
    /// the popover only opens rows it can name.
    public static func unreadRows(
        chats: [ChatItem],
        counts: [String: Int],
        overrides: Set<String>,
        limit: Int = 8
    ) -> [MenuBarUnreadRow] {
        let names = Dictionary(uniqueKeysWithValues: chats.map { ($0.chatId, $0.name) })
        var rows: [MenuBarUnreadRow] = []
        var ids = Set(counts.keys)
        ids.formUnion(overrides)
        for id in ids {
            guard let name = names[id] else { continue }
            let n = UnreadStore.visibleCount(
                auto: counts[id] ?? 0, overridden: overrides.contains(id))
            guard n > 0 else { continue }
            rows.append(MenuBarUnreadRow(chatID: id, name: name, count: n))
        }
        rows.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name < $1.name
        }
        return Array(rows.prefix(max(limit, 0)))
    }
}
