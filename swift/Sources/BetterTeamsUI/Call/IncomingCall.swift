// IncomingCall.swift — incoming calls (UI-SPEC §8 Incoming call, §9.3).
//
// The ring is the core's: `CallStore` rings through `CallNotify` and the
// time-sensitive `CALL` notification (Accept, Decline) posted by
// `Notifier` (live only; demo and evidence never post). There is no
// custom ring UI. Accept and Decline go to the core call slot
// (`CallStore.accept()` / `end()`, via the shared notification
// delegate); this host reacts to the call state: an incoming call that
// becomes active with no session running starts a `CallSession` in the
// presentation the person chose (Settings ▸ Calls ▸ Show calls, DL1)
// and brings it forward, whichever path accepted it.
import AppKit
import Combine
import OstMacCore
import UserNotifications

@MainActor
final class IncomingCallHost {
    private weak var model: WindowModel?
    private let store: CallStore
    private let show: Bool
    private var sub: AnyCancellable?
    private var queued = false
    /// The incoming call a session was started for (one session per call).
    private(set) var hostedCallID: String?

    init(model: WindowModel, store: CallStore, show: Bool = true) {
        self.model = model
        self.store = store
        self.show = show
        // `@Published` emits in willSet: read the slot after it lands.
        sub = store.$phase.sink { [weak self] _ in self?.queueSync() }
    }

    private func queueSync() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            self?.queued = false
            self?.sync()
        }
    }

    /// Starts the host for an accepted incoming call (idempotent).
    func sync() {
        switch store.phase {
        case .idle, .ended:
            hostedCallID = nil
            return
        case .inviting:
            return // ringing: the notification is the UI (§8)
        case .active:
            break
        }
        guard let model, let c = store.call, c.dir == "in", c.id != hostedCallID else { return }
        if let running = model.call, !running.ended { return }
        hostedCallID = c.id
        guard let s = model.beginCall(.person(name: c.displayPeer, thread: c.thread), show: show, store: store)
        else { return }
        guard show, !model.options.evidence, s.presentation == .mainWindow else { return }
        // Accept is a foreground action: the main window comes forward
        // with the call selected (the separate window orders itself in).
        (model.navigator?.host as? ShellWindowController)?.window?.makeKeyAndOrderFront(nil)
    }

    /// Evidence: what the `CALL` notification for the ringing call
    /// carries (built by the core's pure content builder; never posted).
    static func preview(_ store: CallStore) -> String {
        guard store.phase == .inviting, let c = store.call, c.dir == "in" else { return " incoming[none]" }
        let content = OmCallInfo.makeContent(title: c.displayPeer, body: "Incoming call", callID: c.id)
        return " incoming[title=\(content.title) body=\(content.body) category=\(content.categoryIdentifier)"
            + " actions=\(OmCallInfo.acceptTitle),\(OmCallInfo.declineTitle)]"
    }
}
