// FilesModel.swift — Files section values (UI-SPEC §6.6): the fixed
// source list, the table row, pane states and the one date format.
import AppKit
import Foundation
import OstMacCore
import UniformTypeIdentifiers

/// A list-pane source. Selection path: `[key] + selected file ids`.
enum FilesSource: Hashable {
    case recent
    /// My Files (OneDrive): the drive-recents leg.
    case myFiles
    /// Shared in Chats: the chat legs.
    case shared
    /// Teams › team › channel library.
    case channel(String)
    /// Downloads (Files downloads, chat attachments, frame downloads).
    case downloads

    static let channelPrefix = "channel:"

    var key: String {
        switch self {
        case .recent: "recent"
        case .myFiles: "onedrive"
        case .shared: "shared"
        case .channel(let id): Self.channelPrefix + id
        case .downloads: "downloads"
        }
    }

    init?(key: String) {
        switch key {
        case "recent": self = .recent
        case "onedrive": self = .myFiles
        case "shared": self = .shared
        case "downloads": self = .downloads
        default:
            guard key.hasPrefix(Self.channelPrefix), key.count > Self.channelPrefix.count else { return nil }
            self = .channel(String(key.dropFirst(Self.channelPrefix.count)))
        }
    }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .myFiles: "My Files"
        case .shared: "Shared in Chats"
        case .channel: "Channel"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        case .recent: "clock"
        case .myFiles: "cloud"
        case .shared: "bubble.left.and.bubble.right"
        case .channel: "number"
        case .downloads: "arrow.down.circle"
        }
    }

    /// Empty-state message (§6: "No Files" per source).
    var emptyMessage: String {
        switch self {
        case .recent: "Files you open, share or receive appear here."
        case .myFiles: "Files in your OneDrive appear here."
        case .shared: "Files shared in your chats appear here."
        case .channel: "Files shared in this channel appear here."
        case .downloads: "Files you download appear here."
        }
    }

    /// Where Upload… and drops go (Downloads has none).
    var acceptsUpload: Bool { self != .downloads }

    /// §6.6 list order: Recent · My Files · Shared in Chats · Teams
    /// (team › channel) · Downloads. Fixed; only the channel rows vary.
    static func listOrder(teams: [TeamItem]) -> [FilesSource] {
        [.recent, .myFiles, .shared]
            + teams.flatMap { t in t.channels.map { FilesSource.channel($0.channelId) } }
            + [.downloads]
    }
}

/// One table row: a remote file (Files index, channel library, a
/// chat's Files tab) or a local download.
struct FileItem: Identifiable, Equatable {
    enum Backing: Equatable {
        case remote(UnifiedFileRow)
        case local(FileTransfer)
    }

    let backing: Backing
    let id: String
    let name: String
    let isFolder: Bool
    let modified: Date?
    let modifiedBy: String
    let size: UInt64
    /// Location column: the conversation, "OneDrive", or the web app.
    let location: String
    /// Conversation id behind `location` (the link target).
    let locationID: String?

    /// Sort keys (Table sorting needs non-optional Comparable values).
    var modifiedKey: Date { modified ?? .distantPast }

    var row: UnifiedFileRow? {
        if case .remote(let r) = backing { return r }
        return nil
    }

    var transfer: FileTransfer? {
        if case .local(let t) = backing { return t }
        return nil
    }

    var webURL: URL? { row?.file.web_url.flatMap(URL.init(string:)) }

    static func remote(_ r: UnifiedFileRow) -> FileItem {
        let f = r.file
        // Drive rows: the leg label ("OneDrive"), or the demo folder a Move/Copy put it in.
        let location = r.source == .drive ? (r.sourceName.isEmpty ? "OneDrive" : r.sourceName) : (f.source_name ?? r.sourceName)
        return FileItem(
            backing: .remote(r), id: f.id, name: f.name, isFolder: f.isFolder,
            modified: (f.modified ?? f.created).flatMap(TeamsTime.parseISO), modifiedBy: f.sender ?? "",
            size: f.size, location: location, locationID: r.source == .drive ? nil : f.source_id)
    }

    static func local(_ t: FileTransfer) -> FileItem {
        FileItem(backing: .local(t), id: t.id, name: t.name, isFolder: false, modified: t.date,
                 modifiedBy: "", size: t.size, location: t.origin, locationID: t.originID)
    }

    /// Finder icon for the name (folders get the folder icon).
    var icon: NSImage {
        let type: UTType = isFolder ? .folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        return NSWorkspace.shared.icon(for: type)
    }

    var kindLabel: String {
        if isFolder { return "Folder" }
        return UTType(filenameExtension: (name as NSString).pathExtension)?.localizedDescription ?? "Document"
    }
}

/// What the table area shows under its header (§6, R12, R18): the
/// empty, loading and error states live inside the table area.
enum FilesPaneState: Equatable {
    case loading
    case error(message: String)
    case empty
    case files

    static let errorTitle = "Couldn\u{2019}t Load Files"
    static let offlineMessage = "You\u{2019}re offline."

    /// R12: rows on screen win over a refresh's loading or error.
    /// `forced` is the evidence `state=` override; `forcedOffline` the
    /// evidence `state=offline` (demo only).
    static func resolve(_ state: SharedFilesState, count: Int, forced: ForcedPaneState?,
                        forcedOffline: Bool, offline: Bool) -> FilesPaneState
    {
        if forcedOffline { return .error(message: offlineMessage) }
        switch forced {
        case .loading: return .loading
        case .empty: return .empty
        case .error: return .error(message: offline ? offlineMessage : "Something went wrong.")
        case nil: break
        }
        if count > 0 { return .files }
        switch state {
        case .loading: return .loading
        case .error(let m): return .error(message: offline ? offlineMessage : m)
        case .empty, .loaded: return .empty
        }
    }
}

/// One date and size format everywhere in Files (table, inspector,
/// versions, transfers).
enum FilesFormat {
    static func date(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
    }

    static func date(iso: String?) -> String {
        date(iso.flatMap(TeamsTime.parseISO))
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
