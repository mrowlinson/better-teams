// CallsCommands.swift — Calls commands, sheet and popover names
// (UI-SPEC §6.5, §9.1, §11.3 seam). CommandCatalog aggregates this
// list; menu placement is data. Context-menu items (Call Back, Message,
// Speed Dial and Recents edits) have menu-bar twins here.
public enum CallsCommands {
    public static let newCall: CommandID = "calls.newCall"
    public static let testCall: CommandID = "calls.testCall"
    public static let callBack: CommandID = "calls.callBack"
    public static let message: CommandID = "calls.message"
    public static let removeFromRecents: CommandID = "calls.removeFromRecents"
    public static let clearHistory: CommandID = "calls.clearHistory"
    public static let addToSpeedDial: CommandID = "calls.addToSpeedDial"
    public static let removeFromSpeedDial: CommandID = "calls.removeFromSpeedDial"

    /// Sheet names (evidence routes, §12).
    public static let newCallSheet = "newCall"

    @MainActor
    public static let all: [Command] = [
        Command(newCall, "New Call…", symbol: "phone.badge.plus",
                menu: .init(.file, group: 0, order: 6), toolbar: .list, owner: .calls),
        Command(testCall, "Test Call", symbol: "waveform",
                menu: .init(.call, group: 3, order: 0), toolbar: .list, owner: .calls),
        Command(callBack, "Call Back", menu: .init(.call, group: 0, order: 3), owner: .calls),
        Command(message, "Message", menu: .init(.call, group: 0, order: 4), owner: .calls),
        Command(addToSpeedDial, "Add to Speed Dial", menu: .init(.call, group: 4, order: 0), owner: .calls),
        Command(removeFromSpeedDial, "Remove from Speed Dial", menu: .init(.call, group: 4, order: 1), owner: .calls),
        Command(removeFromRecents, "Remove from Recents", menu: .init(.call, group: 4, order: 2), owner: .calls),
        Command(clearHistory, "Clear Call History\u{2026}", menu: .init(.call, group: 4, order: 3), owner: .calls),
    ]
}
