// QuickComposer.swift — f1-composer lane: global quick-composer model.
// Pure Foundation core (no AppKit/Carbon): the hotkey combo value type,
// UserDefaults prefs, the system/in-app reject list, the summon/Esc
// state machine, the send gate, and the open-store-vs-direct routing
// rule. Registration lives in QuickComposerHotKey.swift (Carbon seam),
// the panel in the OstMac target, the view in OstMacChatList.
import Foundation

public extension Notification.Name {
    /// Posted when the combo or enable toggle changes; AppState
    /// re-registers the global hotkey without a relaunch.
    static let quickComposePrefsChanged = Notification.Name("om-quickcompose.prefsChanged")
}

/// A global hotkey combo: macOS virtual keyCode + Carbon modifier bits.
/// Carbon bits (not NSEvent flags) so this file stays AppKit-free; the
/// recorder converts via ``carbonModifiers(cocoaFlags:)``.
public struct QuickComposeCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    /// Carbon modifier bits (cmdKey/shiftKey/optionKey/controlKey).
    public static let cmdModifier: UInt32 = 0x0100
    public static let shiftModifier: UInt32 = 0x0200
    public static let optionModifier: UInt32 = 0x0800
    public static let controlModifier: UInt32 = 0x1000

    /// Default: Ctrl+Cmd+M — clear of Cmd+K/Cmd+J/Cmd+Shift+I and of
    /// every pinned system combo (bare Cmd+M minimizes; Ctrl added).
    public static let `default` = QuickComposeCombo(
        keyCode: 46, modifiers: cmdModifier | controlModifier)

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// NSEvent.ModifierFlags raw value → Carbon bits (caps/numeric/
    /// help/function ignored). Takes the raw value so callers pass
    /// `event.modifierFlags.rawValue` without this file importing AppKit.
    public static func carbonModifiers(cocoaFlags: UInt) -> UInt32 {
        var out: UInt32 = 0
        if cocoaFlags & 0x20000 != 0 { out |= shiftModifier }
        if cocoaFlags & 0x40000 != 0 { out |= controlModifier }
        if cocoaFlags & 0x80000 != 0 { out |= optionModifier }
        if cocoaFlags & 0x100000 != 0 { out |= cmdModifier }
        return out
    }

    /// Display string, modifiers low-to-high (⌃⌥⇧⌘) + key label.
    public var displayString: String {
        var s = ""
        if modifiers & Self.controlModifier != 0 { s += "⌃" }
        if modifiers & Self.optionModifier != 0 { s += "⌥" }
        if modifiers & Self.shiftModifier != 0 { s += "⇧" }
        if modifiers & Self.cmdModifier != 0 { s += "⌘" }
        return s + Self.keyLabel(for: keyCode)
    }

    /// Nil when the combo is usable as a global hotkey; otherwise the
    /// inline reason shown by the Settings recorder.
    public var rejectedReason: String? {
        if modifiers == 0 {
            return "Add a modifier (⌘, ⌃, ⌥, or ⇧) — bare keys can't be global hotkeys."
        }
        if modifiers == Self.shiftModifier {
            return "Shift alone isn't enough — add ⌘, ⌃, or ⌥ (Shift+letter fires while typing)."
        }
        if keyCode == 53 {
            return "Esc can't be a hotkey — it dismisses the composer."
        }
        if keyCode == 48 {
            return "Tab can't be a hotkey — it fires on every focus move."
        }
        let cmd = Self.cmdModifier
        if modifiers == cmd, let owner = Self.cmdSingles[keyCode] {
            return "⌘\(Self.keyLabel(for: keyCode)) is taken by \(owner)."
        }
        if modifiers == Self.controlModifier, keyCode == 49 {
            return "⌃Space is taken by the macOS input switcher."
        }
        if modifiers == (cmd | Self.shiftModifier), keyCode == 34 {
            return "⇧⌘I is taken by Better Teams sign-in."
        }
        return nil
    }

    /// Bare-Cmd single-key owners (system first, then in-app).
    private static let cmdSingles: [UInt32: String] = [
        12: "macOS Quit", // Q
        13: "macOS window close", // W
        48: "macOS app switcher", // Tab (also blanket-rejected above)
        49: "macOS Spotlight", // Space
        50: "macOS window cycling", // `
        4: "macOS Hide", // H
        46: "macOS Minimize", // M (default adds Ctrl, so it clears this)
        43: "macOS Settings", // ,
        3: "macOS Find", // F
        40: "Better Teams jump-to", // K
        38: "Better Teams meeting join", // J
    ]

    /// macOS virtual-keycode → label (letters, digits, F1–F16, common
    /// punctuation + whitespace keys; unknown codes show numerically).
    public static func keyLabel(for keyCode: UInt32) -> String {
        if let label = keyLabels[keyCode] { return label }
        return "key \(keyCode)"
    }

    private static let keyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7",
        99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4",
        119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑",
    ]
}

/// UserDefaults persistence for the quick-composer hotkey. Keys are
/// `om.quickcompose.*` (scope-pinned); the enable toggle defaults true.
public enum QuickComposerPrefs {
    public static let comboKey = "om.quickcompose.combo"
    public nonisolated static let enabledKey = "om.quickcompose.enabled"

    public static func loadCombo(defaults: UserDefaults = .standard) -> QuickComposeCombo {
        guard let data = defaults.data(forKey: comboKey),
              let combo = try? JSONDecoder().decode(QuickComposeCombo.self, from: data),
              combo.rejectedReason == nil
        else { return .default }
        return combo
    }

    public static func saveCombo(_ combo: QuickComposeCombo, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        defaults.set(data, forKey: comboKey)
    }

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }
}

/// Summon/visibility + Esc state machine (jump-palette precedent: Esc
/// with text clears the newest field first; Esc on empty dismisses).
/// The view mirrors this exactly; dismiss touches no main-window state.
public struct QuickComposerModel: Equatable, Sendable {
    public var isVisible = false
    public var targetQuery = ""
    public var message = ""

    public init() {}

    public mutating func summon() {
        isVisible = true
        targetQuery = ""
        message = ""
    }

    public enum EscOutcome: Equatable, Sendable {
        case clearedMessage
        case clearedQuery
        case dismissed
    }

    @discardableResult
    public mutating func esc() -> EscOutcome {
        if !message.isEmpty {
            message = ""
            return .clearedMessage
        }
        if !targetQuery.isEmpty {
            targetQuery = ""
            return .clearedQuery
        }
        isVisible = false
        return .dismissed
    }

    /// Send gate: signed-in (or demo) plus non-blank text. Mirrors the
    /// `ConversationStore.send` trim guard so the button can disable
    /// without ever attempting a blank post.
    public static func canSend(text: String, signedIn: Bool) -> Bool {
        signedIn && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Open-timeline vs direct-core routing (AppState.quickSend wires it):
/// the picked target IS the open chat → send through the open
/// ConversationStore so the optimistic own-bubble lands in the
/// main-window timeline; otherwise post direct to core (no selection
/// change, no list refetch — zero-refresh).
public enum QuickComposerRouting {
    public static func sendThroughOpenStore(targetID: String, openChatID: String?) -> Bool {
        guard let open = openChatID, !open.isEmpty else { return false }
        return targetID == open
    }
}
