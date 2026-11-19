// ApprovalsCommands.swift — approvals commands (UI-SPEC §6.7,
// §9.1, §11.3 seam). CommandCatalog aggregates this list; menu
// placement is data. The detail approve/reject buttons have menu-bar
// twins here.
public enum ApprovalsCommands {
    /// Reload the approvals list.
    public static let refresh: CommandID = "approvals.refresh"
    /// Approve the selected request (dynamic title).
    public static let approve: CommandID = "approvals.approve"
    /// Reject the selected request (dynamic title).
    public static let reject: CommandID = "approvals.reject"

    @MainActor
    public static let all: [Command] = [
        Command(refresh, "Refresh Approvals",
                menu: .init(.view, group: 5, order: 0), owner: .native(.approvals)),
        Command(approve, "Approve Request",
                menu: .init(.file, group: 5, order: 0), owner: .native(.approvals)),
        Command(reject, "Reject Request",
                menu: .init(.file, group: 5, order: 1), owner: .native(.approvals)),
    ]
}
