// AppSettings.swift — app-level preferences with no core store behind
// them (UI-SPEC §9.4 General and Chats): menu bar extra, Dock badge,
// banners while active, default section, Return-to-send, quick composer.
// Core settings bind to their core stores (AppState); this holds only
// the rest. Persisted in the given defaults; demo installs in-memory
// defaults (`MemoryDefaults`) before the first read, like CallSettings,
// so demo and evidence runs never read or write the person's settings.
import Combine
import Foundation
import Observation
import OstMacCore

@Observable
@MainActor
final class AppSettings {
    static var shared: AppSettings {
        if let s = installed { return s }
        let s = AppSettings(defaults: .standard)
        installed = s
        return s
    }

    private static var installed: AppSettings?

    /// Demo: every setting lives in `MemoryDefaults` (never `.standard`).
    static func useDemoStorage() {
        installed = AppSettings(defaults: MemoryDefaults())
    }

    enum Key {
        static let menuBar = "bt.settings.showInMenuBar"
        static let dockBadge = "bt.settings.showDockBadge"
        static let bannersActive = "bt.settings.bannersWhileActive"
        static let defaultSection = "bt.settings.defaultSection"
        static let returnSends = "bt.settings.returnSends"
        static let quickComposer = "bt.settings.quickComposer"
    }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let isMemory: Bool
    @ObservationIgnored private let subject = PassthroughSubject<Void, Never>()
    /// Fires after any setting changes (AppKit observers: Dock badge,
    /// menu bar extra, foreground banner rule, hotkey).
    @ObservationIgnored var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    /// General ▸ Show in menu bar (off by default, §9.2).
    var showInMenuBar: Bool { didSet { save(showInMenuBar, Key.menuBar, oldValue) } }
    /// General ▸ Dock badge (on by default).
    var showDockBadge: Bool { didSet { save(showDockBadge, Key.dockBadge, oldValue) } }
    /// General ▸ Banners while active (opt-in, §9.3).
    var bannersWhileActive: Bool { didSet { save(bannersWhileActive, Key.bannersActive, oldValue) } }
    /// General ▸ Default section: shown when a window has no saved state.
    var defaultSection: String { didSet { save(defaultSection, Key.defaultSection, oldValue) } }
    /// Chats ▸ Return sends (⇧Return inserts a newline); off swaps them.
    var returnSends: Bool { didSet { save(returnSends, Key.returnSends, oldValue) } }
    /// Chats ▸ Quick composer (opt-in, §5.7): the global hotkey panel.
    var quickComposer: Bool { didSet { save(quickComposer, Key.quickComposer, oldValue) } }
    /// Demo only: General ▸ Open at login, never the real login item.
    var demoLaunchAtLogin = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isMemory = defaults is MemoryDefaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
        showInMenuBar = bool(Key.menuBar, false)
        showDockBadge = bool(Key.dockBadge, true)
        bannersWhileActive = bool(Key.bannersActive, false)
        defaultSection = defaults.string(forKey: Key.defaultSection) ?? SectionID.chat.key
        returnSends = bool(Key.returnSends, true)
        quickComposer = bool(Key.quickComposer, false)
    }

    /// The quick-composer shortcut changed (stored with the core prefs).
    func noteQuickComposerChange() { subject.send() }

    private func save<T: Equatable>(_ v: T, _ key: String, _ old: T) {
        guard v != old else { return }
        defaults.set(v, forKey: key)
        subject.send()
    }

    /// Sections a window can open on (§9.4 General ▸ default section).
    static let defaultSections: [SectionID] = [.activity, .chat, .teams, .calendar, .calls, .files]
}
