// HelpContent.swift — the Help window's topics and the Keyboard
// Shortcuts window's rows (C8a). Topics describe this app's behavior
// (UI-SPEC §9.1 menus, §5.5 search, §10 keyboard); the shortcuts list
// is generated from CommandCatalog, so it can never drift from the
// menu bar. Pure data + formatting: unit-tested, no views.
import AppKit

/// One help section: a heading with prose and optional bullets.
public struct HelpSection: Sendable {
    public var heading: String
    public var body: String
    public var bullets: [String]

    public init(_ heading: String, _ body: String, bullets: [String] = []) {
        self.heading = heading
        self.body = body
        self.bullets = bullets
    }
}

/// One help topic: sidebar row + content.
public struct HelpTopic: Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var sections: [HelpSection]

    public init(_ id: String, _ title: String, symbol: String, sections: [HelpSection]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.sections = sections
    }
}

/// One shortcuts row: a command, its keys, and an optional note (⌘E's
/// Teams difference, macOS standards, planned bindings).
public struct ShortcutRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var keys: String
    public var note: String?

    public init(_ id: String, _ title: String, keys: String, note: String? = nil) {
        self.id = id
        self.title = title
        self.keys = keys
        self.note = note
    }
}

/// One shortcuts group: a menu bar menu in standard order.
public struct ShortcutSection: Identifiable, Sendable {
    public var id: String { menu }
    public var menu: String
    public var rows: [ShortcutRow]

    public init(_ menu: String, rows: [ShortcutRow]) {
        self.menu = menu
        self.rows = rows
    }
}

public enum HelpContent {
    public static let topics: [HelpTopic] = [
        HelpTopic("start", "Getting Around", symbol: "house", sections: [
            HelpSection("Sections",
                        "The rail on the left switches sections: Activity, Chat, Teams, Calendar, Calls, and Files. The Go menu jumps straight to any of them.",
                        bullets: ["Activity, Chat, Teams, Calendar, Calls, Files live on ⌘1 to ⌘6.",
                                  "Go To (⌘K) jumps to a chat, channel, or person by name.",
                                  "Next and Previous Unread Chat (⌥⌘↓ and ⌥⌘↑) walk the unread list."]),
            HelpSection("Search",
                        "Search (⌥⌘F) looks everywhere: messages, people, and files. Find in Conversation (⌘F) scopes the field to the open conversation, channel, or page, and ⌘G steps through its matches.",
                        bullets: ["⌥⌘F focuses the search field; Esc leaves it.",
                                  "⌘K focuses the field with scope All; Return opens the top hit."]),
        ]),
        HelpTopic("chat", "Chat", symbol: "bubble.left", sections: [
            HelpSection("List and filters",
                        "Chats sort Pinned first, then Recent. The Filter menu narrows the list to Unread, Mentions, Muted, Snoozed, Hidden, or one folder.",
                        bullets: ["Mark as Unread (⇧⌘U) bookmarks behind the newest message.",
                                  "Mute, Snooze, Notifications, Move to Folder, and Hide live on the Conversation menu and the row menu.",
                                  "Saved Messages (⇧⌘S) shows everything saved for later."]),
            HelpSection("Conversation",
                        "The detail shows the timeline with the composer below it. Tabs above the conversation switch between Chat, Files, and Notes (⌥⌘1 to ⌥⌘3).",
                        bullets: ["Return sends; ⌘Return always sends.",
                                  "The row's hover toolbar holds six quick reactions, More reactions, Reply, and More options.",
                                  "Up and Down move the keyboard-selected message; the Conversation menu's message actions work on it."]),
        ]),
        HelpTopic("teams", "Teams and Channels", symbol: "person.3", sections: [
            HelpSection("Teams",
                        "The Teams list groups channels under each team. Pin and hide channels, mark a team or channel read, and manage members from the Conversation menu or the row menu.",
                        bullets: ["Join or Create Team lives on the File menu.",
                                  "Open Channel in New Window pops a channel out.",
                                  "Channel Notifications tune each channel separately."]),
            HelpSection("Posts",
                        "A channel's Posts tab is a conversation like a chat: timeline, composer, and tabs for Files and Notes.",
                        bullets: ["Reply starts a thread on a post.", "Mark Channel as Read clears its badge."]),
        ]),
        HelpTopic("calls", "Calls and Meetings", symbol: "video", sections: [
            HelpSection("Starting and joining",
                        "Start Audio Call or Start Video Call from the Call menu, or Meet Now for a group chat. Join Meeting (⌘J) joins from an ID or link anywhere.",
                        bullets: ["New Call and Test Call live on the File and Call menus.",
                                  "New Meeting and scheduling live on the Calendar."]),
            HelpSection("In a call",
                        "The Call menu holds every control: Mute (⇧⌘M), Camera (⇧⌘O), Share Screen (⇧⌘E), Devices, and Leave Call (⇧⌘H).",
                        bullets: ["Accept (⇧⌘A) answers a ringing call; Decline (⇧⌘D) sends it away.",
                                  "Raise Hand (⇧⌘K) toggles the hand; meeting chat opens with ⇧⌘R.",
                                  "Push to Talk holds ⌥Space to talk once it is turned on in Settings ▸ Calls."]),
        ]),
        HelpTopic("calendar", "Calendar", symbol: "calendar", sections: [
            HelpSection("Views and meetings",
                        "Day, Work Week, Week, Month, and List views show the week; the toolbar joins the selected meeting.",
                        bullets: ["New Meeting (⌥⇧N) schedules; Join with ID or Link (⌘J) joins.",
                                  "RSVP, counts, and attendee rows sit in the detail toolbar."]),
        ]),
        HelpTopic("search", "Search", symbol: "magnifyingglass", sections: [
            HelpSection("Scopes",
                        "One field searches messages, people, and files. The scope bar narrows it; typing scopes to the open conversation with ⌘F.",
                        bullets: ["⌘G and ⇧⌘G step through in-conversation matches.",
                                  "Use Selection for Find (⌘E) searches the selected text."]),
        ]),
        HelpTopic("notifications", "Notifications and Presence", symbol: "bell.badge", sections: [
            HelpSection("Staying reachable",
                        "Status lives on the Better Teams menu with durations; per-chat levels and mention toggles live in Settings ▸ Notifications.",
                        bullets: ["Quiet hours pause notifications on a schedule.",
                                  "Mark All Activity as Read (⇧Esc) clears the feed."]),
        ]),
        HelpTopic("accessibility", "Accessibility", symbol: "accessibility", sections: [
            HelpSection("Keyboard and VoiceOver",
                        "Every toolbar command has a menu-bar twin, so Full Keyboard Access reaches everything. Lists move with arrows, Return opens, and each row names itself to VoiceOver.",
                        bullets: ["Text size follows View ▸ Zoom In and Zoom Out everywhere.",
                                  "Read Aloud speaks the keyboard-selected message from the Conversation menu.",
                                  "Chat, Activity, Call, and Teams rows expose their row actions to VoiceOver."]),
        ]),
    ]

    /// Teams bindings the lane reserves but a later lane ships: shown as
    /// a footnote, never as working keys.
    public static let planned: [(keys: String, title: String, note: String)] = [
        ("⇧⌘I", "Mark as Important",
         "Teams parity, reserved: needs the rich-compose send path (C1). ⇧⌘I still opens Sign In Again… meanwhile."),
    ]

    /// Notes attached to generated rows (Teams differences and macOS
    /// standards), keyed by command id.
    static let notes: [String: String] = [
        "edit.useSelectionForFind": "macOS standard. Teams uses ⌘E for Search; here ⌥⌘F searches.",
        "shell.search": "Teams parity: ⌘E searches in Teams.",
        "files.newFolder": "macOS Finder standard. Teams has no ⇧⌘N twin.",
        "calendar.newMeeting": "Teams parity (Alt+Shift+N to schedule); ⌘ joins it so the menu key works app-wide.",
        "activity.markAllRead": "Teams parity: ⇧Esc marks everything read.",
        "call.showChat": "Teams parity: the meeting chat.",
        "chat.compose": "Teams parity: the compose box.",
        "chat.reply": "Teams uses R or ⌥⇧R in context; ⌥⌘R keeps ⇧⌘R free for the meeting chat.",
    ]

    /// Every menu-bar command with a key equivalent, grouped by menu in
    /// standard order. Keyless commands are listed without keys, so the
    /// window names every binding and nothing else. `planned` renders as
    /// the closing footnote.
    @MainActor
    public static func shortcutSections() -> [ShortcutSection] {
        var out: [ShortcutSection] = []
        for menu in CommandMenu.allCases {
            let cmds = CommandCatalog.all
                .filter { $0.menu?.menu == menu }
                .sorted { ($0.menu!.group, $0.menu!.order) < ($1.menu!.group, $1.menu!.order) }
            guard !cmds.isEmpty else { continue }
            let rows = cmds.enumerated().map { i, c in
                ShortcutRow("\(menu.title)#\(i)", c.title,
                            keys: ShortcutDisplay.string(key: c.key, modifiers: c.modifiers),
                            note: notes[c.id.rawValue])
            }
            out.append(ShortcutSection(menu.title, rows: rows))
        }
        return out
    }
}

/// Key-equivalent display: ⌃⌥⇧⌘ + the uppercased key (menu-bar order).
public enum ShortcutDisplay {
    public static func string(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        let named: [String: String] = [
            "\u{1b}": "Esc", " ": "Space",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            "\u{8}": "⌫",
        ]
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += named[key] ?? key.uppercased()
        return s
    }
}
