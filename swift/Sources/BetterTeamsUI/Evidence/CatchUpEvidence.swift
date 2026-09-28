// CatchUpEvidence.swift — demo/evidence routes for Catch Up (CATCHQA).
//
//   <any route>?catchup=off|onclick|always     the Catch Up setting
//   settings/ai?catchup=…&ai=ready|unsupported|disabled|downloading
//       Settings ▸ AI with that status row (never the live model state)
//   chat/<id>?inspector=catchup&catchup=onclick&summary=loaded|streaming|updating
//       the inspector summary: done; first run streaming in; a re-run
//       keeping the old summary with its small progress
//   chat/<id>?catchup=always&window=catchup[&digest=updating]
//       Window ▸ Open Catch Up in New Window (mentions + several chats);
//       `digest=updating` re-summarizes one chat in place
//
// Demo only: the canned `CatchUpDemoTransport` (held open for the
// streaming / updating states), the demo in-memory settings.
import AppKit
import OstMacCore

@MainActor
enum CatchUpEvidence {
    /// Before startup: the setting and the Settings status row.
    static func apply(_ route: Route, _ wc: ShellWindowController) {
        guard wc.model.options.demo, let app = wc.model.app else { return }
        switch route.query["catchup"] {
        case "off": app.catchUp.mode = .off
        case "onclick": app.catchUp.mode = .onClick
        case "always": app.catchUp.mode = .alwaysUpToDate
        default: break
        }
        switch route.query["ai"] {
        case "ready": AIPane.demoAvailability = .available
        case "unsupported": AIPane.demoAvailability = .unsupportedDevice
        case "disabled": AIPane.demoAvailability = .disabled
        case "downloading": AIPane.demoAvailability = .downloading
        default: break
        }
    }

    /// After startup (the demo chat is open): summary state, window.
    static func afterStartup(_ wc: ShellWindowController) {
        let m = wc.model
        guard m.options.demo, let app = m.app, let raw = m.options.route, let route = Route(string: raw),
              route.head == "chat", let id = route.tail.first else { return }
        let demo = app.demoCatchUpTransport
        if let state = route.query["summary"] {
            Task {
                guard await waitFor({ m.graph.conv.chatID == id && !m.graph.conv.messages.isEmpty }) else { return }
                switch state {
                case "streaming":
                    demo?.holding = true
                    demo?.holdPartial = streamingPartial
                    CatchUpRunner.run(m, chatID: id)
                case "updating":
                    CatchUpRunner.run(m, chatID: id)
                    guard await waitFor({ if case .loaded = app.catchUp.state { true } else { false } }) else { return }
                    demo?.holding = true
                    demo?.holdPartial = nil
                    // A new message arrived since: the re-run misses the
                    // summary cache and keeps the old text on screen.
                    await app.catchUp.summarize(messages: m.graph.conv.messages + [arrival], chatID: id)
                default:
                    CatchUpRunner.run(m, chatID: id)
                }
            }
        }
        if route.query["window"] == "catchup" {
            let digest = app.catchUpDigest
            digest.maxChatsPerCycle = 10
            CatchUpWindowController.show(m)
            CallEvidence.focus(NSApp.windows.first { $0.title == "Catch Up" }, over: wc)
            digest.updateNow()
            guard route.query["digest"] == "updating" else { return }
            Task {
                guard await waitFor({ !digest.entries.isEmpty && digest.working == nil }) else { return }
                demo?.holding = true
                demo?.holdPartial = nil
                digest.ingest(chatID: DemoData.standupID, chatName: DemoData.name(for: DemoData.standupID) ?? "",
                              messages: [arrival])
                digest.updateNow()
            }
        }
    }

    /// A fresh message (evidence of "new messages since the summary").
    private static let arrival = ChatMessage(
        id: "catchup-evidence", sender: "Tom Becker", timestamp: "2026-09-21T16:30:00Z",
        content: "Packaging is done, the build is up for review.")

    private static let streamingPartial = """
        SUMMARY: Offsite photos are in and Thursday's agenda is locked: roadmap, hiring and the offsite recap.
        POINTS:
        - Megan asked you to share the sunset photo
        """

    /// Re-checks `ok` once per main-queue turn (the harness's settle idiom,
    /// no sleeps, R7) until it holds or 3 s pass.
    private static func waitFor(_ ok: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if ok() { return true }
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
        return ok()
    }
}
