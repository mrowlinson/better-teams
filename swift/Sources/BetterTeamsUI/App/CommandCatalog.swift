// CommandCatalog.swift — every command, once (UI-SPEC §5.4, R19).
//
// Menu items and toolbar items are both generated from these values
// and both validate through the responder chain
// (`ShellWindowController.validateMenuItem` / `validateToolbarItem`).
// Each section declares its own list in `Sections/<Name>/<Name>Commands
// .swift`; this file aggregates them once (§11.3 seams), so lanes never
// edit this file to add a command.
import AppKit

/// String-backed command identifier; doubles as the toolbar item id.
public struct CommandID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ raw: String) { rawValue = raw }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// Menu-bar menus in standard order (§9.1).
public enum CommandMenu: Int, CaseIterable, Sendable {
    case app, file, edit, view, go, conversation, call, window, help

    public var title: String {
        switch self {
        case .app: "Better Teams"
        case .file: "File"
        case .edit: "Edit"
        case .view: "View"
        case .go: "Go"
        case .conversation: "Conversation"
        case .call: "Call"
        case .window: "Window"
        case .help: "Help"
        }
    }
}

/// Where a command sits in the menu bar. Groups are separated;
/// `submenu` nests the item under a static submenu title (one level).
public struct MenuPlacement: Sendable {
    public var menu: CommandMenu
    public var group: Int
    public var order: Int
    public var submenu: String?

    public init(_ menu: CommandMenu, group: Int, order: Int, submenu: String? = nil) {
        self.menu = menu
        self.group = group
        self.order = order
        self.submenu = submenu
    }
}

/// Toolbar group (§5.4).
public enum ToolbarGroup: Sendable {
    case list, detail, trailing
}

public struct Command: Sendable {
    public var id: CommandID
    public var title: String
    /// Title while the command's state is on (Show/Hide pairs).
    public var alternateTitle: String?
    public var symbol: String?
    public var key: String
    public var modifiers: NSEvent.ModifierFlags
    /// Standard AppKit action (nil = `performCommand:` dispatch).
    public var selector: Selector?
    public var menu: MenuPlacement?
    public var toolbar: ToolbarGroup?
    /// Items are built on demand by the owner (`submenuItems`).
    public var isSubmenu: Bool
    /// Owning section (nil = shell).
    public var owner: SectionID?
    /// Tooltip when it says more than the title (a standing reason the
    /// command is unavailable); nil = the title.
    public var help: String?

    public init(
        _ id: CommandID, _ title: String, alternateTitle: String? = nil,
        symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
        selector: Selector? = nil, menu: MenuPlacement? = nil, toolbar: ToolbarGroup? = nil,
        isSubmenu: Bool = false, owner: SectionID? = nil, help: String? = nil
    ) {
        self.id = id
        self.title = title
        self.alternateTitle = alternateTitle
        self.symbol = symbol
        self.key = key
        self.modifiers = modifiers
        self.selector = selector
        self.menu = menu
        self.toolbar = toolbar
        self.isSubmenu = isSubmenu
        self.owner = owner
        self.help = help
    }

    /// Key equivalent identity for uniqueness checks ("" = none).
    public var shortcut: String {
        key.isEmpty ? "" : "\(modifiers.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue):\(key.lowercased())"
    }
}

/// Validation answer (enabled, checkmark, dynamic title).
public struct CommandValidation: Sendable {
    public var enabled: Bool
    public var checked: Bool
    public var title: String?

    public init(enabled: Bool, checked: Bool = false, title: String? = nil) {
        self.enabled = enabled
        self.checked = checked
        self.title = title
    }

    public static let disabled = CommandValidation(enabled: false)
    public static let enabled = CommandValidation(enabled: true)
}

/// One dynamic submenu entry; `arg` rides in the invocation.
public struct SubmenuItem: Sendable {
    public var title: String
    public var arg: String
    public var symbol: String?
    public var checked: Bool
    public var enabled: Bool
    public var separatorBefore: Bool

    public init(_ title: String, arg: String, symbol: String? = nil, checked: Bool = false,
                enabled: Bool = true, separatorBefore: Bool = false) {
        self.title = title
        self.arg = arg
        self.symbol = symbol
        self.checked = checked
        self.enabled = enabled
        self.separatorBefore = separatorBefore
    }
}

/// Shell-owned command ids.
public enum ShellCommand {
    public static let goActivity: CommandID = "go.activity"
    public static let goChat: CommandID = "go.chat"
    public static let goTeams: CommandID = "go.teams"
    public static let goCalendar: CommandID = "go.calendar"
    public static let goCalls: CommandID = "go.calls"
    public static let goFiles: CommandID = "go.files"
    public static let goPinned = [CommandID("go.pinned.1"), "go.pinned.2", "go.pinned.3"]
    public static let goApps: CommandID = "go.apps"
    public static let goTo: CommandID = "go.goto"
    public static let nextUnread: CommandID = "go.nextUnread"
    public static let previousUnread: CommandID = "go.previousUnread"
    public static let inspector: CommandID = "view.inspector"
    public static let tabChat: CommandID = "view.tab.chat"
    public static let tabFiles: CommandID = "view.tab.files"
    public static let tabNotes: CommandID = "view.tab.notes"
    public static let actualSize: CommandID = "view.actualSize"
    public static let zoomIn: CommandID = "view.zoomIn"
    public static let zoomOut: CommandID = "view.zoomOut"
    /// View ▸ zoom commands; in a web app they scale the page.
    static let pageZoom: Set<CommandID> = [actualSize, zoomIn, zoomOut]
    public static let search: CommandID = "shell.search"
    public static let find: CommandID = "shell.find"
    public static let findNext: CommandID = "shell.findNext"
    public static let findPrevious: CommandID = "shell.findPrevious"
    public static let account: CommandID = "shell.account"
    public static let connection: CommandID = "shell.connection"
    public static let signOut: CommandID = "app.signOut"
    /// File ▸ New Quick Message… (⌃⌘M, the hotkey's default combo).
    public static let quickMessage: CommandID = "shell.quickMessage"
    public static let settings: CommandID = "app.settings"

    static func go(_ s: SectionID) -> CommandID {
        switch s {
        case .activity: goActivity
        case .chat: goChat
        case .teams: goTeams
        case .calendar: goCalendar
        case .calls: goCalls
        case .files: goFiles
        default: goApps
        }
    }
}

@MainActor
public enum CommandCatalog {
    /// Shell + every section's list (the per-section lists P1 wires once).
    public static let all: [Command] = shell + ChatCommands.all + ActivityCommands.all
        + TeamsCommands.all + CalendarCommands.all + CallsCommands.all + FilesCommands.all
        + AppsCommands.all + PlannerCommands.all + ToDoCommands.all + ShiftsCommands.all
        + RecapsCommands.all + OneNoteCommands.all + CallCommands.all

    private static let byID: [CommandID: Command] = Dictionary(
        all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static func command(_ id: CommandID) -> Command? { byID[id] }

    /// Commands with a toolbar placement, catalog order.
    public static var toolbarCommands: [Command] { all.filter { $0.toolbar != nil } }

    static let shell: [Command] = {
        typealias C = Command
        let sel = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        var list: [Command] = [
            // Better Teams menu
            C("app.about", "About Better Teams", selector: sel, menu: .init(.app, group: 0, order: 0)),
            C(ShellCommand.settings, "Settings…", key: ",", menu: .init(.app, group: 1, order: 0)),
            C(ShellCommand.account, "Status", symbol: "person.crop.circle", menu: .init(.app, group: 1, order: 1),
              toolbar: .trailing, isSubmenu: true),
            C(ShellCommand.connection, "Sign In Again…", symbol: "exclamationmark.triangle",
              key: "i", modifiers: [.command, .shift], menu: .init(.app, group: 1, order: 2), toolbar: .trailing),
            C(ShellCommand.signOut, "Sign Out…", menu: .init(.app, group: 1, order: 3)),
            C("app.hide", "Hide Better Teams", key: "h", selector: #selector(NSApplication.hide(_:)),
              menu: .init(.app, group: 3, order: 0)),
            C("app.hideOthers", "Hide Others", key: "h", modifiers: [.command, .option],
              selector: #selector(NSApplication.hideOtherApplications(_:)), menu: .init(.app, group: 3, order: 1)),
            C("app.showAll", "Show All", selector: #selector(NSApplication.unhideAllApplications(_:)),
              menu: .init(.app, group: 3, order: 2)),
            C("app.quit", "Quit Better Teams", key: "q", selector: #selector(NSApplication.terminate(_:)),
              menu: .init(.app, group: 4, order: 0)),
            // File
            C(ShellCommand.quickMessage, "New Quick Message\u{2026}", symbol: "square.and.pencil", key: "m",
              modifiers: [.command, .control], menu: .init(.file, group: 0, order: 8)),
            C("file.close", "Close Window", key: "w", selector: #selector(NSWindow.performClose(_:)),
              menu: .init(.file, group: 9, order: 0)),
            // Edit
            C("edit.undo", "Undo", key: "z", selector: Selector(("undo:")), menu: .init(.edit, group: 0, order: 0)),
            C("edit.redo", "Redo", key: "z", modifiers: [.command, .shift], selector: Selector(("redo:")),
              menu: .init(.edit, group: 0, order: 1)),
            C("edit.cut", "Cut", key: "x", selector: #selector(NSText.cut(_:)), menu: .init(.edit, group: 1, order: 0)),
            C("edit.copy", "Copy", key: "c", selector: #selector(NSText.copy(_:)), menu: .init(.edit, group: 1, order: 1)),
            C("edit.paste", "Paste", key: "v", selector: #selector(NSText.paste(_:)), menu: .init(.edit, group: 1, order: 2)),
            C("edit.pasteMatch", "Paste and Match Style", key: "v", modifiers: [.command, .option, .shift],
              selector: #selector(NSTextView.pasteAsPlainText(_:)), menu: .init(.edit, group: 1, order: 3)),
            C("edit.delete", "Delete", selector: #selector(NSText.delete(_:)), menu: .init(.edit, group: 1, order: 4)),
            C("edit.selectAll", "Select All", key: "a", selector: #selector(NSText.selectAll(_:)),
              menu: .init(.edit, group: 1, order: 5)),
            C(ShellCommand.find, "Find…", key: "f", menu: .init(.edit, group: 2, order: 0, submenu: "Find")),
            C(ShellCommand.search, "Search", symbol: "magnifyingglass", key: "f", modifiers: [.command, .option],
              menu: .init(.edit, group: 2, order: 1, submenu: "Find"), toolbar: .trailing),
            C(ShellCommand.findNext, "Find Next", key: "g", menu: .init(.edit, group: 2, order: 2, submenu: "Find")),
            C(ShellCommand.findPrevious, "Find Previous", key: "g", modifiers: [.command, .shift],
              menu: .init(.edit, group: 2, order: 3, submenu: "Find")),
            // View
            C("view.toolbar", "Show Toolbar", alternateTitle: "Hide Toolbar", key: "t", modifiers: [.command, .option],
              selector: #selector(NSWindow.toggleToolbarShown(_:)), menu: .init(.view, group: 0, order: 0)),
            C(ShellCommand.inspector, "Show Inspector", alternateTitle: "Hide Inspector", symbol: "sidebar.trailing",
              key: "i", modifiers: [.command, .option], menu: .init(.view, group: 0, order: 1), toolbar: .trailing),
            C(ShellCommand.tabChat, "Chat", key: "1", modifiers: [.command, .option], menu: .init(.view, group: 1, order: 0)),
            C(ShellCommand.tabFiles, "Files", key: "2", modifiers: [.command, .option], menu: .init(.view, group: 1, order: 1)),
            C(ShellCommand.tabNotes, "Notes", key: "3", modifiers: [.command, .option], menu: .init(.view, group: 1, order: 2)),
            C(ShellCommand.actualSize, "Actual Size", key: "0", menu: .init(.view, group: 4, order: 0)),
            C(ShellCommand.zoomIn, "Zoom In", key: "+", menu: .init(.view, group: 4, order: 1)),
            C(ShellCommand.zoomOut, "Zoom Out", key: "-", menu: .init(.view, group: 4, order: 2)),
            C("view.fullScreen", "Enter Full Screen", key: "f", modifiers: [.command, .control],
              selector: #selector(NSWindow.toggleFullScreen(_:)), menu: .init(.view, group: 6, order: 0)),
            // Go
            C(ShellCommand.goActivity, "Activity", key: "1", menu: .init(.go, group: 0, order: 0)),
            C(ShellCommand.goChat, "Chat", key: "2", menu: .init(.go, group: 0, order: 1)),
            C(ShellCommand.goTeams, "Teams", key: "3", menu: .init(.go, group: 0, order: 2)),
            C(ShellCommand.goCalendar, "Calendar", key: "4", menu: .init(.go, group: 0, order: 3)),
            C(ShellCommand.goCalls, "Calls", key: "5", menu: .init(.go, group: 0, order: 4)),
            C(ShellCommand.goFiles, "Files", key: "6", menu: .init(.go, group: 0, order: 5)),
            C(ShellCommand.goApps, "Apps", menu: .init(.go, group: 0, order: 9)),
            C(ShellCommand.goTo, "Go To…", key: "k", menu: .init(.go, group: 1, order: 0)),
            C(ShellCommand.nextUnread, "Next Unread Chat", key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
              modifiers: [.command, .option], menu: .init(.go, group: 1, order: 1)),
            C(ShellCommand.previousUnread, "Previous Unread Chat", key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
              modifiers: [.command, .option], menu: .init(.go, group: 1, order: 2)),
            // Window
            C("window.minimize", "Minimize", key: "m", selector: #selector(NSWindow.performMiniaturize(_:)),
              menu: .init(.window, group: 0, order: 0)),
            C("window.zoom", "Zoom", selector: #selector(NSWindow.performZoom(_:)), menu: .init(.window, group: 0, order: 1)),
            C("window.front", "Bring All to Front", selector: #selector(NSApplication.arrangeInFront(_:)),
              menu: .init(.window, group: 1, order: 0)),
            // Help
            C("help.help", "Better Teams Help", key: "?", menu: .init(.help, group: 0, order: 0)),
        ]
        for (i, id) in ShellCommand.goPinned.enumerated() {
            list.append(C(id, "Pinned App \(i + 1)", key: "\(7 + i)", menu: .init(.go, group: 0, order: 6 + i)))
        }
        return list
    }()
}
