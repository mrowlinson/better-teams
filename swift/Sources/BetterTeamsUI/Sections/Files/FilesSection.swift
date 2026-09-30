// FilesSection.swift — Files section provider (UI-SPEC §6.6).
//
// List: the fixed sources (Recent · My Files · Shared in Chats · Teams ›
// channel · Downloads). Detail: the file table of the selected source
// (never a no-selection pane: nil selection = Recent). Inspector: info +
// Versions for one selected file. Rows come from the account's Files
// index (`UnifiedFilesStore`), a Files-owned channel-library store, and
// `TransferStore` (downloads). Loads start in `selectionDidChange` (R24).
import AppKit
import Combine
import OstMacCore
import SwiftUI

@MainActor
final class FilesSection: SectionProvider, InspectorCapable {
    let section: SectionID = .files
    let title = "Files"
    let hasInspector = true

    /// Channel library (Teams › channel): its own store, so browsing a
    /// channel here never moves the open conversation's Files tab.
    let library = SharedFilesStore()
    let versions = FileVersionsStore()
    let transfersPopover = TransfersPopover()
    private var uploadWatch: AnyCancellable?

    /// Evidence requests from the launch route (demo only).
    struct Evidence: Equatable {
        var popover: String?
        var quickLook = false
        var offline = false
    }

    private(set) var evidence = Evidence()
    private var evidenceApplied = false

    /// Evidence alias (`files/recent/demo-file`, §12).
    static let demoFileAlias = "demo-file"
    static let demoFileID = "demo-u-chat1"

    func listPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane("No Files", systemImage: "folder"))
        }
        return AnyView(FilesSourceList(teams: app.teams))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        guard let app = m.app else {
            return AnyView(EmptyPane("No Files", systemImage: "folder", message: FilesSource.recent.emptyMessage))
        }
        return AnyView(FilesDetailPane(unified: app.unifiedFiles, library: library, transfers: app.transfers,
                                       teams: app.teams, section: self))
    }

    func inspector(_ m: WindowModel) -> AnyView? {
        guard let app = m.app else { return nil }
        return AnyView(FilesInspector(unified: app.unifiedFiles, library: library, transfers: app.transfers,
                                      versions: versions, section: self))
    }

    var allToolbarItems: [CommandID] {
        [FilesCommands.upload, FilesCommands.quickLook, FilesCommands.share, FilesCommands.transfers]
    }

    /// `files/<source>[/<file id>…]`, `files?select=<id>` (in Recent),
    /// plus the evidence queries `popover=transfers`, `quicklook=1`,
    /// `state=offline`.
    func selection(for route: Route) -> SectionSelection? {
        evidence = Evidence(popover: route.query["popover"], quickLook: route.query["quicklook"] == "1",
                            offline: route.query["state"] == "offline")
        evidenceApplied = false
        var path = route.tail
        if path.isEmpty, let id = route.query["select"], !id.isEmpty { path = [FilesSource.recent.key, id] }
        guard !path.isEmpty else { return nil }
        path = path.map { $0 == Self.demoFileAlias ? Self.demoFileID : $0 }
        return SectionSelection(path)
    }

    // MARK: selection

    static func source(_ m: WindowModel) -> FilesSource {
        m.nav.selection(in: .files)?.path.first.flatMap(FilesSource.init(key:)) ?? .recent
    }

    static func selectedIDs(_ m: WindowModel) -> [String] {
        Array((m.nav.selection(in: .files)?.path ?? []).dropFirst())
    }

    static func select(source: FilesSource, ids: [String] = [], _ m: WindowModel) {
        m.navigator?.select(SectionSelection([source.key] + ids), in: .files)
    }

    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard m.app != nil else { return }
        if m.options.demo, evidence.offline { m.setConnection(.offline) }
        let source = sel?.path.first.flatMap(FilesSource.init(key:)) ?? .recent
        if case .channel(let id) = source, library.chatID != id {
            if m.options.demo {
                library.showDemo(chatID: id, files: DemoData.sharedFiles(for: id))
            } else {
                library.open(chatID: id)
            }
        }
        // Versions for the one selected remote file (inspector).
        let ids = Array((sel?.path ?? []).dropFirst())
        guard ids.count == 1, let row = item(ids[0], m)?.row, !row.file.isFolder,
              let drive = row.file.drive_id, versions.itemID != row.file.id else { return }
        if m.options.demo {
            versions.showDemo(driveID: drive, itemID: row.file.id, filename: row.file.name,
                              versions: DemoData.fileVersions(for: row.file.id))
        } else {
            versions.open(driveID: drive, itemID: row.file.id, filename: row.file.name)
        }
    }

    /// Evidence (demo): the route's popover or Quick Look, once, after
    /// the window is on screen (the table's first appearance, else the
    /// app's after-startup evidence hook).
    func applyEvidence(_ m: WindowModel) {
        // The popover anchors to the toolbar item: wait for the window.
        guard m.options.demo, !evidenceApplied, Self.window(m)?.isVisible == true else { return }
        evidenceApplied = true
        if evidence.popover == FilesCommands.transfersPopover { showTransfers(m) }
        if evidence.quickLook { _ = perform(FilesCommands.quickLook, arg: nil, m) }
    }

    /// Evidence geometry field: the Transfers popover's state. It opens
    /// inside the window frame, so the capture rect cannot show it.
    static func geometry(_ m: WindowModel) -> String {
        guard m.nav.section == .files, let f = m.provider(.files) as? FilesSection else { return "" }
        return " transfersPopover=\(f.transfersPopover.isShown)"
    }

    // MARK: rows

    /// The selected source's rows (one builder for table, inspector and
    /// commands).
    func items(_ source: FilesSource, _ app: AppState) -> [FileItem] {
        let rows = app.unifiedFiles.rows
        switch source {
        case .recent: return rows.map(FileItem.remote)
        case .myFiles: return rows.filter { $0.source == .drive }.map(FileItem.remote)
        case .shared: return rows.filter { $0.source == .chat }.map(FileItem.remote)
        case .channel(let id):
            guard library.chatID == id else { return [] }
            let name = Self.channelName(id, app.teams.teams)
            return library.files.map {
                FileItem.remote(UnifiedFileRow(file: $0, source: .channel, sourceName: name, sourceID: id))
            }
        case .downloads: return app.transfers.downloads.map(FileItem.local)
        }
    }

    func state(_ source: FilesSource, _ app: AppState) -> SharedFilesState {
        switch source {
        case .recent, .myFiles, .shared: app.unifiedFiles.state
        case .channel(let id): library.chatID == id ? library.state : .loading
        case .downloads: .loaded
        }
    }

    static func channelName(_ id: String, _ teams: [TeamItem]) -> String {
        for t in teams {
            if let c = t.channels.first(where: { $0.channelId == id }) { return "\(t.name) > #\(c.name)" }
        }
        return "Channel"
    }

    static let conversationPrefix = "c:"

    /// A command's file: `arg` = file id in the Files section, `c:<id>`
    /// in a chat's or channel's Files tab; nil = the first selected row.
    /// A multi-item arg (FilesManage) names its first item here.
    func item(_ arg: String?, _ m: WindowModel) -> FileItem? {
        guard let app = m.app else { return nil }
        if let arg, arg.contains(Self.argSeparator) {
            return arg.split(separator: Self.argSeparator).first.flatMap { item(String($0), m) }
        }
        if let arg, arg.hasPrefix(Self.conversationPrefix) {
            let id = String(arg.dropFirst(Self.conversationPrefix.count))
            guard let f = app.shared.files.first(where: { $0.id == id }), let chat = app.shared.chatID else { return nil }
            let name = m.graph.chats.chats.first { $0.id == chat }?.name ?? Self.channelName(chat, app.teams.teams)
            let isChannel = app.teams.teams.contains { $0.channels.contains { $0.channelId == chat } }
            return .remote(UnifiedFileRow(file: f, source: isChannel ? .channel : .chat, sourceName: name,
                                          sourceID: chat))
        }
        guard m.nav.section == .files || arg != nil,
              let id = arg ?? Self.selectedIDs(m).first else { return nil }
        // A transfer (Transfers popover) may sit outside the shown source.
        return items(Self.source(m), app).first { $0.id == id }
            ?? app.transfers.items.first { $0.id == id }.map(FileItem.local)
    }

    // MARK: commands

    func perform(_ c: CommandID, arg: String?, _ m: WindowModel) -> Bool {
        guard let app = m.app else { return false }
        if c == FilesCommands.transfers {
            showTransfers(m)
            return true
        }
        if c == FilesCommands.upload {
            if m.nav.section != .files { m.navigator?.select(section: .files) }
            chooseUpload(m)
            return true
        }
        if Self.manageCommands.contains(c) { return performManage(c, arg: arg, m) }
        if Self.multiCommands.contains(c) {
            let all = items(forArg: arg, m)
            if all.count > 1 { return runMulti(c, all, app, m) }
        }
        guard let it = item(arg, m) else { return false }
        return run(c, it, arg: arg, app, m)
    }

    /// Open / Download / Copy Link act on every selected item (Finder).
    static let multiCommands: Set<CommandID> = [FilesCommands.open, FilesCommands.download, FilesCommands.copyLink]

    /// A multi-item Open / Download / Copy Link. Folders are skipped
    /// (a folder drills in only on its own); Copy Link copies every link
    /// at once, one per line.
    private func runMulti(_ c: CommandID, _ all: [FileItem], _ app: AppState, _ m: WindowModel) -> Bool {
        let files = all.filter { !$0.isFolder }
        switch c {
        case FilesCommands.open:
            guard let first = files.first else { return false }
            // Demo previews instead of launching apps: one Quick Look.
            if m.options.demo { quickLook(first, app, m) } else { for it in files { open(it, app, m) } }
        case FilesCommands.download:
            let rows = files.compactMap { it in it.row.map { (it, $0) } }
            guard !rows.isEmpty else { return false }
            for (it, row) in rows { download(row, it, app, to: nil) }
        case FilesCommands.copyLink:
            let rows = all.compactMap(\.row).filter { $0.file.drive_id != nil }
            guard !rows.isEmpty else { return false }
            app.unifiedFiles.shareLinks(rows)
        default:
            return false
        }
        return true
    }

    private func validateMulti(_ c: CommandID, _ all: [FileItem]) -> CommandValidation {
        switch c {
        case FilesCommands.open: CommandValidation(enabled: all.contains { !$0.isFolder })
        case FilesCommands.download: CommandValidation(enabled: all.contains { !$0.isFolder && $0.row != nil })
        case FilesCommands.copyLink: CommandValidation(enabled: all.contains { $0.row?.file.drive_id != nil })
        default: .disabled
        }
    }

    /// A file command on an explicit file (a timeline file chip): Open,
    /// Download (to ~/Downloads), Save As…, Copy Link.
    func perform(_ c: CommandID, file row: UnifiedFileRow, _ m: WindowModel) {
        guard let app = m.app else { return }
        _ = run(c, .remote(row), arg: nil, app, m)
    }

    private func run(_ c: CommandID, _ it: FileItem, arg: String?, _ app: AppState, _ m: WindowModel) -> Bool {
        switch c {
        case FilesCommands.open:
            if it.isFolder, let row = it.row {
                // A folder drills in the store that listed it.
                if arg?.hasPrefix(Self.conversationPrefix) == true { app.shared.drill(row.file) } else { library.drill(row.file) }
            } else {
                open(it, app, m)
            }
        case FilesCommands.openWindow:
            guard let f = it.row?.file, !it.isFolder else { return false }
            FileWindowController.show(m, chatID: it.locationID ?? "", file: f)
        case FilesCommands.openInBrowser:
            if !m.options.demo, let url = it.webURL { TeamsLinkRouter.openInBrowser(url) }
        case FilesCommands.quickLook:
            quickLook(it, app, m)
        case FilesCommands.showInFinder:
            guard let path = localPath(it, app, m) else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case FilesCommands.download:
            guard let row = it.row else { return false }
            download(row, it, app, to: nil)
        case FilesCommands.saveAs:
            guard let row = it.row else { return false }
            saveAs(row, it, app, m)
        case FilesCommands.copyLink:
            guard let row = it.row else { return false }
            app.unifiedFiles.shareLink(row)
        case FilesCommands.share:
            if let row = it.row {
                app.unifiedFiles.share(row)
            } else if let path = localPath(it, app, m) {
                ShareSheet.show(items: [URL(fileURLWithPath: path)])
            }
        case FilesCommands.openConversation:
            guard let id = it.locationID else { return false }
            Self.openSource(id, name: it.location, m)
        default:
            return false
        }
        return true
    }

    func validate(_ c: CommandID, arg: String?, _ m: WindowModel) -> CommandValidation {
        guard let app = m.app else { return .disabled }
        switch c {
        case FilesCommands.transfers:
            return .enabled
        case FilesCommands.upload:
            return CommandValidation(enabled: m.nav.section != .files || Self.source(m).acceptsUpload)
        default:
            break
        }
        if Self.manageCommands.contains(c) { return validateManage(c, arg: arg, m) }
        if Self.multiCommands.contains(c) {
            let all = items(forArg: arg, m)
            if all.count > 1 { return validateMulti(c, all) }
        }
        guard let it = item(arg, m) else { return .disabled }
        let file = !it.isFolder
        switch c {
        case FilesCommands.open: return .enabled
        case FilesCommands.openWindow: return CommandValidation(enabled: file && it.row != nil)
        case FilesCommands.openInBrowser: return CommandValidation(enabled: it.webURL != nil)
        case FilesCommands.quickLook: return CommandValidation(enabled: file)
        case FilesCommands.showInFinder:
            let saved = it.row.flatMap { app.unifiedFiles.localPath(for: $0) }
            return CommandValidation(enabled: it.transfer?.path != nil || saved != nil)
        case FilesCommands.download, FilesCommands.saveAs:
            return CommandValidation(enabled: file && it.row != nil)
        case FilesCommands.copyLink: return CommandValidation(enabled: it.row?.file.drive_id != nil)
        case FilesCommands.share: return CommandValidation(enabled: file)
        case FilesCommands.openConversation:
            return CommandValidation(enabled: it.locationID != nil && arg?.hasPrefix(Self.conversationPrefix) != true)
        default: return .disabled
        }
    }

    // MARK: actions

    /// Local file for a row: a download's file, or a saved copy. Demo
    /// downloads get placeholder bytes in the demo tmp dir on demand.
    private func localPath(_ it: FileItem, _ app: AppState, _ m: WindowModel) -> String? {
        if let t = it.transfer, let path = t.path {
            if m.options.demo, !FileManager.default.fileExists(atPath: path) {
                try? "\(t.name)\nDemo download from \(t.origin).\n".write(toFile: path, atomically: true, encoding: .utf8)
            }
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        return it.row.flatMap { app.unifiedFiles.localPath(for: $0) }
    }

    private func quickLook(_ it: FileItem, _ app: AppState, _ m: WindowModel) {
        if let row = it.row {
            app.unifiedFiles.preview(row)
        } else if let path = localPath(it, app, m) {
            QuickLookPreview.shared.preview(paths: [path])
        }
    }

    /// Open: a local file in its app; a remote file downloads first
    /// (live). Demo never launches another app: it previews.
    private func open(_ it: FileItem, _ app: AppState, _ m: WindowModel) {
        if m.options.demo { return quickLook(it, app, m) }
        if let doc = Self.documentApp(it, m) {
            // An Office document in SharePoint / OneDrive: its web page,
            // read-only, in this window (R9), not a desktop app.
            m.navigator?.select(section: .web(doc.id))
            return
        }
        if let path = localPath(it, app, m) {
            TeamsLinkRouter.open(URL(fileURLWithPath: path))
        } else if let row = it.row {
            download(row, it, app, to: nil) { path in TeamsLinkRouter.open(URL(fileURLWithPath: path)) }
        }
    }

    /// The in-window pane for a stored Office document (nil: any other file).
    static func documentApp(_ it: FileItem, _ m: WindowModel) -> FrameApp? {
        guard !it.isFolder, let raw = it.row?.file.web_url, let url = URL(string: raw) else { return nil }
        return m.frameHost.library.document(name: it.name, webURL: url)
    }

    /// Download (to ~/Downloads, never overwriting: Finder-style " 2"
    /// suffix; or `dest`), listed in Transfers and Files ▸ Downloads.
    private func download(_ row: UnifiedFileRow, _ it: FileItem, _ app: AppState, to dest: String?,
                          then: ((String) -> Void)? = nil) {
        let transfers = app.transfers
        let store = app.unifiedFiles
        let id = transfers.begin(FileTransfer(name: row.file.name, direction: .download, origin: it.location,
                                              originID: it.locationID, size: row.file.size))
        let done: (UnifiedFileRow) -> Void = { [weak store, weak transfers] r in
            guard let path = store?.localPath(for: r) else {
                transfers?.fail(id, message: "The file couldn\u{2019}t be saved.")
                return
            }
            transfers?.finish(id, path: path)
            then?(path)
        }
        let target = dest ?? ImageSave.uniqueDestination(dir: TeamsFrameDownloads.defaultDirectory(),
                                                         name: TeamsFrameDownloads.sanitizedFilename(row.file.name)) {
            FileManager.default.fileExists(atPath: $0)
        }.path
        store.saveAs(row, to: target, after: done)
    }

    private func saveAs(_ row: UnifiedFileRow, _ it: FileItem, _ app: AppState, _ m: WindowModel) {
        guard let window = Self.window(m) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = row.file.name
        panel.directoryURL = TeamsFrameDownloads.defaultDirectory()
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.download(row, it, app, to: url.path)
        }
    }

    /// Upload…: open panel, then the selected source's upload target.
    private func chooseUpload(_ m: WindowModel) {
        guard let window = Self.window(m) else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Upload"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK else { return }
            let paths = panel.urls.map(\.path)
            self?.upload(paths: paths, m)
        }
    }

    /// Upload (panel or drop) to the selected source: a channel library
    /// uploads there; other sources upload to the Files index target.
    func upload(paths: [String], _ m: WindowModel) {
        guard let app = m.app, !paths.isEmpty else { return }
        let source = Self.source(m)
        guard source.acceptsUpload else { return }
        let origin: String
        let originID: String?
        if case .channel(let id) = source {
            origin = Self.channelName(id, app.teams.teams)
            originID = id
        } else {
            origin = app.unifiedFiles.uploadTarget?.name ?? "OneDrive"
            originID = app.unifiedFiles.uploadTarget?.id
        }
        let ids = paths.map { p in
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64) ?? 0
            return app.transfers.begin(FileTransfer(name: (p as NSString).lastPathComponent, direction: .upload,
                                                    origin: origin, originID: originID, path: p, size: size))
        }
        let transfers = app.transfers
        let finish: (Bool, String?) -> Void = { [weak transfers] uploading, error in
            guard !uploading else { return }
            for id in ids {
                if let error { transfers?.fail(id, message: error) } else { transfers?.finish(id) }
            }
        }
        if case .channel = source {
            library.upload(paths: paths)
            if !library.uploading { finish(false, library.uploadError) } else {
                uploadWatch = library.$uploading.dropFirst().filter { !$0 }.first()
                    .sink { [weak library] _ in finish(false, library?.uploadError) }
            }
        } else {
            let store = app.unifiedFiles
            store.upload(paths: paths)
            if !store.uploading { finish(false, store.uploadError) } else {
                uploadWatch = store.$uploading.dropFirst().filter { !$0 }.first()
                    .sink { [weak store] _ in finish(false, store?.uploadError) }
            }
        }
    }

    // MARK: transfers popover

    func showTransfers(_ m: WindowModel) {
        guard let app = m.app else { return }
        if m.nav.section != .files { m.navigator?.select(section: .files) }
        guard let window = Self.window(m) else { return }
        let item = window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == FilesCommands.transfers.rawValue && !$0.isHidden
        }
        transfersPopover.toggle(transfers: app.transfers, model: m, item: item, window: window)
    }

    // MARK: source conversation

    /// Where a conversation id opens: a channel in Teams (its team from
    /// the joined list), else the chat.
    static func sourceTarget(_ id: String, teams: [TeamItem]) -> (SectionID, SectionSelection) {
        if let team = teams.first(where: { $0.channels.contains { $0.channelId == id } }) {
            return (.teams, TeamsSelection(teamID: team.teamId, channelID: id).selection)
        }
        return (.chat, SectionSelection(id: id))
    }

    static func openSource(_ id: String, name: String?, _ m: WindowModel) {
        guard let nav = m.navigator else { return }
        let (s, sel) = sourceTarget(id, teams: m.app?.teams.teams ?? [])
        if s == .chat { m.graph.openChat(id: id, name: name) }
        nav.select(sel, in: s)
        nav.select(section: s)
    }

    static func window(_ m: WindowModel) -> NSWindow? {
        (m.navigator?.host as? ShellWindowController)?.window
    }
}
