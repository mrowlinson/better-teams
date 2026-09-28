// FilesViews.swift — Files panes (UI-SPEC §6.6): the source list, the
// file table (shared with a chat's and a channel's Files tab), the
// folder breadcrumb, and the inspector (info + Versions).
import AppKit
import OstMacCore
import SwiftUI

// MARK: list (sources)

struct FilesSourceList: View {
    @ObservedObject var teams: TeamsViewModel
    @Environment(\.windowModel) private var model
    /// Teams whose disclosure the user flipped from its default (open
    /// when it holds the selected channel, else closed).
    @State private var flipped: Set<String> = []

    var body: some View {
        if let model {
            list(model)
        }
    }

    private func list(_ m: WindowModel) -> some View {
        let current = FilesSection.source(m)
        let selection = Binding<String?>(
            get: { current.key },
            set: { key in
                guard let key, let s = FilesSource(key: key), s != FilesSection.source(m) else { return }
                FilesSection.select(source: s, m)
            })
        return List(selection: selection) {
            Section {
                row(.recent)
                row(.myFiles)
                row(.shared)
            }
            if !teams.teams.isEmpty {
                Section("Teams") {
                    ForEach(teams.teams) { team in
                        DisclosureGroup(isExpanded: expanded(team, current)) {
                            ForEach(team.channels) { c in
                                Label(c.name, systemImage: FilesSource.channel(c.channelId).symbol)
                                    .lineLimit(1)
                                    .tag(FilesSource.channel(c.channelId).key)
                            }
                        } label: {
                            Label(team.name, systemImage: "person.3").lineLimit(1)
                        }
                    }
                }
            }
            Section {
                row(.downloads)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ s: FilesSource) -> some View {
        Label(s.title, systemImage: s.symbol).tag(s.key)
    }

    private func expanded(_ team: TeamItem, _ current: FilesSource) -> Binding<Bool> {
        let holdsSelection: Bool = {
            if case .channel(let id) = current { return team.channels.contains { $0.channelId == id } }
            return false
        }()
        return Binding(
            get: { holdsSelection != flipped.contains(team.teamId) },
            set: { open in
                guard open != (holdsSelection != flipped.contains(team.teamId)) else { return }
                if flipped.contains(team.teamId) { flipped.remove(team.teamId) } else { flipped.insert(team.teamId) }
            })
    }
}

// MARK: detail (table)

struct FilesDetailPane: View {
    @ObservedObject var unified: UnifiedFilesStore
    @ObservedObject var library: SharedFilesStore
    @ObservedObject var transfers: TransferStore
    @ObservedObject var teams: TeamsViewModel
    let section: FilesSection
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let app = model.app {
            content(model, app)
                .task { section.applyEvidence(model) }
        }
    }

    private func content(_ m: WindowModel, _ app: AppState) -> some View {
        let source = FilesSection.source(m)
        let items = section.items(source, app)
        let storeState = section.state(source, app)
        let state = FilesPaneState.resolve(
            storeState, count: items.count, forced: m.forced(.files),
            forcedOffline: m.options.demo && section.evidence.offline, offline: m.connection == .offline)
        let shown = state == .files ? items : []
        let selection = Binding<Set<String>>(
            get: { Set(FilesSection.selectedIDs(m)) },
            set: { ids in FilesSection.select(source: source, ids: shown.map(\.id).filter(ids.contains), m) })
        let isChannel: Bool = { if case .channel = source { return true } else { return false } }()
        return VStack(spacing: 0) {
            if isChannel, !library.crumbs.isEmpty {
                FolderCrumbs(store: library, root: FilesSection.channelName(library.chatID ?? "", teams.teams))
                Divider()
            }
            FileTableView(items: shown, selection: selection, state: state, emptyMessage: source.emptyMessage,
                          canUpload: source.acceptsUpload, argPrefix: "", linksLocation: true) {
                guard !m.options.demo else { return }
                if isChannel { library.refresh() } else { unified.refresh() }
            }
            // R12: a refresh (or an uncached folder) loads behind the rows.
            .refreshStatus(state == .files && storeState == .loading,
                           failure: state == .files ? FilesPaneState.failure(storeState) : nil,
                           label: "Updating Files", retry: {
                               guard !m.options.demo else { return }
                               if isChannel { library.refresh() } else { unified.refresh() }
                           })
        }
    }
}

/// The one file table (§6.6): Name (icon, middle truncation), Modified,
/// Modified By, Size, Location; header click sorts, again reverses;
/// resizable columns, alternating rows, multi-select. Empty, loading
/// and error states sit inside the table area under the header. Space =
/// Quick Look; Return / double-click = Open; drops upload.
struct FileTableView: View {
    let items: [FileItem]
    @Binding var selection: Set<String>
    let state: FilesPaneState
    let emptyMessage: String
    let canUpload: Bool
    /// Command `arg` prefix: "" in the Files section, `c:` in a chat's
    /// or channel's Files tab.
    let argPrefix: String
    /// Location opens the source conversation (not inside the
    /// conversation itself).
    let linksLocation: Bool
    let retry: () -> Void
    @Environment(\.windowModel) private var model
    @State private var order = [KeyPathComparator(\FileItem.modifiedKey, order: .reverse)]

    var body: some View {
        if let model {
            table(model)
        }
    }

    private func table(_ m: WindowModel) -> some View {
        Table(items.sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { f in
                HStack(spacing: 6) {
                    Image(nsImage: f.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Modified", value: \.modifiedKey) { f in
                Text(FilesFormat.date(f.modified)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            // Fits "Sep 25, 2026 at 10:58 AM" without truncating.
            .width(min: 170, ideal: 190)
            TableColumn("Modified By", value: \.modifiedBy) { f in
                Text(f.modifiedBy).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 120)
            TableColumn("Size", value: \.size) { f in
                Text(f.isFolder ? "--" : FilesFormat.size(f.size)).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Location", value: \.location) { f in
                location(f, m)
            }
            .width(min: 90, ideal: 170)
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { ids in
            // The clicked row, or the whole selection when it holds that
            // row: Delete / Move / Copy act on every item (Finder).
            let args = items.filter { ids.contains($0.id) }.map { argPrefix + $0.id }
            if !args.isEmpty { FilesContextMenu(arg: FilesSection.multiArg(args)) }
        } primaryAction: { ids in
            // Double-click / Return opens every selected item (Finder).
            let args = items.filter { ids.contains($0.id) }.map { argPrefix + $0.id }
            if args.count > 1 {
                _ = m.provider(.files).perform(FilesCommands.open, arg: FilesSection.multiArg(args), m)
            } else if let id = ids.first {
                run(FilesCommands.open, id, m)
            }
        }
        .onKeyPress(.space) {
            guard let id = items.first(where: { selection.contains($0.id) })?.id else { return .ignored }
            run(FilesCommands.quickLook, id, m)
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            let paths = urls.filter(\.isFileURL).map(\.path)
            guard canUpload, !paths.isEmpty, let files = m.provider(.files) as? FilesSection else { return false }
            files.upload(paths: paths, m)
            return true
        }
        .overlay { overlay(m) }
    }

    @ViewBuilder
    private func location(_ f: FileItem, _ m: WindowModel) -> some View {
        if linksLocation, let id = f.locationID {
            Button(f.location) { FilesSection.openSource(id, name: f.location, m) }
                .buttonStyle(.link)
                .lineLimit(1)
                .help("Open \(f.location)")
                .accessibilityLabel("in \(f.location)")
        } else {
            Text(f.location).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private func overlay(_ m: WindowModel) -> some View {
        switch state {
        case .files:
            EmptyView()
        case .loading:
            LoadingPane("Loading Files\u{2026}")
        case .error(let message):
            ErrorPane(title: FilesPaneState.errorTitle, message: message, retry: retry)
        case .empty:
            EmptyPane("No Files", systemImage: "folder", message: emptyMessage) {
                if canUpload {
                    Button(CommandCatalog.command(FilesCommands.upload)?.title ?? "Upload\u{2026}") {
                        _ = m.provider(.files).perform(FilesCommands.upload, arg: nil, m)
                    }
                }
            }
        }
    }

    private func run(_ c: CommandID, _ id: String, _ m: WindowModel) {
        _ = m.provider(.files).perform(c, arg: argPrefix + id, m)
    }
}

/// Context menu (§6.6): catalog commands in separator groups, titles from
/// `CommandCatalog`, unavailable items hidden (HIG context menus).
struct FilesContextMenu: View {
    let arg: String
    @Environment(\.windowModel) private var model

    struct Item: Identifiable {
        let cmd: Command
        var id: String { cmd.id.rawValue }
    }

    struct MenuGroup: Identifiable {
        let id: Int
        let items: [Item]
    }

    var body: some View {
        if let model {
            let p = model.provider(.files)
            let groups = FilesCommands.contextGroups.map { ids in
                ids.compactMap(CommandCatalog.command).filter { p.validate($0.id, arg: arg, model).enabled }.map(Item.init)
            }
            .filter { !$0.isEmpty }
            let numbered = zip(groups.indices, groups).map { MenuGroup(id: $0, items: $1) }
            ForEach(numbered) { g in
                if g.id > 0 { Divider() }
                ForEach(g.items) { item in
                    Button(item.cmd.title) { _ = p.perform(item.cmd.id, arg: arg, model) }
                }
            }
        }
    }
}

/// Folder drill-in breadcrumb (§6.6): borderless buttons.
struct FolderCrumbs: View {
    @ObservedObject var store: SharedFilesStore
    let root: String

    var body: some View {
        HStack(spacing: 4) {
            Button(root) { store.goToRoot() }
            ForEach(crumbs) { c in
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                Button(c.name) { store.goTo(depth: c.id) }
                    .disabled(c.id == store.crumbs.count)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    struct Crumb: Identifiable {
        let id: Int
        let name: String
    }

    private var crumbs: [Crumb] {
        zip(store.crumbs.indices, store.crumbs).map { Crumb(id: $0 + 1, name: $1.name) }
    }
}

// MARK: inspector

struct FilesInspector: View {
    @ObservedObject var unified: UnifiedFilesStore
    @ObservedObject var library: SharedFilesStore
    @ObservedObject var transfers: TransferStore
    @ObservedObject var versions: FileVersionsStore
    let section: FilesSection
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model {
            let ids = FilesSection.selectedIDs(model)
            if ids.count > 1 {
                NoSelectionPane("\(ids.count) Files Selected")
            } else if let it = ids.first.flatMap({ section.item($0, model) }) {
                details(it, model)
            } else {
                NoSelectionPane("No File Selected")
            }
        }
    }

    private func details(_ it: FileItem, _ m: WindowModel) -> some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(nsImage: it.icon).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                    Text(it.name).font(AppFont.bodyEmphasized(m.textScale)).lineLimit(2).truncationMode(.middle)
                }
            }
            Section("Info") {
                LabeledContent("Kind", value: it.kindLabel)
                if !it.isFolder { LabeledContent("Size", value: FilesFormat.size(it.size)) }
                LabeledContent("Modified", value: FilesFormat.date(it.modified))
                if !it.modifiedBy.isEmpty { LabeledContent("Modified By", value: it.modifiedBy) }
                if let created = it.row?.file.created { LabeledContent("Created", value: FilesFormat.date(iso: created)) }
                LabeledContent("Location") {
                    if let id = it.locationID {
                        Button(it.location) { FilesSection.openSource(id, name: it.location, m) }
                            .buttonStyle(.link)
                            .accessibilityLabel("in \(it.location)")
                    } else {
                        Text(it.location)
                    }
                }
                if let row = it.row, row.file.drive_id != nil {
                    LabeledContent("Link") {
                        if let link = unified.link(for: row) {
                            Text(link).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        } else {
                            Button(CommandCatalog.command(FilesCommands.copyLink)?.title ?? "Copy Link") {
                                _ = section.perform(FilesCommands.copyLink, arg: it.id, m)
                            }
                        }
                    }
                }
            }
            if let row = it.row, !it.isFolder, row.file.drive_id != nil {
                Section("Versions") {
                    versionList(row.file.id)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func versionList(_ fileID: String) -> some View {
        if versions.itemID != fileID || (versions.state == .loading && versions.versions.isEmpty) {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if case .error(let msg) = versions.state, versions.versions.isEmpty {
            LabeledContent(msg) {
                Button("Try Again") { versions.refresh() }
            }
        } else if versions.versions.isEmpty {
            Text("No earlier versions").foregroundStyle(.secondary)
        } else {
            ForEach(versions.versions) { v in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.id == versions.versions.first?.id ? "Current Version" : "Version \(v.id)")
                        Text([FilesFormat.date(iso: v.modified), v.modified_by ?? ""].filter { !$0.isEmpty }
                            .joined(separator: " \u{00B7} "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if v.id != versions.versions.first?.id {
                        Button("Restore") { versions.restore(v) }
                            .disabled(versions.restoringIDs.contains(v.id))
                    }
                    Button("Download") { versions.save(v) }
                        .disabled(versions.savingIDs.contains(v.id))
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
