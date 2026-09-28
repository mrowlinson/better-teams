// CallPresentation.swift — where calls appear (UI-SPEC §8, DL1): the
// person chooses in Settings ▸ Calls ▸ Show calls; the choice applies
// from the next call (a running call keeps its host).
import Foundation
import Observation
import OstMacCore

public enum CallPresentation: String, CaseIterable, Sendable {
    case mainWindow, separateWindow

    public var title: String {
        switch self {
        case .mainWindow: "In Main Window"
        case .separateWindow: "In a Separate Window"
        }
    }

    static let defaultsKey = "bt.callPresentation"

    /// The setting (default In Main Window).
    @MainActor
    public static var current: CallPresentation { CallSettings.shared.presentation }
}

/// The Show calls setting (Settings ▸ Calls). Persisted in the given
/// defaults; demo mode installs in-memory defaults (`MemoryDefaults`)
/// before the first read, so demo and evidence runs never read or
/// write the person's preference.
@Observable
@MainActor
public final class CallSettings {
    /// Created on first use: `.standard`, or the demo's in-memory
    /// defaults when `useDemoStorage()` ran first.
    public static var shared: CallSettings {
        if let s = installed { return s }
        let s = CallSettings(defaults: .standard)
        installed = s
        return s
    }

    private static var installed: CallSettings?

    /// Demo: the setting lives in `MemoryDefaults` (never `.standard`).
    /// Call before anything reads `shared`.
    public static func useDemoStorage() {
        installed = CallSettings(defaults: MemoryDefaults())
    }

    @ObservationIgnored private var defaults: UserDefaults?

    public var presentation: CallPresentation {
        didSet {
            guard presentation != oldValue else { return }
            defaults?.set(presentation.rawValue, forKey: CallPresentation.defaultsKey)
        }
    }

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        presentation = Self.load(defaults)
    }

    static func load(_ d: UserDefaults?) -> CallPresentation {
        d?.string(forKey: CallPresentation.defaultsKey).flatMap(CallPresentation.init(rawValue:)) ?? .mainWindow
    }

    /// Demo mode: detach from persistent storage (in-memory default).
    public func useVolatileStorage(_ initial: CallPresentation = .mainWindow) {
        defaults = nil
        presentation = initial
    }
}
