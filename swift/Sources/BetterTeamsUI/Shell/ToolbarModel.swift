// ToolbarModel.swift — the pure visibility function (UI-SPEC §5.4,
// DL3). The toolbar's identifier list is a fixed superset created once;
// `ShellToolbarController.sync()` sets `isHidden` on the difference.
import Foundation

@MainActor
public enum ToolbarModel {
    /// Always-present trailing items. The inspector toggle stays visible
    /// and validates off where there is no inspector ("enablement comes
    /// from validation, never from hiding"): a hidden item beside the
    /// inspector tracking separator left a hole at the trailing edge.
    static let fixedTrailing: [CommandID] = [ShellCommand.inspector, ShellCommand.account, ShellCommand.search]

    public static func visible(
        items: [CommandID], layout: SectionLayout, hasInspector: Bool,
        searching: Bool, call: Bool, connection: ConnectionState,
        searchItems: [CommandID] = []
    ) -> Set<CommandID> {
        var out = Set(fixedTrailing)
        if connection != .online { out.insert(ShellCommand.connection) }
        // Toolbar call item (§8): a running call whose stage is not on
        // screen in this window.
        if call { out.insert(CallCommands.show) }
        // Search mode: section items hide; a conversation in the search
        // detail brings its own items (the shared conversation view).
        guard !searching else { return out.union(searchItems) }
        for id in items {
            let group = CommandCatalog.command(id)?.toolbar
            // In `.full` the list pane is collapsed: list-group originals
            // hide (their detail-group twins carry them, §5.4).
            if layout == .full, group == .list { continue }
            out.insert(id)
        }
        return out
    }
}
