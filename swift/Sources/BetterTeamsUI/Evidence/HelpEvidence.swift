// HelpEvidence.swift — demo/evidence routes for the Help window (C8a).
//
//   help                     the Help topics window
//   help?topic=<id>          Help on one topic
//   shortcuts                the Keyboard Shortcuts table
//
// The Help window is its own window: in evidence mode the main window
// is ordered out and `EvidenceHarness.primaryWindow` reports it.
import AppKit

@MainActor
enum HelpEvidence {
    static func apply(_ route: Route, _ wc: ShellWindowController) {
        let m = wc.model
        guard m.options.demo else { return }
        switch route.head {
        case "help":
            HelpWindowController.shared.show(topic: route.query["topic"], evidence: m.options.evidence)
            CallEvidence.focus(HelpWindowController.shared.window, over: wc)
        case "shortcuts":
            HelpWindowController.shared.showShortcuts(evidence: m.options.evidence)
            CallEvidence.focus(HelpWindowController.shared.window, over: wc)
        default:
            break
        }
    }
}
