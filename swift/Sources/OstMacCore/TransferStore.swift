// TransferStore.swift — uploads and downloads for Files ▸ Downloads and
// the Transfers popover (UI-SPEC §6.6, §7.3).
//
// One per account composition root. Frame downloads (WKDownload from a
// pinned web app), file downloads (Files, a chat's Files tab) and
// uploads report here. Finished downloads persist through the injected
// defaults (`AppState.storageDefaults`: in-memory in `--demo`, so demo
// never reads or writes a real key); running transfers are memory only.
import Foundation

/// One upload or download.
public struct FileTransfer: Identifiable, Equatable, Codable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case download, upload
    }

    public enum Status: Equatable, Codable, Sendable {
        case running
        case done
        case failed(String)
    }

    public let id: String
    public var name: String
    public var direction: Direction
    /// Where it came from or went to: a web app name ("Planner"), a
    /// conversation ("Design Sync"), or "OneDrive".
    public var origin: String
    /// Conversation id when `origin` is a chat or channel (jump target).
    public var originID: String?
    /// Local file (downloads, once written; the picked file for uploads).
    public var path: String?
    public var size: UInt64
    public var date: Date
    /// 0…1 while running; nil = indeterminate.
    public var progress: Double?
    public var status: Status
    /// Cleared from the Transfers popover (a finished download stays in
    /// Files ▸ Downloads).
    public var cleared = false

    public init(
        id: String = UUID().uuidString, name: String, direction: Direction, origin: String,
        originID: String? = nil, path: String? = nil, size: UInt64 = 0, date: Date = Date(),
        progress: Double? = nil, status: Status = .running
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.origin = origin
        self.originID = originID
        self.path = path
        self.size = size
        self.date = date
        self.progress = progress
        self.status = status
    }

    public var isRunning: Bool { status == .running }
}

@MainActor
public final class TransferStore: ObservableObject {
    /// Newest first.
    @Published public private(set) var items: [FileTransfer] = []

    private let defaults: UserDefaults?
    public nonisolated static let defaultsKey = "bt.files.downloads"
    /// Finished downloads kept (oldest dropped).
    public nonisolated static let maxKept = 200

    /// `defaults` nil = memory only (tests).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([FileTransfer].self, from: data) {
            items = saved
        }
    }

    /// Finished downloads (Files ▸ Downloads), newest first.
    public var downloads: [FileTransfer] {
        items.filter { $0.direction == .download && $0.status == .done }
    }

    /// Transfers popover rows, newest first.
    public var popoverItems: [FileTransfer] { items.filter { !$0.cleared } }

    public var hasRunning: Bool { items.contains(where: \.isRunning) }

    /// Starts a transfer; returns its id.
    @discardableResult
    public func begin(_ t: FileTransfer) -> String {
        items.insert(t, at: 0)
        return t.id
    }

    public func update(_ id: String, progress: Double?) {
        mutate(id) { $0.progress = progress.map { min(1, max(0, $0)) } }
    }

    public func finish(_ id: String, path: String? = nil, size: UInt64? = nil) {
        mutate(id) {
            $0.status = .done
            $0.progress = 1
            if let path { $0.path = path }
            if let size { $0.size = size }
        }
        persist()
    }

    public func fail(_ id: String, message: String) {
        mutate(id) { $0.status = .failed(message) }
    }

    /// Clear: finished and failed transfers leave the popover; finished
    /// downloads stay listed in Files ▸ Downloads.
    public func clearFinished() {
        items.removeAll { !$0.isRunning && !($0.direction == .download && $0.status == .done) }
        for i in items.indices where !items[i].isRunning { items[i].cleared = true }
        persist()
    }

    /// Demo: canned transfers (in memory; the store's defaults are the
    /// demo's `MemoryDefaults`).
    public func seedDemo(_ items: [FileTransfer]) {
        self.items = items
    }

    private func mutate(_ id: String, _ f: (inout FileTransfer) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        f(&items[i])
    }

    private func persist() {
        guard let defaults else { return }
        let kept = Array(downloads.prefix(Self.maxKept))
        if let data = try? JSONEncoder().encode(kept) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
