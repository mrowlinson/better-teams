// QuickComposerPanel.swift — the opt-in quick composer (UI-SPEC §5.7,
// §9.4 Chats): Settings ▸ Chats ▸ Quick composer (off by default) with
// a hotkey recorder. When on, the core's global hotkey
// (`QuickComposerHotKey`, Carbon; no event monitors, R10) opens a small
// floating panel: To (recent chats), message, Send (default) / Cancel.
// Sending goes through the core (`AppState.quickSend`). The hotkey is
// never registered in demo or evidence runs.
import AppKit
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class QuickComposerController {
    private weak var shell: ShellWindowController?
    private let hotKey = QuickComposerHotKey()
    private var panel: NSPanel?
    private var sub: AnyCancellable?

    init(shell: ShellWindowController) {
        self.shell = shell
        hotKey.onFire = { [weak self] in MainActor.assumeIsolated { self?.show() } }
        guard !shell.model.options.demo, !shell.model.options.evidence else { return }
        sub = AppSettings.shared.changes.sink { [weak self] in
            DispatchQueue.main.async { self?.sync() }
        }
        sync()
    }

    /// The combo lives with the core's prefs (same defaults as the app settings).
    static func combo() -> QuickComposeCombo { QuickComposerPrefs.loadCombo(defaults: AppSettings.shared.defaults) }

    static func setCombo(_ c: QuickComposeCombo) {
        QuickComposerPrefs.saveCombo(c, defaults: AppSettings.shared.defaults)
    }

    func sync() {
        hotKey.update(combo: Self.combo(), enabled: AppSettings.shared.quickComposer)
    }

    func show() {
        guard let m = shell?.model, let app = m.app else { return }
        panel?.close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        p.title = "Quick Message"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isRestorable = false
        p.becomesKeyOnlyIfNeeded = false
        let chats = Array(m.graph.chats.chats.prefix(20)).map { (id: $0.id, name: $0.name) }
        let view = QuickComposerView(chats: chats) { [weak self, weak app] id, name, text in
            app?.quickSend(targetID: id, targetName: name, text: text)
            self?.panel?.close()
        } cancel: { [weak self] in
            self?.panel?.close()
        }
        p.contentViewController = Hosting.controller(view, role: .sheet, model: m)
        p.center()
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }
}

struct QuickComposerView: View {
    struct Target: Identifiable { let id: String; let name: String }
    let targets: [Target]
    let send: (String, String, String) -> Void
    let cancel: () -> Void
    @State private var to: String
    @State private var text = ""

    init(chats: [(id: String, name: String)], send: @escaping (String, String, String) -> Void,
         cancel: @escaping () -> Void) {
        targets = chats.map { Target(id: $0.id, name: $0.name.isEmpty ? "Conversation" : $0.name) }
        self.send = send
        self.cancel = cancel
        _to = State(initialValue: chats.first?.id ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("To:", selection: $to) {
                    ForEach(targets) { Text($0.name).tag($0.id) }
                }
                TextField("Message:", text: $text, axis: .vertical)
                    .lineLimit(1...4)
            }
            .formStyle(.columns)
            .padding(16)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") {
                    let name = targets.first { $0.id == to }?.name ?? ""
                    send(to, name, text)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(to.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 420)
    }
}

/// Settings ▸ Chats ▸ quick composer hotkey recorder: click, then type
/// the shortcut (Esc cancels). Key events reach it as first responder;
/// no event monitors (R10). Combos the core rejects are refused.
struct HotKeyRecorder: NSViewRepresentable {
    let combo: QuickComposeCombo
    let onChange: (QuickComposeCombo) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onChange = onChange
        b.combo = combo
        return b
    }

    func updateNSView(_ b: RecorderButton, context: Context) {
        b.onChange = onChange
        if !b.recording { b.combo = combo }
    }

    final class RecorderButton: NSButton {
        var onChange: ((QuickComposeCombo) -> Void)?
        var combo = QuickComposeCombo.default { didSet { refresh() } }
        private(set) var recording = false { didSet { refresh() } }

        init() {
            super.init(frame: .zero)
            bezelStyle = .push
            target = self
            action = #selector(begin)
            refresh()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

        override var acceptsFirstResponder: Bool { true }

        @objc private func begin() {
            recording = true
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return super.resignFirstResponder()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            record(event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            record(event)
        }

        private func record(_ event: NSEvent) {
            if event.keyCode == 53 { recording = false; return } // Esc
            let c = QuickComposeCombo(keyCode: UInt32(event.keyCode),
                                      modifiers: QuickComposeCombo.carbonModifiers(
                                          cocoaFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
            guard c.rejectedReason == nil else { NSSound.beep(); return }
            recording = false
            combo = c
            onChange?(c)
        }

        private func refresh() {
            title = recording ? "Type Shortcut…" : combo.displayString
            setAccessibilityLabel("Quick composer shortcut, \(combo.displayString)")
        }
    }
}
