// ToDoCommands.swift — To Do commands (UI-SPEC §6.7, §9.1, §11.3 seam).
// CommandCatalog aggregates this list; menu placement is data.
public enum ToDoCommands {
    /// Show or hide completed tasks in the open list (checked state).
    public static let showCompleted: CommandID = "todo.showCompleted"

    @MainActor
    public static let all: [Command] = [
        Command(showCompleted, "Show Completed Tasks", menu: .init(.view, group: 4, order: 5),
                owner: .native(.todo)),
    ]
}
