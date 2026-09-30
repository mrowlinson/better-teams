// AppsSection.swift — Apps section provider (UI-SPEC §7.2).
//
// List = the app library (filter field, Pinned · Built-in · Channel
// Tabs · Personal Apps · Web Links); detail = the app card. Opening an
// app selects its own section (a web app renders in-window like Files;
// an unpinned app becomes the rail's transient item). Also owns the
// web-app commands (§7.3) and forwards them to the web app on screen.
import AppKit
import OstMacCore
import SwiftUI

@MainActor
final class AppsSection: SectionProvider {
    let section: SectionID = .apps
    let title = "Apps"

    func listPane(_ m: WindowModel) -> AnyView {
        AnyView(AppsListPane(library: m.frameHost.library))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        AnyView(AppsDetailPane(library: m.frameHost.library))
    }

    var allToolbarItems: [CommandID] { [AppsCommands.refresh, AppsCommands.addWebLink] }

    /// `apps/detail?id=<appID>` = store detail, `apps/store?category=<c>`
    /// = store category (APPHOST-B2); other paths select library rows.
    func selection(for route: Route) -> SectionSelection? {
        switch route.tail.first {
        case "detail":
            guard let id = route.query["id"], !id.isEmpty else { return nil }
            return AppStoreRoute.detail(id)
        case "store":
            return route.query["category"].map(AppStoreRoute.category)
        default:
            return route.tail.isEmpty ? nil : SectionSelection(route.tail)
        }
    }

    /// The library loads itself (catalog + store on window open); a
    /// selection change fetches nothing.
    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {}

    // MARK: commands

    /// The web app on screen (web commands forward to it).
    private func webApp(_ m: WindowModel) -> WebAppSection? {
        guard m.nav.search == nil, case .web = m.nav.section else { return nil }
        return m.provider(m.nav.section) as? WebAppSection
    }

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        if AppsCommands.webCommands.contains(c) { return webApp(m)?.perform(c, arg: arg, m) ?? false }
        switch c {
        case AppsCommands.refresh: m.frameHost.library.refresh()
        case AppsCommands.addWebLink: m.presentSheet(SheetRequest(AppsCommands.addWebLinkSheet, in: .apps))
        case AppsCommands.customizeTabBar: m.presentSheet(SheetRequest(AppsCommands.customizeTabBarSheet, in: .apps))
        default: return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        if AppsCommands.webCommands.contains(c) { return webApp(m)?.validate(c, arg: arg, m) ?? .disabled }
        switch c {
        case AppsCommands.refresh:
            let lib = m.frameHost.library
            return CommandValidation(enabled: lib.canRefresh(offline: m.connection == .offline))
        case AppsCommands.addWebLink, AppsCommands.customizeTabBar: return .enabled
        default: return .disabled
        }
    }

    func submenuItems(_ c: CommandID, _ m: WindowModel) -> [SubmenuItem] {
        webApp(m)?.submenuItems(c, m) ?? []
    }

    func sheet(_ r: SheetRequest, _ m: WindowModel) -> AnyView? {
        switch r.name {
        case AppsCommands.customizeTabBarSheet: AnyView(CustomizeTabBarSheet(library: m.frameHost.library))
        case AppsCommands.addWebLinkSheet: AnyView(AddWebLinkSheet(library: m.frameHost.library))
        default: nil
        }
    }
}

/// Actions shared by the library rows, the card and the rail.
@MainActor
enum AppActions {
    static func open(_ item: LibraryItem, _ m: WindowModel) {
        if let launch = item.launch, !launch.runsInApp {
            if !m.options.demo { TeamsLinkRouter.open(launch.url) }
            return
        }
        m.navigator?.select(section: item.entry.section)
    }

    static func togglePin(_ item: LibraryItem, _ m: WindowModel) {
        if m.rail.pinned.contains(item.entry) {
            m.navigator?.unpin(item.entry)
        } else if item.runsInApp {
            m.rail.pin(item.entry)
        }
    }

    static func openInBrowser(_ item: LibraryItem, _ m: WindowModel) {
        guard !m.options.demo, let url = item.launch?.url else { return }
        TeamsLinkRouter.openInBrowser(url)
    }

    static func remove(_ item: LibraryItem, _ m: WindowModel) {
        guard item.isWebLink, case .web(let id) = item.entry else { return }
        m.confirm(title: "Remove “\(item.title)”?",
                  message: "The link is removed from your library and the tab bar.", action: "Remove") {
            if m.rail.pinned.contains(item.entry) { m.rail.unpin(item.entry) }
            if m.rail.transient == item.entry { m.navigator?.closeTransient() }
            m.frameHost.unload(.app(id))
            m.frameHost.library.removeWebLink(id)
            m.navigator?.select(nil, in: .apps)
        }
    }
}
