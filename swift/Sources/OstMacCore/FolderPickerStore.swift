// FolderPickerStore.swift — the Move To… / Copy To… folder browser
// (UI-SPEC §6.6): one drive, the path of folders from its root, and the
// open folder's subfolders. The root is a destination too (core resolves
// the `root` alias to the real folder id). Demo browses canned folders
// in memory; live lists children via core (off-main).
import Foundation

@MainActor
public final class FolderPickerStore: ObservableObject {
    public typealias ChildrenFetcher = SharedFilesStore.ChildrenFetcher

    /// Graph alias for a drive's root folder.
    public nonisolated static let rootID = "root"

    public let driveID: String
    /// Root first, the open folder last (never empty).
    @Published public private(set) var path: [SharedFolderCrumb]
    /// The open folder's subfolders (the items being moved excluded).
    @Published public private(set) var folders: [SharedFolderCrumb] = []
    @Published public private(set) var state: SharedFilesState = .loading

    private let excluded: Set<String>
    private let isDemo: Bool
    private let fetcher: ChildrenFetcher
    private var generation = 0

    public init(
        driveID: String, rootName: String, excluding: Set<String> = [], demo: Bool,
        children: @escaping ChildrenFetcher = {
            try RustCore.sharedChildren(driveID: $0, itemID: $1, limit: $2)
        }
    ) {
        self.driveID = driveID
        self.excluded = excluding
        self.isDemo = demo
        self.fetcher = children
        path = [SharedFolderCrumb(driveID: driveID, itemID: Self.rootID, name: rootName)]
        load()
    }

    /// The open folder (the root at first).
    public var current: SharedFolderCrumb { path[path.count - 1] }

    /// Open a subfolder of the current folder.
    public func enter(_ folder: SharedFolderCrumb) {
        path.append(folder)
        load()
    }

    /// Back to the folder at `index` in `path` (0 = root).
    public func goTo(index: Int) {
        guard index >= 0, index < path.count - 1 else { return }
        path.removeSubrange((index + 1)...)
        load()
    }

    private func load() {
        generation += 1
        let gen = generation
        let parent = current.itemID
        folders = []
        if isDemo {
            finish(DemoData.fileFolders(driveID: driveID, parentID: parent))
            return
        }
        state = .loading
        let drive = driveID
        let fetch = fetcher
        Task {
            do {
                let resp = try await Task.detached { try fetch(drive, parent, 200) }.value
                guard gen == generation else { return }
                finish(resp.files.filter(\.isFolder).map {
                    SharedFolderCrumb(driveID: drive, itemID: $0.id, name: $0.name)
                })
            } catch {
                guard gen == generation else { return }
                state = .error(SharedFilesStore.message(for: error))
            }
        }
    }

    private func finish(_ list: [SharedFolderCrumb]) {
        folders = list.filter { !excluded.contains($0.itemID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        state = folders.isEmpty ? .empty : .loaded
    }
}
