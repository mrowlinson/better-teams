// AppDelegate.swift — Better Teams app lifecycle (UI-SPEC §4, §5.7,
// §11.2 App/).
//
// Builds the AppState composition root, the menu bar, and one main
// window. The window's navigation is restored and applied before it is
// first shown (R26). `--demo` skips sign-in. Launch flags: see
// LaunchOptions.swift.
import AppKit
import OstMacCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let state: AppState
    let options: LaunchOptions
    private(set) var shell: ShellWindowController?
    /// System integration (§9.2, §9.3, §8): Dock badge, notification
    /// routing, incoming-call host, menu bar extra, quick composer.
    private var dockBadge: DockBadge?
    private var notifications: NotificationRouter?
    private var incomingCalls: IncomingCallHost?
    private var statusItem: StatusItemController?
    private var quickComposer: QuickComposerController?

    public init(args: [String]) {
        let options = LaunchOptions(args: args)
        self.options = options
        // Evidence captures stamp demo data from a pinned working-hours
        // moment (set before AppState builds any demo data).
        if options.evidence, options.demo { DemoClock.pinForEvidence() }
        // Core restores its own last chat at startup (SelectionRestore)
        // and would open it over the window's selection. Hand it the
        // chat the window will show so both agree (`--chat` wins there).
        var coreArgs = args
        if !args.contains("--chat"), let id = Self.initialChatID(options) {
            coreArgs += ["--chat", id]
        }
        state = AppState(args: coreArgs)
        super.init()
        // Window tabs would merge account windows and add a second
        // "Tab Bar" to the View menu (R26).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// The chat the first window selects: route `chat/<id>`, else (demo)
    /// the persisted selection, else the demo default.
    private static func initialChatID(_ o: LaunchOptions) -> String? {
        if let r = o.route.flatMap(Route.init(string:)) {
            return r.head == "chat" ? r.tail.first : nil
        }
        guard o.demo else { return nil }
        if let saved = Navigator.loadPersisted("demo") {
            return saved.selection[SectionID.chat.key]?.id
        }
        return DemoData.demoID
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        switch options.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if options.evidence, !options.demo {
            // Capture never runs on live data (§11.4).
            print("EVIDENCE REFUSED: --evidence requires --demo")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        let route = options.route.flatMap(Route.init(string:))
        if options.demo {
            // Demo: every setting lives in memory (never `.standard`).
            AppSettings.useDemoStorage()
        }
        CallEvidence.prepare(options)
        if options.evidence {
            // Frozen at launch: demo data is stamped relative to the
            // same pinned demo moment.
            RelativeClock.shared.pin(DemoClock.now)
        } else {
            RelativeClock.shared.start()
        }
        let wc = ShellWindowController(graph: state, options: options)
        shell = wc
        SettingsWindowController.model = wc.model
        if route?.head == "evidence" {
            EvidenceHarness.showControl(in: wc)
        } else if route?.head == "signin", options.demo {
            wc.showSignIn(evidence: route?.query["state"] == "code" ? .code("K7QP2M4XD") : .start)
        } else if options.demo || state.accounts.activeID != nil {
            wc.showShell()
            if let route, route.head != "signin" {
                wc.navigator.apply(route)
            } else if options.demo, Navigator.loadPersisted(wc.model.accountKey) == nil {
                wc.navigator.apply(Route(path: ["chat", DemoData.demoID]))
            } else if Navigator.loadPersisted(wc.model.accountKey) == nil,
                      let s = SectionID(key: AppSettings.shared.defaultSection) {
                // Settings ▸ General ▸ default section (no saved state).
                wc.navigator.select(section: s)
            }
        } else {
            wc.showSignIn()
        }
        // After content is installed: the content controller resizes
        // the window to its fitting size when it is set.
        wc.placeWindow()
        if options.evidenceActive {
            // Active-appearance capture, requested for unattended runs.
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            // No field focused: a key window's text view draws the
            // insertion point and input-source indicator in the shot.
            wc.window?.makeFirstResponder(nil)
            DispatchQueue.main.async { [weak wc] in wc?.window?.makeFirstResponder(nil) }
        } else if options.evidence {
            // Evidence captures run while the owner uses this Mac: order
            // the window in without activating the app or taking key, so
            // no keystroke ever lands in it (ui-shot.sh captures by
            // window id, so occlusion does not matter).
            wc.window?.orderFrontRegardless()
        } else {
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        startSystemIntegration(wc)
        // A forced load error (`state=error`) is the offline failure, so it
        // raises the same connection state the Offline item reads (not a
        // web app's own load error: `Route.forcedConnection`).
        let connection = route?.forcedConnection
        if options.demo, let raw = connection, wc.isShowingShell {
            // Evidence: `<route>?connection=offline|expired` shows the
            // trailing connection item (§5.7) without a live feed.
            wc.setConnection(raw == "expired" ? .expired : raw == "offline" ? .offline : .online)
        }
        if options.demo, route?.query["find"] == "1", wc.isShowingShell {
            // Evidence: `<route>?find=1` is ⌘F (field focused, scoped to
            // the conversation on screen, §5.5).
            wc.navigator.focusSearch(.conversation)
        }
        if options.demo, let route, wc.isShowingShell {
            // Evidence: `settings/<pane>`, `call?state=…&presentation=…`.
            CatchUpEvidence.apply(route, wc)
            CallEvidence.apply(route, wc)
        }
        if options.demo, let route, let name = route.query["sheet"], let s = route.section {
            // Evidence: `<route>?sheet=<name>` opens a section sheet.
            wc.model.presentSheet(SheetRequest(name, in: s))
        }
        Task {
            await state.startup()
            if wc.isShowingShell { wc.navigator.resyncSelection() }
            if options.demo, wc.isShowingShell {
                ConversationEvidence.afterStartup(wc.model)
                CatchUpEvidence.afterStartup(wc)
            }
            if options.demo, wc.isShowingShell, wc.model.nav.section == .files {
                // Evidence: Files popover / Quick Look once the window is up.
                (wc.model.provider(.files) as? FilesSection)?.applyEvidence(wc.model)
            }
            if options.evidence { EvidenceHarness.settle(wc, options: options) }
        }
    }

    /// Dock badge, notification routing, the incoming-call host, the
    /// menu bar extra and the quick composer, for the main window.
    private func startSystemIntegration(_ wc: ShellWindowController) {
        dockBadge = DockBadge(model: wc.model, tile: options.evidence ? nil : NSApp.dockTile)
        notifications = NotificationRouter(shell: wc)
        if let store = wc.model.app?.call { incomingCalls = IncomingCallHost(model: wc.model, store: store) }
        statusItem = StatusItemController(shell: wc)
        quickComposer = QuickComposerController(shell: wc)
    }

    /// Dock menu (§9.2): New Chat, Set Status ▸, up to five unread chats.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let wc = shell, wc.isShowingShell else { return nil }
        return DockMenu.build(wc)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { shell?.window?.makeKeyAndOrderFront(nil) }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()
    }
}
