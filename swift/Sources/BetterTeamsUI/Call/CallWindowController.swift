// CallWindowController.swift — the In a Separate Window host (UI-SPEC
// §8, DL1). Exists only while a call runs: an `NSSplitViewController`
// with the session's stage and the People | Chat inspector, a stock
// toolbar with the call controls (Mute, Camera, Share Screen, Devices,
// inspector toggle, Leave as the one `.prominent` red trailing item),
// title = call name, subtitle = duration. Closing the window asks
// "Leave the call?" (Leave, Cancel).
import AppKit

@MainActor
public final class CallWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation
{
    private weak var session: CallSession?
    private let slot = CallStageHostController()
    private let split = NSSplitViewController()
    private var leaving = false

    static let leaveItem = NSToolbarItem.Identifier(CallCommands.leave.rawValue)
    static let controlItems: [CommandID] = [CallCommands.mute, CallCommands.camera, CallCommands.share,
                                            CallCommands.devices]

    init(session: CallSession) {
        self.session = session
        split.splitView.isVertical = true
        split.addSplitViewItem(NSSplitViewItem(viewController: slot))
        let inspector = NSSplitViewItem(inspectorWithViewController:
            Hosting.controller(CallInspector(session: session), role: .pane, model: session.model))
        inspector.minimumThickness = 240
        inspector.canCollapse = true
        // Collapsed unless the person (or a route) opened the call's
        // inspector in this account window (shared People | Chat state).
        inspector.isCollapsed = !(session.model?.nav.isInspectorVisible(.call) ?? false)
        split.addSplitViewItem(inspector)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 520, height: 360)
        window.contentViewController = split
        window.title = session.title
        window.subtitle = session.statusLine
        window.setContentSize(NSSize(width: 760, height: 520))
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "call.window")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        slot.attach(session.stage)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Subtitle = duration (the session's ticker), or the call state.
    func setSubtitle(_ s: String) {
        guard let window, window.subtitle != s else { return }
        window.subtitle = s
    }

    /// Closes without asking (the call already ended).
    func closeAfterLeave() {
        leaving = true
        slot.attach(nil)
        close()
    }

    /// Full screen keeps the call toolbar visible (§8).
    public func window(_ window: NSWindow,
                       willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        proposed.subtracting(.autoHideToolbar)
    }

    // MARK: close asks to leave (§8)

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !leaving, let session, !session.ended else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Leave the call?"
        alert.informativeText = "You\u{2019}ll leave \u{201C}\(session.title)\u{201D}."
        let leave = alert.addButton(withTitle: "Leave")
        leave.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak session] response in
            if response == .alertFirstButtonReturn { session?.leave() }
        }
        return false
    }

    // MARK: toolbar (controls live in the toolbar, never a bottom bar)

    private var identifiers: [NSToolbarItem.Identifier] {
        Self.controlItems.map { NSToolbarItem.Identifier($0.rawValue) }
            + [.flexibleSpace, .toggleInspector, Self.leaveItem]
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier ident: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let id = CommandID(ident.rawValue)
        guard let cmd = CommandCatalog.command(id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: ident)
        item.label = cmd.title
        item.toolTip = cmd.title
        item.image = cmd.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: cmd.title) }
        item.isBordered = true
        item.target = self
        switch id {
        case CallCommands.leave:
            item.label = "Leave"
            item.toolTip = "Leave Call (⇧⌘H)"
            item.style = .prominent
            item.backgroundTintColor = .systemRed
            item.action = #selector(leaveCall(_:))
        case CallCommands.mute:
            item.action = #selector(toggleMute(_:))
        case CallCommands.camera:
            item.action = #selector(toggleCamera(_:))
        case CallCommands.share:
            item.action = #selector(toggleShare(_:))
        case CallCommands.devices:
            if let session { item.view = CallDevicesButton(session: session) }
        default:
            return nil
        }
        if let session, let c = session.controls.control(id) {
            item.label = c.label
            item.toolTip = c.menuTitle
            item.image = NSImage(systemSymbolName: c.symbol, accessibilityDescription: c.label)
        }
        return item
    }

    @objc func leaveCall(_ sender: Any?) { session?.leave() }
    @objc func toggleMute(_ sender: Any?) { session?.toggleMute() }
    @objc func toggleCamera(_ sender: Any?) { session?.toggleCamera() }
    @objc func toggleShare(_ sender: Any?) { session?.toggleShare() }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let session, !session.ended else { return false }
        return session.controls.control(CommandID(item.itemIdentifier.rawValue))?.enabled ?? true
    }

    /// People | Chat inspector toggle (the stock `.toggleInspector`).
    @objc public func toggleInspector(_ sender: Any?) {
        split.toggleInspector(sender)
    }

    // MARK: menu commands while the call window is key

    /// Menu-bar commands reach the account's main window: the call
    /// window is in the responder chain instead of the shell, so it
    /// forwards (Call ▸ Leave Call, Go ▸ …, Settings…).
    private var shell: ShellWindowController? {
        session?.model?.navigator?.host as? ShellWindowController ?? ShellWindowController.current
    }

    @objc public func performCommand(_ sender: Any?) {
        guard let (id, arg) = ShellWindowController.invocation(sender) else { return }
        shell?.perform(id, arg: arg)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let shell else { return false }
        return shell.validateMenuItem(item)
    }
}
