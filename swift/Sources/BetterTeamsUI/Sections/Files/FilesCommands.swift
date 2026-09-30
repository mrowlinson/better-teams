// FilesCommands.swift — Files commands, sheet and popover names
// (UI-SPEC §6.6, §9.1, §11.3 seam). CommandCatalog aggregates this
// list; menu placement is data. Every context-menu item is one of these
// commands (title from the catalog, dispatch through the provider), so
// each has its menu-bar twin. `arg` = a file id (Files section) or
// `c:<id>` (a chat's or channel's Files tab).
public enum FilesCommands {
    public static let upload: CommandID = "files.upload"
    public static let quickLook: CommandID = "files.quickLook"
    public static let share: CommandID = "files.share"
    public static let transfers: CommandID = "files.transfers"
    public static let open: CommandID = "files.open"
    public static let openInBrowser: CommandID = "files.openInBrowser"
    public static let showInFinder: CommandID = "files.showInFinder"
    public static let download: CommandID = "files.download"
    public static let saveAs: CommandID = "files.saveAs"
    public static let copyLink: CommandID = "files.copyLink"
    public static let openConversation: CommandID = "files.openConversation"
    public static let rename: CommandID = "files.rename"
    public static let moveTo: CommandID = "files.moveTo"
    public static let copyTo: CommandID = "files.copyTo"
    public static let delete: CommandID = "files.delete"
    /// The file in its own window (R1).
    public static let openWindow: CommandID = "files.openWindow"

    /// Sheet and popover names (evidence routes, §12).
    public static let transfersPopover = "transfers"
    /// Rename… sheet (`arg` = the command arg).
    public static let renameSheet = "renameFile"
    /// Move To… / Copy To… destination sheet (`arg` = "move|<arg>" or
    /// "copy|<arg>").
    public static let destinationSheet = "fileDestination"

    /// Context menu (§6.6), in separator groups; unavailable items hide.
    static let contextGroups: [[CommandID]] = [
        [open, openInBrowser, quickLook, showInFinder, openWindow],
        [download, saveAs, copyLink, share],
        [openConversation],
        [rename, moveTo, copyTo, delete],
    ]

    @MainActor
    public static let all: [Command] = [
        Command(upload, "Upload\u{2026}", symbol: "arrow.up.doc", key: "u",
                menu: .init(.file, group: 2, order: 0), toolbar: .detail, owner: .files),
        Command(quickLook, "Quick Look", symbol: "eye", key: "y",
                menu: .init(.file, group: 3, order: 2), toolbar: .detail, owner: .files),
        Command(share, "Share\u{2026}", symbol: "square.and.arrow.up",
                menu: .init(.file, group: 4, order: 3), toolbar: .detail, owner: .files),
        Command(transfers, "Transfers", symbol: "arrow.down.circle", key: "l", modifiers: [.command, .option],
                menu: .init(.view, group: 7, order: 0), toolbar: .trailing, owner: .files),
        Command(open, "Open", key: "o", menu: .init(.file, group: 3, order: 0), owner: .files),
        Command(openInBrowser, "Open in Browser", menu: .init(.file, group: 3, order: 1), owner: .files),
        Command(openWindow, "Open in New Window", symbol: "macwindow.badge.plus",
                menu: .init(.file, group: 3, order: 5), owner: .files),
        Command(showInFinder, "Show in Finder", menu: .init(.file, group: 3, order: 3), owner: .files),
        Command(download, "Download", menu: .init(.file, group: 4, order: 0), owner: .files),
        // No shortcut: ⇧⌘S is Saved Messages (owner spec).
        Command(saveAs, "Save As\u{2026}",
                menu: .init(.file, group: 4, order: 1), owner: .files),
        Command(copyLink, "Copy Link", menu: .init(.file, group: 4, order: 2), owner: .files),
        Command(openConversation, "Open Conversation", menu: .init(.file, group: 3, order: 4), owner: .files),
        Command(rename, "Rename\u{2026}", menu: .init(.file, group: 6, order: 0), owner: .files),
        Command(moveTo, "Move To\u{2026}", menu: .init(.file, group: 6, order: 1), owner: .files),
        Command(copyTo, "Copy To\u{2026}", menu: .init(.file, group: 6, order: 2), owner: .files),
        // ⌘⌫, the Finder shortcut for removing an item.
        Command(delete, "Delete\u{2026}", key: "\u{8}", menu: .init(.file, group: 6, order: 3), owner: .files),
    ]
}
