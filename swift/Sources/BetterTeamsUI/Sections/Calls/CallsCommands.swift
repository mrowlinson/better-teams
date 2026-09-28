// CallsCommands.swift — Calls commands, sheet and popover names
// (UI-SPEC §6.5, §9.1, §11.3 seam). CommandCatalog aggregates this
// list; menu placement is data. Context-menu items (Call Back, Message)
// have menu-bar twins here.
public enum CallsCommands {
    public static let newCall: CommandID = "calls.newCall"
    public static let testCall: CommandID = "calls.testCall"
    public static let callBack: CommandID = "calls.callBack"
    public static let message: CommandID = "calls.message"

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
    ]
}
