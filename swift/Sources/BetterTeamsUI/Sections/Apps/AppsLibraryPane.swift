// AppsLibraryPane.swift — the Apps list pane and app card (UI-SPEC
// §7.2). Filter field at the top of the list (HIG search fields), then
// Pinned · Built-in (always present) · Channel Tabs · Personal Apps ·
// Web Links. Selection binds through Navigator (R3, R21); double-click
// or Return opens the app.
import AppKit
import SwiftUI

struct AppsListPane: View {
    let library: AppsLibrary
    @State private var filter = ""
    @Environment(\.windowModel) private var model

    var body: some View {
        if let m = model {
            VStack(spacing: 0) {
                SearchField(text: $filter, placeholder: "Filter Apps")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .accessibilityLabel("Filter Apps")
                content(m)
            }
        }
    }

    @ViewBuilder
    private func content(_ m: WindowModel) -> some View {
        let forced = m.forced(.apps)
        let f = filter.trimmingCharacters(in: .whitespaces)
        let pinned = m.rail.pinned.compactMap(library.item(for:)).filter { $0.matches(f) }
        let builtIns = library.builtIns.filter { $0.matches(f) }
        let tabs = forced == .empty ? [] : library.channelTabs.map(LibraryItem.init).filter { $0.matches(f) }
        let links = forced == .empty ? [] : library.webLinks.map(LibraryItem.init).filter { $0.matches(f) }
        let apps = forced == .empty ? [] : library.personalApps.map(LibraryItem.init).filter { $0.matches(f) }
        let browse = f.isEmpty || "Browse in Teams on the Web".localizedCaseInsensitiveContains(f)
        let personal = browse || !apps.isEmpty
        if pinned.isEmpty, builtIns.isEmpty, tabs.isEmpty, links.isEmpty, !personal {
            EmptyPane("No Results", systemImage: "magnifyingglass", message: "No apps match “\(f)”.")
        } else {
            list(m, forced: forced, filtering: !f.isEmpty, pinned: pinned, builtIns: builtIns,
                 tabs: tabs, links: links, apps: apps, personal: personal, browse: browse)
        }
    }

    private func list(_ m: WindowModel, forced: ForcedPaneState?, filtering: Bool, pinned: [LibraryItem],
                      builtIns: [LibraryItem], tabs: [LibraryItem], links: [LibraryItem],
                      apps: [LibraryItem], personal: Bool, browse: Bool) -> some View {
        let selection = Binding<String?>(
            get: { Self.tag(m.nav.selection(in: .apps)) },
            set: { tag in m.navigator?.select(tag.map(Self.selection(for:)), in: .apps) })
        let pinnedSet = Set(m.rail.pinned)
        return List(selection: selection) {
            if !filtering {
                // The Apps store (APPHOST-B2): all apps, then categories.
                Section("Discover") {
                    StoreNavRow(title: AppStoreRoute.all, symbol: "square.grid.2x2")
                        .tag("\(AppStoreRoute.group)|\(AppStoreRoute.categoryPrefix)\(AppStoreRoute.all)")
                    ForEach(library.store.categories.map(NamedItem.init)) { c in
                        StoreNavRow(title: c.id, symbol: StoreNavRow.symbol(c.id))
                            .tag("\(AppStoreRoute.group)|\(AppStoreRoute.categoryPrefix)\(c.id)")
                    }
                }
            }
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { AppRow(item: $0, pinned: true).tag("pinned|\($0.id)") }
                }
            }
            if !builtIns.isEmpty {
                Section("Built-in") {
                    ForEach(builtIns) { AppRow(item: $0, pinned: pinnedSet.contains($0.entry)).tag($0.id) }
                }
            }
            if !filtering || !tabs.isEmpty {
                Section("Channel Tabs") {
                    ForEach(tabs) { item in
                        AppRow(item: item, pinned: pinnedSet.contains(item.entry), detail: item.sourceLine)
                            .tag(item.id)
                    }
                    if !filtering { scanStatus(m, forced: forced, empty: tabs.isEmpty) }
                }
            }
            if personal {
                Section("Personal Apps") {
                    // Installed apps from the Teams app catalog, hosted natively.
                    ForEach(apps) { AppRow(item: $0, pinned: pinnedSet.contains($0.entry)).tag($0.id) }
                    if browse {
                        AppRow(item: LibraryItem(FrameBuiltIns.teamsWeb), pinned: false,
                               titleOverride: "Browse in Teams on the Web")
                            .tag("personal|\(FrameBuiltIns.teamsWebID)")
                    }
                }
            }
            if !links.isEmpty {
                Section("Web Links") {
                    ForEach(links) { AppRow(item: $0, pinned: pinnedSet.contains($0.entry)).tag($0.id) }
                }
            }
        }
        // The list's top edge draws no full-width rule above whichever
        // section comes first; the rules between sections stay inset.
        .listSectionSeparator(.hidden, edges: .top)
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { tags in
            if let tag = tags.first, let item = library.item(Self.selection(for: tag).id ?? "") {
                rowMenu(item, m)
            }
        } primaryAction: { tags in
            if let tag = tags.first, let item = library.item(Self.selection(for: tag).id ?? "") {
                AppActions.open(item, m)
            }
        }
    }

    /// First run / scanning / scan error / nothing found, inline (§7.2 States).
    @ViewBuilder
    private func scanStatus(_ m: WindowModel, forced: ForcedPaneState?, empty: Bool) -> some View {
        // Glyph in the rows' 20 pt symbol column, text at the rows' title
        // x (`AppRow`): the status sits on the row grid.
        if forced == .loading || (library.scanning && empty) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                    .frame(width: 20)
                Text("Scanning your channels for apps…").foregroundStyle(.secondary)
            }
            .selectionDisabled()
        } else if forced == .error || (library.scanError != nil && empty) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.failed)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(forced == .error ? "Couldn't scan your channels." : (library.scanError ?? ""))
                    .foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                // Same validation as the toolbar's Refresh Library.
                Button("Retry") { library.refresh() }
                    .controlSize(.small)
                    .disabled(!library.canRefresh(offline: m.connection == .offline))
            }
            .selectionDisabled()
        } else if empty {
            Text(library.scanned ? "No channel tabs found." : "Refresh the library to find your channel tabs.")
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }

    @ViewBuilder
    private func rowMenu(_ item: LibraryItem, _ m: WindowModel) -> some View {
        let pinned = m.rail.pinned.contains(item.entry)
        Button("Open") { AppActions.open(item, m) }
        Button(pinned ? "Unpin from Tab Bar" : "Pin to Tab Bar") { AppActions.togglePin(item, m) }
            .disabled(!pinned && !item.runsInApp)
        if item.launch != nil {
            Button("Open in Browser") { AppActions.openInBrowser(item, m) }
                .disabled(m.options.demo)
        }
        if item.isWebLink {
            Divider()
            Button("Remove…", role: .destructive) { AppActions.remove(item, m) }
        }
    }

    /// Selection ↔ row tag. Pinned and Personal rows carry a group
    /// prefix so one app listed twice highlights one row.
    static func tag(_ sel: SectionSelection?) -> String? {
        guard let sel, let id = sel.id else { return nil }
        return sel.path.count > 1 ? "\(sel.path[1])|\(id)" : id
    }

    static func selection(for tag: String) -> SectionSelection {
        let parts = tag.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? SectionSelection([parts[1], parts[0]]) : SectionSelection([tag])
    }
}

/// A Discover row: the store home or one category.
private struct StoreNavRow: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
        }
    }

    static func symbol(_ category: String) -> String {
        switch category.lowercased() {
        case "productivity": "bolt"
        case "project management": "chart.bar.doc.horizontal"
        case "workflow": "arrow.triangle.branch"
        case "communication": "bubble.left.and.bubble.right"
        case "utilities": "wrench.and.screwdriver"
        case "surveys": "checklist"
        case "finance": "dollarsign.circle"
        case "developer tools": "hammer"
        case "design": "paintbrush"
        case "education": "graduationcap"
        default: "tag"
        }
    }
}

/// One library row: symbol, name, optional source line, pinned glyph.
private struct AppRow: View {
    let item: LibraryItem
    let pinned: Bool
    var detail: String?
    var titleOverride: String?

    var body: some View {
        let title = titleOverride ?? item.title
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if pinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .help(title)
    }
}

// MARK: - Detail (app card)

struct AppsDetailPane: View {
    let library: AppsLibrary
    @Environment(\.windowModel) private var model

    var body: some View {
        if let m = model {
            let sel = m.nav.selection(in: .apps)
            if let page = AppStoreRoute.page(sel) {
                switch page {
                case .home(let category): AppStoreHome(library: library, category: category)
                case .detail(let id): AppStoreDetail(library: library, appID: id)
                }
            } else if let id = sel?.id, let item = library.item(id) {
                AppCard(item: item, library: library)
            } else {
                NoSelectionPane("No App Selected")
            }
        }
    }
}

private struct AppCard: View {
    let item: LibraryItem
    let library: AppsLibrary
    @Environment(\.windowModel) private var model

    var body: some View {
        if let m = model {
            card(m)
        }
    }

    private func card(_ m: WindowModel) -> some View {
        let pinned = m.rail.pinned.contains(item.entry)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: item.symbol)
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(.tint.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.title2.weight(.semibold))
                    Text(item.sourceLine).foregroundStyle(.secondary)
                }
            }
            Label(capability, systemImage: item.runsInApp ? "app.badge.checkmark" : "arrow.up.forward.app")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Open") { AppActions.open(item, m) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!item.runsInApp && m.options.demo)
                Button(pinned ? "Unpin" : "Pin to Tab Bar") { AppActions.togglePin(item, m) }
                    .disabled(!pinned && !item.runsInApp)
                if item.launch != nil {
                    Button("Open in Browser") { AppActions.openInBrowser(item, m) }
                        .disabled(m.options.demo)
                }
                if item.isWebLink {
                    Button("Remove…", role: .destructive) { AppActions.remove(item, m) }
                }
            }
            if !item.runsInApp {
                Text("Apps that open in your browser can't be pinned to the tab bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if case .web(let id) = item.entry, case .teamsHosted = item.launch {
                AppCardAdvanced(id: id, host: m.frameHost, demo: m.options.demo)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var capability: String {
        guard let launch = item.launch, !launch.runsInApp else { return "Runs in Better Teams" }
        return "Opens in your browser — \(launch.url.host ?? "this site") isn't a Microsoft 365 site."
    }
}
