// UnifiedFilesStore.swift — P3 split: verbatim move from UnifiedFiles.swift (API frozen).
import Foundation
import Combine

@MainActor
public final class UnifiedFilesStore: ObservableObject {
    public typealias ListFetcher = SharedFilesStore.ListFetcher
    public typealias RecentsFetcher = @Sendable (Int32) throws -> DriveRecentsResponse
    public typealias UploadFetcher = SharedFilesStore.UploadFetcher
    public typealias DownloadFetcher = SharedFilesStore.DownloadFetcher
    public typealias LinkFetcher = SharedFilesStore.LinkFetcher
    public typealias RenameFetcher = SharedFilesStore.RenameFetcher
    public typealias MoveFetcher = SharedFilesStore.MoveFetcher
    public typealias CopyFetcher = SharedFilesStore.CopyFetcher
    public typealias DeleteFetcher = SharedFilesStore.DeleteFetcher
    public typealias OpenURLFn = SharedFilesStore.OpenURLFn
    public typealias CopyLinkFn = SharedFilesStore.CopyLinkFn
    public typealias SizeProbe = ComposeAttachmentsStore.SizeProbe
    /// QuickLook entry (save-first: always a local path). Tests inject
    /// a capturing closure; default opens the QL panel (no-op in XCTest).
    public typealias PreviewFn = @Sendable (String) -> Void
    /// Share-sheet entry (save-first: always local file URLs + fallback
    /// web URLs). Same seam as PreviewFn.
    public typealias ShareFn = @Sendable ([Any]) -> Void

    /// Live fan-out caps: the 10 most recent chats + 20 channels keep
    /// the merge to ~31 core calls (each chat leg is 1 + N shares
    /// resolves; channels are 1 + team scan).
    public nonisolated static let maxChats = 10
    public nonisolated static let maxChannels = 20

    @Published public private(set) var rows: [UnifiedFileRow] = []
    @Published public private(set) var state: SharedFilesState = .loading
    @Published public private(set) var uploading = false
    @Published public private(set) var uploadProgress: Double?
    @Published public private(set) var savingIDs: Set<String> = []
    @Published public private(set) var linkingIDs: Set<String> = []
    /// Rows with a rename/move/copy/delete in flight (by row key).
    @Published public private(set) var managingIDs: Set<String> = []
    @Published public private(set) var links: [String: String] = [:]
    /// Saved local copies by row key (Save-first flow: QL + share read here).
    @Published public private(set) var savedPaths: [String: String] = [:]
    @Published public private(set) var gatedUploads: [String] = []
    @Published public private(set) var uploadError: String?
    @Published public var sort: SharedFilesSort = .date
    @Published public var filter: SharedFilesTypeFilter = .all
    @Published public var sourceFilter: UnifiedFileSourceFilter = .all
    public private(set) var specs: [UnifiedSourceSpec] = []
    public private(set) var isDemo = false

    private let listFetcher: ListFetcher
    private let recentsFetcher: RecentsFetcher
    private let uploadFetcher: UploadFetcher
    private let downloadFetcher: DownloadFetcher
    private let linkFetcher: LinkFetcher
    private let renameFetcher: RenameFetcher
    private let moveFetcher: MoveFetcher
    private let copyFetcher: CopyFetcher
    private let deleteFetcher: DeleteFetcher
    private let openURLFn: OpenURLFn
    private let copyLinkFn: CopyLinkFn
    private let sizeProbe: SizeProbe
    private let previewFn: PreviewFn
    private let shareFn: ShareFn
    private var loadGeneration = 0
    /// Rows awaiting QL/share after their save lands (save-then-act).
    private var pendingPreview: Set<String> = []
    private var pendingShare: Set<String> = []

    /// Default QuickLook entry. No-op under XCTest (never opens the
    /// panel in tests); the Task hop keeps the closure nonisolated-safe.
    public nonisolated static let defaultPreview: PreviewFn = { path in
        if NSClassFromString("XCTestCase") != nil { return }
        Task { @MainActor in QuickLookPreview.shared.preview(paths: [path]) }
    }

    /// Default share-sheet entry. No-op under XCTest (never touches
    /// the service picker in tests).
    public nonisolated static let defaultShare: ShareFn = { items in
        if NSClassFromString("XCTestCase") != nil { return }
        Task { @MainActor in ShareSheet.show(items: items) }
    }

    public nonisolated init(
        list: @escaping ListFetcher = {
            try RustCore.sharedFiles(chatID: $0, limit: $1, includeFolders: true)
        },
        recents: @escaping RecentsFetcher = { try RustCore.driveRecents(limit: $0) },
        upload: @escaping UploadFetcher = { try RustCore.sharedUpload(chatID: $0, path: $1) },
        download: @escaping DownloadFetcher = {
            try RustCore.sharedDownload(driveID: $0, itemID: $1, dest: $2)
        },
        link: @escaping LinkFetcher = {
            try RustCore.sharedLink(driveID: $0, itemID: $1, scope: $2)
        },
        rename: @escaping RenameFetcher = {
            try RustCore.sharedRename(driveID: $0, itemID: $1, newName: $2)
        },
        move: @escaping MoveFetcher = {
            try RustCore.sharedMove(driveID: $0, itemID: $1, destFolderID: $2)
        },
        copy: @escaping CopyFetcher = {
            try RustCore.sharedCopy(driveID: $0, itemID: $1, destFolderID: $2, newName: $3)
        },
        delete: @escaping DeleteFetcher = {
            try RustCore.sharedDelete(driveID: $0, itemID: $1)
        },
        openURL: @escaping OpenURLFn = SharedFilesStore.defaultOpenURL,
        copyLink: @escaping CopyLinkFn = SharedFilesStore.defaultCopyLink,
        sizeProbe: @escaping SizeProbe = ComposeAttachmentsStore.defaultSizeProbe,
        preview: @escaping PreviewFn = UnifiedFilesStore.defaultPreview,
        share: @escaping ShareFn = UnifiedFilesStore.defaultShare
    ) {
        self.listFetcher = list
        self.recentsFetcher = recents
        self.uploadFetcher = upload
        self.downloadFetcher = download
        self.linkFetcher = link
        self.renameFetcher = rename
        self.moveFetcher = move
        self.copyFetcher = copy
        self.deleteFetcher = delete
        self.openURLFn = openURL
        self.copyLinkFn = copyLink
        self.sizeProbe = sizeProbe
        self.previewFn = preview
        self.shareFn = share
    }

    // MARK: - Pure merge/specs/display

    /// Live specs from the loaded lists: the `maxChats` most recent
    /// chats (list order is recency) + flattened team channels capped at
    /// `maxChannels`. Channel rows read "Team > #channel".
    public static func specsFor(
        chats: [ChatItem], teams: [TeamItem],
        chatCap: Int = maxChats, channelCap: Int = maxChannels
    ) -> [UnifiedSourceSpec] {
        var out: [UnifiedSourceSpec] = chats.prefix(max(0, chatCap)).map {
            UnifiedSourceSpec(kind: .chat, id: $0.chatId, name: $0.name)
        }
        var channels = 0
        for team in teams {
            for channel in team.channels {
                guard channels < max(0, channelCap) else { break }
                out.append(UnifiedSourceSpec(
                    kind: .channel, id: channel.channelId,
                    name: "\(team.name) > #\(channel.name)"))
                channels += 1
            }
            if channels >= max(0, channelCap) { break }
        }
        return out
    }

    /// Pure merge: tag every leg file with its source, dedupe by row key
    /// (conversation legs win over the drive leg: pass drive files last).
    /// Order preserved (first-wins); callers sort via `displayed`.
    public static func merge(
        legs: [(source: UnifiedFileSource, sourceName: String, files: [SharedFile])]
    ) -> [UnifiedFileRow] {
        var seen = Set<String>()
        var out: [UnifiedFileRow] = []
        for leg in legs {
            for file in leg.files {
                let key = UnifiedFileRow.key(for: file)
                guard seen.insert(key).inserted else { continue }
                out.append(UnifiedFileRow(
                    file: file, source: leg.source, sourceName: leg.sourceName))
            }
        }
        return out
    }

    /// Pure source-filter (`.all` passes everything through untouched).
    public static func sourceFiltered(
        _ list: [UnifiedFileRow], by filter: UnifiedFileSourceFilter
    ) -> [UnifiedFileRow] {
        filter == .all ? list : list.filter { filter.matches($0) }
    }

    /// Pure filter-then-sort (backs `displayedRows`). Reuses the
    /// Shared-tab type filter + sort on the wrapped files; the row
    /// order follows the sorted files (keys are unique post-merge).
    public static func displayed(
        _ list: [UnifiedFileRow], sort: SharedFilesSort,
        filter: SharedFilesTypeFilter, sourceFilter: UnifiedFileSourceFilter
    ) -> [UnifiedFileRow] {
        let scoped = sourceFiltered(list, by: sourceFilter)
        let files = SharedFilesStore.displayed(
            scoped.map(\.file), sort: sort, filter: filter)
        let byKey = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })
        return files.compactMap { byKey[UnifiedFileRow.key(for: $0)] }
    }

    /// "2026-09-25T10:00:00Z" → "Sep 25, 2026" (nil when dateless).
    public static func dateLabel(_ file: SharedFile) -> String? {
        guard let date = SharedFilesStore.dateValue(file) else { return nil }
        return Self.shortDate.string(from: date)
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Share payload for one row: the saved local file URL when a copy
    /// exists (service picker uploads/shares bytes), else the SharePoint
    /// web URL (link share). Nil when neither exists.
    public static func shareItems(for row: UnifiedFileRow, savedPath: String?) -> [Any] {
        if let path = savedPath, QuickLookPreview.canPreview(path: path) {
            return [URL(fileURLWithPath: path)]
        }
        if let s = row.file.web_url, let url = URL(string: s) {
            return [url]
        }
        return []
    }

    /// Demo placeholder content for a fabricated save (offline: real
    /// bytes so QuickLook + share work in demo with zero network).
    public static func demoFileContent(for file: SharedFile) -> String {
        "\(file.name)\nDemo copy — \(file.sizeLabel) in the shared library.\n"
    }

    /// Demo save destination: a tmp subdir, never ~/Downloads (demo
    /// fabrications must not litter the owner's real folders). Pure.
    public static func demoSaveDestination(filename: String) -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("UnifiedFilesDemo")
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent(filename)
    }

    /// Core-call failure message (nonisolated: TaskGroup legs call it
    /// off the main actor). Same shape as SharedFilesStore.message.
    nonisolated static func message(for error: Error) -> String {
        FriendlyError.message(for: error)
    }

    // MARK: - Load

    /// Rows after the source + type filters + sort (what the list renders).
    public var displayedRows: [UnifiedFileRow] {
        Self.displayed(rows, sort: sort, filter: filter, sourceFilter: sourceFilter)
    }

    /// Upload target: the first chat leg, else the first channel leg
    /// (drive recents are read-only — nowhere to post a reference).
    /// Nil with no conversation legs (upload disabled).
    public var uploadTarget: UnifiedSourceSpec? {
        specs.first { $0.kind == .chat } ?? specs.first { $0.kind == .channel }
    }

    /// Existing saved copy for one row (Save-first flow reads here).
    /// Drops stale entries (user deleted the file behind us).
    public func localPath(for row: UnifiedFileRow) -> String? {
        guard let path = savedPaths[row.id],
              QuickLookPreview.canPreview(path: path)
        else { return nil }
        return path
    }

    /// Load the merged view: every spec's shared list + drive recents,
    /// fanned out concurrently. Partial legs still merge (one chat's
    /// 404 never blanks the surface); all-legs-failed surfaces the
    /// first error. Stale completions are dropped (fast refresh lands
    /// newest). Demo mode stays offline (see `showDemo`).
    public func load(
        chats: [(id: String, name: String)],
        channels: [(id: String, name: String)],
        limitPerSource: Int32 = 10, recentsLimit: Int32 = 25
    ) {
        let next = chats.map {
            UnifiedSourceSpec(kind: .chat, id: $0.id, name: $0.name)
        } + channels.map {
            UnifiedSourceSpec(kind: .channel, id: $0.id, name: $0.name)
        }
        specs = next
        isDemo = false
        loadGeneration += 1
        let gen = loadGeneration
        state = .loading
        let list = listFetcher
        let recents = recentsFetcher
        // R12: a source that fails this refresh keeps the rows it had.
        let previous = rows
        Task {
            var legs: [(source: UnifiedFileSource, sourceName: String, files: [SharedFile])] =
                Array(repeating: (source: .chat, sourceName: "", files: []), count: next.count + 1)
            var landed = 0
            var firstError: String?
            await withTaskGroup(of: (Int, [SharedFile]?, String?).self) { group in
                for (i, spec) in next.enumerated() {
                    group.addTask {
                        do {
                            let resp = try await Task.detached {
                                try list(spec.id, limitPerSource)
                            }.value
                            return (i, resp.files, nil)
                        } catch {
                            return (i, nil, Self.message(for: error))
                        }
                    }
                }
                group.addTask {
                    do {
                        let resp = try await Task.detached {
                            try recents(recentsLimit)
                        }.value
                        return (next.count, resp.files, nil)
                    } catch {
                        return (next.count, nil, Self.message(for: error))
                    }
                }
                for await (i, files, err) in group {
                    if let files {
                        landed += 1
                        if i < next.count {
                            let spec = next[i]
                            legs[i] = (spec.kind, spec.name,
                                       files.map { $0.withSource(name: spec.name, id: spec.id) })
                        } else {
                            legs[i] = (.drive, UnifiedFileSource.drive.label, files)
                        }
                    } else {
                        if firstError == nil { firstError = err }
                        let kept = i < next.count
                            ? previous.filter { $0.source == next[i].kind && $0.sourceID == next[i].id }
                            : previous.filter { $0.source == .drive }
                        if !kept.isEmpty {
                            legs[i] = i < next.count
                                ? (next[i].kind, next[i].name, kept.map(\.file))
                                : (.drive, UnifiedFileSource.drive.label, kept.map(\.file))
                        }
                    }
                }
            }
            guard gen == loadGeneration else { return }
            let merged = Self.merge(legs: legs.filter {
                !($0.sourceName.isEmpty && $0.files.isEmpty)
            })
            rows = merged
            if landed > 0, !merged.isEmpty {
                snapshots?.save(Snapshot(
                    specs: next,
                    rows: merged.prefix(Self.snapshotRows).map {
                        UnifiedFileRow(file: $0.file.withoutDownloadURL, source: $0.source,
                                       sourceName: $0.sourceName)
                    }), key: Self.snapshotKey)
            }
            if landed == 0, let err = firstError {
                // Every source failed: rows kept above stay on screen
                // (R12), the error only shows as the quiet refresh notice.
                state = .error(err)
            } else if !merged.isEmpty {
                state = .loaded
            } else {
                state = .empty
            }
        }
    }

    /// NOLOAD: last-good snapshot store (nil = memory only / demo).
    public var snapshots: SectionCache?
    static let snapshotKey = "files"
    /// Rows kept on disk (newest first after merge).
    static let snapshotRows = 300

    struct Snapshot: Codable {
        let specs: [UnifiedSourceSpec]
        let rows: [UnifiedFileRow]
    }

    /// Paint the last good merged list before any fetch (Retry /
    /// refresh reuse the cached specs until the live ones land).
    @discardableResult
    public func restoreSnapshot() -> Bool {
        guard rows.isEmpty, let snap = snapshots?.load(Snapshot.self, key: Self.snapshotKey),
              !snap.rows.isEmpty else { return false }
        if specs.isEmpty { specs = snap.specs }
        rows = snap.rows
        state = .loaded
        return true
    }

    /// Demo mode: canned rows offline (no core). Resets specs to the
    /// demo conversations.
    public func showDemo(specs: [UnifiedSourceSpec], rows: [UnifiedFileRow]) {
        self.specs = specs
        self.rows = rows
        isDemo = true
        state = rows.isEmpty ? .empty : .loaded
    }

    /// Stamp the conversation a file was shared in (core-b) from the
    /// loaded rows: same drive-scoped key, chat/channel legs only. Files
    /// that already name a source, or that the index lacks, pass through.
    public func resolveSource(_ file: SharedFile) -> SharedFile {
        Self.resolveSource(file, rows: rows)
    }

    /// Pure form of `resolveSource(_:)`.
    public nonisolated static func resolveSource(_ file: SharedFile, rows: [UnifiedFileRow]) -> SharedFile {
        guard file.source_name == nil else { return file }
        let key = UnifiedFileRow.key(for: file)
        guard let hit = rows.first(where: { $0.id == key && $0.source != .drive }),
              let name = hit.file.source_name
        else { return file }
        return file.withSource(name: name, id: hit.file.source_id)
    }

    /// Fire-and-forget reload with the current specs.
    public func refresh(limitPerSource: Int32 = 10, recentsLimit: Int32 = 25) {
        guard !isDemo else { return }
        load(
            chats: specs.filter { $0.kind == .chat }.map { ($0.id, $0.name) },
            channels: specs.filter { $0.kind == .channel }.map { ($0.id, $0.name) },
            limitPerSource: limitPerSource, recentsLimit: recentsLimit)
    }

    // MARK: - Row actions (Save-first: download → preview/share)

    /// Open the SharePoint page in the browser. No-op without a web_url.
    /// Returns the URL opened, if any (test seam).
    @discardableResult
    public func open(_ row: UnifiedFileRow) -> URL? {
        guard let s = row.file.web_url, let url = URL(string: s) else { return nil }
        _ = openURLFn(url)
        return url
    }

    /// Quick save to ~/Downloads/<name>, then run `after` (preview/share
    /// continuations). The view prefers `saveAs` (Save panel defaulting
    /// there). Demo mode fabricates a placeholder file offline.
    public func save(_ row: UnifiedFileRow, after: ((UnifiedFileRow) -> Void)? = nil) {
        saveAs(row, to: SharedFilesStore.downloadDestination(filename: row.file.name), after: after)
    }

    /// Save to an explicit destination (the Save panel's pick). Needs
    /// drive_id; without it falls back to opening the pre-signed
    /// download_url in the browser (dest unused, no continuation).
    public func saveAs(
        _ row: UnifiedFileRow, to dest: String,
        after: ((UnifiedFileRow) -> Void)? = nil
    ) {
        if isDemo {
            // Fabricated bytes land in tmp (never ~/Downloads); the
            // passed dest is ignored so demo previews stay hermetic.
            let demoDest = Self.demoSaveDestination(filename: row.file.name)
            let content = Self.demoFileContent(for: row.file)
            try? content.write(toFile: demoDest, atomically: true, encoding: .utf8)
            if QuickLookPreview.canPreview(path: demoDest) {
                savedPaths[row.id] = demoDest
            }
            after?(row)
            return
        }
        guard let drive = row.file.drive_id else {
            if let s = row.file.download_url, let url = URL(string: s) {
                _ = openURLFn(url)
            }
            return
        }
        guard !savingIDs.contains(row.id) else { return }
        savingIDs.insert(row.id)
        let fetcher = downloadFetcher
        let file = row.file
        Task {
            defer { savingIDs.remove(row.id) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, file.id, dest)
                }.value
                savedPaths[row.id] = resp.path
                after?(row)
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// QuickLook preview, save-first: an existing local copy opens at
    /// once; otherwise the row saves to ~/Downloads and the panel opens
    /// when the bytes land. Remote-only rows (no drive_id) open in the
    /// browser instead (no bytes, no panel).
    public func preview(_ row: UnifiedFileRow) {
        if let local = localPath(for: row) {
            previewFn(local)
            return
        }
        guard row.file.drive_id != nil || isDemo else {
            save(row) // browser fallback for the pre-signed URL
            return
        }
        pendingPreview.insert(row.id)
        save(row) { [weak self] done in
            guard let self, pendingPreview.remove(done.id) != nil else { return }
            if let local = localPath(for: done) { previewFn(local) }
        }
    }

    /// Share sheet, save-first: an existing local copy shares bytes
    /// (upload-capable services); otherwise the row saves first and the
    /// picker opens when the bytes land. With no local copy and no
    /// web_url there is nothing to share (guarded no-op).
    public func share(_ row: UnifiedFileRow) {
        let items = Self.shareItems(for: row, savedPath: localPath(for: row))
        if !items.isEmpty, localPath(for: row) != nil || row.file.drive_id == nil {
            shareFn(items)
            return
        }
        guard row.file.drive_id != nil || isDemo else { return }
        pendingShare.insert(row.id)
        save(row) { [weak self] done in
            guard let self, pendingShare.remove(done.id) != nil else { return }
            let items = Self.shareItems(for: done, savedPath: localPath(for: done))
            if !items.isEmpty { shareFn(items) }
        }
    }

    /// Cached sharing link for one row (createLink result, or the row's
    /// own share_url when core filled it). Nil until linked.
    public func link(for row: UnifiedFileRow) -> String? {
        links[row.id] ?? row.file.share_url
    }

    /// Create a view-only sharing link via core and copy it to the
    /// pasteboard. Cached links re-copy without refetching. No-op
    /// without a drive_id; demo mode fabricates a stable link.
    public func shareLink(_ row: UnifiedFileRow, scope: String = "organization") {
        if let cached = link(for: row) {
            copyLinkFn(cached)
            return
        }
        guard let drive = row.file.drive_id else { return }
        if isDemo {
            let demo = SharedFileLink.demoLink(for: row.file.id)
            links[row.id] = demo
            copyLinkFn(demo)
            return
        }
        guard !linkingIDs.contains(row.id) else { return }
        linkingIDs.insert(row.id)
        let fetcher = linkFetcher
        let file = row.file
        Task {
            defer { linkingIDs.remove(row.id) }
            do {
                let resp = try await Task.detached {
                    try fetcher(drive, file.id, scope)
                }.value
                links[row.id] = resp.link
                copyLinkFn(resp.link)
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Copy Link for several rows (Files multi-select): one pasteboard
    /// write, the links in row order joined by newlines. Cached (and
    /// demo) links are reused; the rest are created one after another.
    /// A row whose link fails is left out and the failure shows as for a
    /// single Copy Link. Rows without a drive_id are skipped; one row
    /// goes through `shareLink`.
    public func shareLinks(_ rows: [UnifiedFileRow], scope: String = "organization") {
        let rows = rows.filter { $0.file.drive_id != nil }
        guard rows.count > 1 else {
            if let row = rows.first { shareLink(row, scope: scope) }
            return
        }
        var known: [String: String] = [:]
        var missing: [UnifiedFileRow] = []
        for row in rows {
            if let cached = link(for: row) {
                known[row.id] = cached
            } else if isDemo {
                let demo = SharedFileLink.demoLink(for: row.file.id)
                links[row.id] = demo
                known[row.id] = demo
            } else if !linkingIDs.contains(row.id) {
                missing.append(row)
            }
        }
        guard !missing.isEmpty else {
            copyLinkFn(rows.compactMap { known[$0.id] }.joined(separator: "\n"))
            return
        }
        for row in missing { linkingIDs.insert(row.id) }
        let fetcher = linkFetcher
        let found = known
        Task {
            var out = found
            var failure: Error?
            for row in missing {
                let file = row.file
                guard let drive = file.drive_id else { continue }
                do {
                    let resp = try await Task.detached { try fetcher(drive, file.id, scope) }.value
                    links[row.id] = resp.link
                    out[row.id] = resp.link
                } catch {
                    failure = error
                }
                linkingIDs.remove(row.id)
            }
            let text = rows.compactMap { out[$0.id] }.joined(separator: "\n")
            if !text.isEmpty { copyLinkFn(text) }
            if let failure { state = .error(Self.message(for: failure)) }
        }
    }

    // MARK: - Upload (targets the first conversation leg)

    /// Multi-upload to the upload target (panel + drops): over-cap
    /// files pre-gate into `gatedUploads`/`uploadError` (the fetcher
    /// never runs for them); the rest upload one at a time and upsert
    /// into the merged rows tagged with the target leg. No-op without
    /// a target. Demo mode fabricates each row locally.
    public func upload(paths: [String]) {
        guard !paths.isEmpty, let target = uploadTarget else { return }
        var ok: [String] = []
        var gated: [(path: String, size: UInt64)] = []
        for path in paths {
            let size = sizeProbe(path) ?? 0
            if ComposeAttachments.isTooLarge(size: size) {
                gated.append((path, size))
            } else {
                ok.append(path)
            }
        }
        gatedUploads = gated.map(\.path)
        if let first = gated.first {
            var msg = ComposeAttachments.capMessage(actual: first.size)
            if gated.count > 1 { msg += " (+\(gated.count - 1) more)" }
            uploadError = msg
        } else {
            uploadError = nil
        }
        guard !ok.isEmpty else { return }
        if isDemo {
            for path in ok {
                let name = (path as NSString).lastPathComponent
                rows.insert(
                    UnifiedFileRow(
                        file: SharedFile(id: "demo-up-\(rows.count + 1)", name: name, size: 1024),
                        source: target.kind, sourceName: target.name,
                        sourceID: target.id),
                    at: 0)
            }
            state = .loaded
            return
        }
        uploading = true
        uploadProgress = nil
        let fetcher = uploadFetcher
        Task {
            defer {
                uploading = false
                uploadProgress = nil
            }
            for path in ok {
                do {
                    let resp = try await Task.detached {
                        try fetcher(target.id, path)
                    }.value
                    rows = Self.upsert(
                        UnifiedFileRow(
                            file: resp.file, source: target.kind,
                            sourceName: target.name, sourceID: target.id),
                        into: rows)
                    state = .loaded
                } catch {
                    state = .error(Self.message(for: error))
                }
            }
        }
    }

    // MARK: - Rename / move / copy / delete (drive items)

    /// Rename via core PATCH; the row keeps its leg. Demo renames the
    /// row in memory. No-op without a drive_id or when blank/unchanged.
    public func rename(_ row: UnifiedFileRow, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != row.file.name, !managingIDs.contains(row.id) else { return }
        if isDemo {
            let files = SharedFilesStore.renamed(row.file.id, to: name, in: [row.file])
            if let f = files.first { rows = Self.replacing(row, with: f, in: rows) }
            return
        }
        guard let drive = row.file.drive_id else { return }
        manage(row) { [renameFetcher] in
            try renameFetcher(drive, row.file.id, name).file
        }
    }

    /// Move into a folder on the same drive via core PATCH. The index is
    /// flat (recents + conversation legs), so the row stays listed. Demo
    /// updates the row in memory: modified now, and a drive-leg row's
    /// Location becomes `folderName`.
    public func move(_ row: UnifiedFileRow, toFolder destFolderID: String, folderName: String? = nil) {
        let folder = destFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, !managingIDs.contains(row.id) else { return }
        if isDemo {
            let file = SharedFilesStore.demoVariant(of: row.file, id: row.file.id, name: row.file.name,
                                                    modified: SharedFilesStore.nowStamp(), keepSource: true)
            rows = rows.map { r in
                guard r.id == row.id else { return r }
                let place = r.source == .drive ? (folderName ?? r.sourceName) : r.sourceName
                return UnifiedFileRow(file: file, source: r.source, sourceName: place, sourceID: r.sourceID)
            }
            return
        }
        guard let drive = row.file.drive_id else { return }
        manage(row) { [moveFetcher] in
            try moveFetcher(drive, row.file.id, folder).file
        }
    }

    /// Copy into a folder on the same drive (server-side, async). The
    /// copy lands outside the index until the next refresh. Demo adds
    /// the copy in memory: "Name copy.ext", modified now, on the drive
    /// leg with Location `folderName`.
    public func copy(_ row: UnifiedFileRow, toFolder destFolderID: String, folderName: String? = nil) {
        let folder = destFolderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, !managingIDs.contains(row.id) else { return }
        if isDemo {
            let name = SharedFilesStore.copyName(row.file.name, isFolder: row.file.isFolder,
                                                 taken: Set(rows.map(\.file.name)))
            let id = SharedFilesStore.copyID(row.file.id, taken: Set(rows.map(\.file.id)))
            let file = SharedFilesStore.demoVariant(of: row.file, id: id, name: name,
                                                    modified: SharedFilesStore.nowStamp(), keepSource: false)
            rows = Self.upsert(UnifiedFileRow(file: file, source: .drive, sourceName: folderName ?? "OneDrive"),
                               into: rows)
            state = .loaded
            return
        }
        guard let drive = row.file.drive_id else { return }
        manage(row) { [copyFetcher] in
            _ = try copyFetcher(drive, row.file.id, folder, nil)
            return nil
        }
    }

    /// Delete via core DELETE. Demo (or a row without a drive item)
    /// drops the row in memory.
    public func delete(_ row: UnifiedFileRow) {
        guard !managingIDs.contains(row.id) else { return }
        guard let drive = row.file.drive_id, !isDemo else {
            rows.removeAll { $0.id == row.id }
            if rows.isEmpty { state = .empty }
            return
        }
        let fetcher = deleteFetcher
        managingIDs.insert(row.id)
        Task {
            defer { managingIDs.remove(row.id) }
            do {
                _ = try await Task.detached { try fetcher(drive, row.file.id) }.value
                rows.removeAll { $0.id == row.id }
                if rows.isEmpty { state = .empty }
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// One core manage call off-main; a returned file replaces the row
    /// in place (same leg), nil leaves the rows untouched.
    private func manage(_ row: UnifiedFileRow, _ call: @escaping @Sendable () throws -> SharedFile?) {
        managingIDs.insert(row.id)
        Task {
            defer { managingIDs.remove(row.id) }
            do {
                if let f = try await Task.detached(operation: call).value {
                    rows = Self.replacing(row, with: f, in: rows)
                }
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Pure: `row` replaced in place by `file` on the same leg.
    public nonisolated static func replacing(_ row: UnifiedFileRow, with file: SharedFile,
                                             in list: [UnifiedFileRow]) -> [UnifiedFileRow] {
        list.map { r in
            guard r.id == row.id else { return r }
            return UnifiedFileRow(file: file, source: r.source, sourceName: r.sourceName, sourceID: r.sourceID)
        }
    }

    /// Dismiss the over-cap upload banner.
    public func clearUploadError() {
        uploadError = nil
        gatedUploads = []
    }

    /// Pure upsert: same key replaces in place, new key prepends.
    public static func upsert(_ row: UnifiedFileRow, into list: [UnifiedFileRow]) -> [UnifiedFileRow] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == row.id }) {
            out[i] = row
        } else {
            out.insert(row, at: 0)
        }
        return out
    }
}
