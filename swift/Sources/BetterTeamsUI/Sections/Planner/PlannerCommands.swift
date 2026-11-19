// PlannerCommands.swift — Planner commands (UI-SPEC §6.7, §9.1, §11.3
// seam). CommandCatalog aggregates this list; menu placement is data.
// The task context menu's Mark as Complete has its menu-bar twin here.
public enum PlannerCommands {
    /// Complete / reopen the selected task (dynamic title).
    public static let toggleComplete: CommandID = "planner.toggleComplete"
    /// New plan (presents the sheet below).
    public static let newPlan: CommandID = "planner.newPlan"

    /// Sheet name (evidence routes, §12).
    public static let newPlanSheet = "newPlan"

    @MainActor
    public static let all: [Command] = [
        Command(toggleComplete, "Mark as Complete", alternateTitle: "Mark as Incomplete",
                menu: .init(.file, group: 5, order: 0), owner: .native(.planner)),
        // New Plan has no File-menu slot: adding one changes the pinned
        // menu-bar catalog (MenuShortcutCatalogGuardTests), which needs
        // owner OK quoted in the commit. The sheet stays reachable from
        // the board header button + perform(newPlan). Recommend the menu
        // slot as an owner-approved follow-up.
        Command(newPlan, "New Plan…", owner: .native(.planner)),
    ]
}
