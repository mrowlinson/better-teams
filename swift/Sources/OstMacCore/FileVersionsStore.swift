// FileVersionsStore.swift — P3 split: verbatim move from FileVersionsView.swift (API frozen).
import Foundation
import Combine

@MainActor
public final class FileVersionsStore: ObservableObject {
    public typealias ListFetcher = @Sendable (String, String) throws -> FileVersionsResponse
    public typealias RestoreFetcher = @Sendable (String, String, String) throws -> FileVersionRestoreResponse
    public typealias DownloadFetcher = @Sendable (String, String, String, String) throws -> SharedFileDownloadResponse

    @Published public private(set) var versions: [FileVersion] = []
    @Published public private(set) var state: FileVersionsState = .loading
    @Published public private(set) var restoringIDs: Set<String> = []
    @Published public private(set) var savingIDs: Set<String> = []
    @Published public private(set) var savedPath: String?
    @Published public private(set) var restoredID: String?
    public private(set) var driveID: String?
    public private(set) var itemID: String?
    public private(set) var filename: String?
    public private(set) var isDemo = false

    private let listFetcher: ListFetcher
    private let restoreFetcher: RestoreFetcher
    private let downloadFetcher: DownloadFetcher
    private var openGeneration = 0

    public nonisolated init(
        list: @escaping ListFetcher = { try RustCore.fileVersions(driveID: $0, itemID: $1) },
        restore: @escaping RestoreFetcher = {
            try RustCore.fileVersionRestore(driveID: $0, itemID: $1, versionID: $2)
        },
        download: @escaping DownloadFetcher = {
            try RustCore.fileVersionDownload(driveID: $0, itemID: $1, versionID: $2, dest: $3)
        }
    ) {
        self.listFetcher = list
        self.restoreFetcher = restore
        self.downloadFetcher = download
    }

    /// Open one file's history: fetch via core, replace versions.
    /// Stale completions are dropped (fast file-switching lands newest).
    public func open(driveID: String, itemID: String, filename: String) {
        self.driveID = driveID
        self.itemID = itemID
        self.filename = filename
        state = .loading
        savedPath = nil
        restoredID = nil
        openGeneration += 1
        let gen = openGeneration
        Task {
            let fetcher = listFetcher
            do {
                let resp = try await Task.detached { try fetcher(driveID, itemID) }.value
                guard gen == openGeneration else { return }
                versions = resp.versions
                state = resp.versions.isEmpty ? .empty : .loaded
            } catch {
                guard gen == openGeneration else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Fire-and-forget reload.
    public func refresh() {
        guard let d = driveID, let i = itemID, let name = filename else { return }
        open(driveID: d, itemID: i, filename: name)
    }

    /// Demo mode: canned history offline (no core).
    public func showDemo(driveID: String, itemID: String, filename: String, versions: [FileVersion]) {
        self.driveID = driveID
        self.itemID = itemID
        self.filename = filename
        self.versions = versions
        isDemo = true
        state = versions.isEmpty ? .empty : .loaded
    }

    /// Restore one version as current. Demo mode marks it locally.
    public func restore(_ version: FileVersion) {
        guard let d = driveID, let i = itemID else { return }
        if isDemo {
            restoredID = version.id
            return
        }
        guard !restoringIDs.contains(version.id) else { return }
        restoringIDs.insert(version.id)
        let fetcher = restoreFetcher
        let versionID = version.id
        Task {
            defer { restoringIDs.remove(versionID) }
            do {
                let resp = try await Task.detached {
                    try fetcher(d, i, versionID)
                }.value
                restoredID = resp.version_id ?? versionID
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Save one old version's bytes to ~/Downloads. Demo mode fabricates
    /// the path (no core, no file).
    public func save(_ version: FileVersion) {
        guard let d = driveID, let i = itemID else { return }
        let dest = Self.versionDownloadDestination(
            filename: filename ?? "file", versionID: version.id)
        if isDemo {
            savedPath = dest
            return
        }
        guard !savingIDs.contains(version.id) else { return }
        savingIDs.insert(version.id)
        let fetcher = downloadFetcher
        let versionID = version.id
        Task {
            defer { savingIDs.remove(versionID) }
            do {
                let resp = try await Task.detached {
                    try fetcher(d, i, versionID, dest)
                }.value
                savedPath = resp.path
            } catch {
                state = .error(Self.message(for: error))
            }
        }
    }

    /// ~/Downloads/<base>-v<id>.<ext> (pure, testable). The id is
    /// sanitized (no slashes) so hostile ids stay inside ~/Downloads.
    public static func versionDownloadDestination(filename: String, versionID: String) -> String {
        let safe = versionID.replacingOccurrences(of: "/", with: "_")
        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? filename : ns.deletingPathExtension
        let name = ext.isEmpty ? "\(base)-v\(safe)" : "\(base)-v\(safe).\(ext)"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Downloads/\(name)")
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
