// PlannerCommands.swift — Planner commands (UI-SPEC §6.7, §9.1, §11.3
// seam). CommandCatalog aggregates this list; menu placement is data.
// The task context menu's Mark as Complete has its menu-bar twin here.
public enum PlannerCommands {
    /// Complete / reopen the selected task (dynamic title).
    public static let toggleComplete: CommandID = "planner.toggleComplete"

    @MainActor
    public static let all: [Command] = [
        Command(toggleComplete, "Mark as Complete", alternateTitle: "Mark as Incomplete",
                menu: .init(.file, group: 5, order: 0), owner: .native(.planner)),
    ]
}
