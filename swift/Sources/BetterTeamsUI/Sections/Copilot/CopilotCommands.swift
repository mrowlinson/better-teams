// CopilotCommands.swift — Copilot commands (UI-SPEC §6.7, §9.1,
// §11.3 seam). CommandCatalog aggregates this list; menu placement
// is data. The input-bar Stop button has a menu-bar twin here.
public enum CopilotCommands {
    /// Clear the conversation (the next turn starts a new one).
    public static let newChat: CommandID = "copilot.new"
    /// Cancel the in-flight turn (real only while streaming).
    public static let stop: CommandID = "copilot.stop"

    @MainActor
    public static let all: [Command] = [
        Command(newChat, "New Copilot Chat", symbol: "square.and.pencil",
                menu: .init(.file, group: 6, order: 0), toolbar: .detail, owner: .native(.copilot)),
        Command(stop, "Stop Copilot", symbol: "stop.circle",
                menu: .init(.file, group: 6, order: 1), toolbar: .detail, owner: .native(.copilot)),
    ]
}
