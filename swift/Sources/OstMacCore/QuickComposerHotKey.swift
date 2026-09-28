// QuickComposerHotKey.swift — f1-composer lane: global-hotkey
// registration via Carbon RegisterEventHotKey (no Accessibility
// permission, no new dependency). This file is the ONLY Carbon
// surface: a future CGEventTap swap touches nothing else. The combo
// value + reject list live in QuickComposer.swift (pure, tested).
import Carbon
import Foundation

/// C trampoline for kEventHotKeyPressed (a Swift closure cannot serve
/// as an EventHandlerUPP; a module-global func converts implicitly).
private func quickComposeHotKeyProc(
    _: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?
) -> OSStatus {
    QuickComposerHotKey.fireActive()
    return noErr
}

/// One global hotkey (single Carbon hotkey id). Main-thread use;
/// `onFire` always runs on the main queue.
public final class QuickComposerHotKey {
    private static let signature = OSType(0x6F6D7163) // 'omqc'
    private static let hotKeyID: UInt32 = 1

    /// Installed once per process (InstallEventHandler is idempotent
    /// here only because we track it).
    nonisolated(unsafe) private static var handlerInstalled = false
    /// Fire closure of the currently registered instance only.
    nonisolated(unsafe) private static var activeFire: (() -> Void)?
    nonisolated(unsafe) private static var activeOwner: ObjectIdentifier?

    /// Fired (main queue) when the registered combo is pressed anywhere.
    public var onFire: (() -> Void)?
    public private(set) var isRegistered = false
    public private(set) var activeCombo: QuickComposeCombo?
    private var hotKeyRef: EventHotKeyRef?

    public init() {}

    deinit { unregister() }

    /// Reconcile registration with prefs: enabled + usable combo →
    /// registered (re-registered when the combo changed); otherwise
    /// unregistered. Returns `isRegistered`. No relaunch needed.
    @discardableResult
    public func update(combo: QuickComposeCombo, enabled: Bool) -> Bool {
        guard enabled, combo.rejectedReason == nil else {
            unregister()
            return false
        }
        if isRegistered, activeCombo == combo { return true }
        unregister()
        Self.installHandler()
        var ref: EventHotKeyRef?
        let hotID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotID,
            GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        activeCombo = combo
        isRegistered = true
        Self.activeFire = { [weak self] in self?.fire() }
        Self.activeOwner = ObjectIdentifier(self)
        return true
    }

    /// Release the global combo (toggle-off path + deinit). Clears the
    /// fire closure only when this instance owns it.
    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if Self.activeOwner == ObjectIdentifier(self) {
            Self.activeOwner = nil
            Self.activeFire = nil
        }
        isRegistered = false
        activeCombo = nil
    }

    private func fire() {
        if Thread.isMainThread {
            onFire?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onFire?() }
        }
    }

    fileprivate static func fireActive() {
        activeFire?()
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), quickComposeHotKeyProc,
            1, &spec, nil, nil)
    }
}
