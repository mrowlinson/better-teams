// AppsCommands.swift — Apps library and web-app commands, sheet names
// (UI-SPEC §7.2, §7.3, §11.3 seam). CommandCatalog aggregates `all`.
// Web-app commands are owned by `.apps`: AppsSection forwards them to
// the web app on screen (every web app is its own section).
public enum AppsCommands {
    // Library (list toolbar, §7.2)
    public static let refresh: CommandID = "apps.refresh"
    public static let addWebLink: CommandID = "apps.addWebLink"
    public static let customizeTabBar: CommandID = "apps.customizeTabBar"

    // Web-app toolbar (§7.3), detail group, only in web content
    public static let back: CommandID = "web.back"
    public static let forward: CommandID = "web.forward"
    public static let reload: CommandID = "web.reload"
    public static let stop: CommandID = "web.stop"
    public static let more: CommandID = "web.more"

    public static let webCommands: Set<CommandID> = [back, forward, reload, stop, more]

    /// More ▸ submenu args.
    public enum MoreArg {
        public static let actualSize = "actualSize"
        public static let zoomIn = "zoomIn"
        public static let zoomOut = "zoomOut"
        public static let find = "find"
        public static let copyLink = "copyLink"
        public static let openInBrowser = "openInBrowser"
        public static let unload = "unload"
        public static let unpin = "unpin"
        public static let keep = "keep"
    }

    /// Sheet and popover names (evidence routes, §12).
    public static let customizeTabBarSheet = "customizeTabBar"
    public static let addWebLinkSheet = "addWebLink"

    @MainActor
    public static let all: [Command] = [
        Command(refresh, "Refresh Library", symbol: "arrow.clockwise",
                menu: .init(.view, group: 3, order: 0), toolbar: .list, owner: .apps),
        Command(customizeTabBar, "Customize Tab Bar…", menu: .init(.view, group: 3, order: 1), owner: .apps),
        Command(addWebLink, "Add Web Link…", symbol: "link.badge.plus",
                menu: .init(.file, group: 0, order: 9), toolbar: .list, owner: .apps),
        Command(back, "Back", symbol: "chevron.backward", key: "[",
                menu: .init(.view, group: 5, order: 0), toolbar: .detail, owner: .apps),
        Command(forward, "Forward", symbol: "chevron.forward", key: "]",
                menu: .init(.view, group: 5, order: 1), toolbar: .detail, owner: .apps),
        Command(reload, "Reload Page", symbol: "arrow.clockwise", key: "r",
                menu: .init(.view, group: 5, order: 2), toolbar: .detail, owner: .apps),
        Command(stop, "Stop Loading", key: ".", menu: .init(.view, group: 5, order: 3), owner: .apps),
        Command(more, "More", symbol: "ellipsis.circle", menu: .init(.view, group: 5, order: 4),
                toolbar: .detail, isSubmenu: true, owner: .apps),
    ]
}
