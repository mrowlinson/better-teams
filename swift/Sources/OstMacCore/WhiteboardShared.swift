// WhiteboardShared.swift — WHITEBOARD-BUILD: the shared board behind a
// whiteboard tab, over the RE-mapped REST+ODSP surface.
//
// The tab's embed/web route (ChatTabCatalog) renders the board itself;
// this store holds the board record (create/open), its share link, my
// permissions, and the read-only content snapshot (op counts; full op
// bytes stay in core until the phase-2 P3 decode lands). Every
// shared-board call is live-gated: when the service is unreachable
// the state is `.unavailable` with the server's reason, and the
// local-ink sketch (WhiteboardInkStore) stays the offline fallback.
// Live op streaming is not connected in this lane (no socket.io
// client; join bytes need live verification) — the UI says so.
import Combine
import Foundation

/// One shared board's loaded state (record + share + snapshot).
public struct WhiteboardSharedBoard: Equatable, Sendable {
    public var board: WhiteboardBoard
    public var perms: WhiteboardPerms?
    /// Content snapshot op count (nil = snapshot not read).
    public var ops: Int?
    public var hasMoreOps: Bool
    public var share: WhiteboardShareLink?
    /// Last share-mint failure (board stays loaded).
    public var shareError: String?
    /// Snapshot-read failure (board stays loaded).
    public var snapshotError: String?

    public init(
        board: WhiteboardBoard, perms: WhiteboardPerms? = nil, ops: Int? = nil,
        hasMoreOps: Bool = false, share: WhiteboardShareLink? = nil,
        shareError: String? = nil, snapshotError: String? = nil
    ) {
        self.board = board
        self.perms = perms
        self.ops = ops
        self.hasMoreOps = hasMoreOps
        self.share = share
        self.shareError = shareError
        self.snapshotError = snapshotError
    }
}

/// Load state of one shared board.
public enum WhiteboardSharedLoad: Equatable, Sendable {
    case idle
    case loading
    case loaded(WhiteboardSharedBoard)
    /// Live-gated: the service is unreachable; the reason is the
    /// server's (or transport's) own words.
    case unavailable(String)
}

/// Shared-board state for one whiteboard tab pane.
@MainActor
public final class WhiteboardSharedStore: ObservableObject {
    public typealias ShowFetcher = @Sendable (String) throws -> WhiteboardBoardResponse
    public typealias ShareFetcher = @Sendable (String) throws -> WhiteboardShareResponse
    public typealias PermsFetcher = @Sendable (String) throws -> WhiteboardPermsResponse
    public typealias ContentFetcher = @Sendable (String, String?) throws -> WhiteboardContentResponse
    public typealias CreateFetcher = @Sendable (String?) throws -> WhiteboardBoardResponse

    @Published public private(set) var load: WhiteboardSharedLoad = .idle
    /// Next content-page cursor (nil = first page / last page read).
    @Published public private(set) var cursor: String?
    /// A share mint is in flight (buttons disable meanwhile).
    @Published public private(set) var sharing = false
    /// A create is in flight (the sheet disables meanwhile).
    @Published public private(set) var creating = false

    private let showFetcher: ShowFetcher
    private let shareFetcher: ShareFetcher
    private let permsFetcher: PermsFetcher
    private let contentFetcher: ContentFetcher
    private let createFetcher: CreateFetcher
    private var generation = 0

    public nonisolated init(
        show: @escaping ShowFetcher = { try RustCore.whiteboardShow(boardID: $0) },
        share: @escaping ShareFetcher = { try RustCore.whiteboardShare(boardID: $0) },
        perms: @escaping PermsFetcher = { try RustCore.whiteboardMyPerms(boardID: $0) },
        content: @escaping ContentFetcher = { try RustCore.whiteboardContent(boardID: $0, cursor: $1) },
        create: @escaping CreateFetcher = { try RustCore.whiteboardCreate(title: $0) }
    ) {
        self.showFetcher = show
        self.shareFetcher = share
        self.permsFetcher = perms
        self.contentFetcher = content
        self.createFetcher = create
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }

    /// Load one board's shared state; demo tabs get their seeded
    /// state (loaded for the group demo, live-gated for the meeting
    /// demo so both UI states are capturable offline).
    public func load(boardID: String, demo: Bool) async {
        let id = boardID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if demo {
            load = DemoWhiteboardBoards.load(for: id)
            cursor = nil
            return
        }
        generation += 1
        let gen = generation
        load = .loading
        cursor = nil
        let show = showFetcher
        let perms = permsFetcher
        let content = contentFetcher
        do {
            let board = try await Task.blocking { try show(id) }.value.board
            guard gen == generation else { return }
            // Permissions + snapshot degrade (nil + note); only the
            // board read itself gates the pane.
            let gotPerms = try? await Task.blocking { try perms(id) }.value.perms
            guard gen == generation else { return }
            let page = try? await Task.blocking { try content(id, nil) }.value
            guard gen == generation else { return }
            cursor = page?.nextCursor
            load = .loaded(WhiteboardSharedBoard(
                board: board, perms: gotPerms, ops: page?.ops,
                hasMoreOps: page?.hasNext ?? false,
                snapshotError: page == nil ? "Snapshot unreadable." : nil))
        } catch {
            guard gen == generation else { return }
            load = .unavailable(Self.message(for: error))
        }
    }

    /// Re-run the last load (Refresh buttons).
    public func refresh(boardID: String, demo: Bool) async {
        await load(boardID: boardID, demo: demo)
    }

    /// Mint a share link on the loaded board. Failure lands in
    /// `shareError` and keeps the board.
    public func share(boardID: String, demo: Bool) async {
        guard case .loaded(var shared) = load else { return }
        if demo {
            shared.share = WhiteboardShareLink(
                shareURI: "https://example.com/demo-share/\(boardID)", token: "demo-token")
            shared.shareError = nil
            load = .loaded(shared)
            return
        }
        sharing = true
        defer { sharing = false }
        let fetcher = shareFetcher
        do {
            let link = try await Task.blocking { try fetcher(boardID) }.value.share
            guard case .loaded(var current) = load else { return }
            current.share = link
            current.shareError = nil
            load = .loaded(current)
        } catch {
            guard case .loaded(var current) = load else { return }
            current.shareError = Self.message(for: error)
            load = .loaded(current)
        }
    }

    /// Read the next snapshot page, accumulating op counts.
    public func loadMore(boardID: String, demo: Bool) async {
        guard case .loaded(var shared) = load, let cur = cursor, !demo else { return }
        let fetcher = contentFetcher
        guard let page = try? await Task.blocking(operation: { try fetcher(boardID, cur) }).value else { return }
        shared.ops = (shared.ops ?? 0) + page.ops
        shared.hasMoreOps = page.hasNext
        cursor = page.nextCursor
        load = .loaded(shared)
    }

    /// Create a board; demo synthesizes one locally, live calls core.
    /// The created board replaces the pane's shared state.
    public func create(title: String?, demo: Bool) async {
        if demo {
            let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            load = .loaded(WhiteboardSharedBoard(board: WhiteboardBoard(
                id: "demo-created", title: name.isEmpty ? "Untitled board" : name, isShared: false)))
            cursor = nil
            return
        }
        creating = true
        defer { creating = false }
        let fetcher = createFetcher
        do {
            let board = try await Task.blocking { try fetcher(title) }.value.board
            load = .loaded(WhiteboardSharedBoard(board: board))
            cursor = nil
        } catch {
            load = .unavailable(Self.message(for: error))
        }
    }
}

/// Demo shared-board states (offline; static only — never stored on
/// the live graph, so the DEMOLEAK guard stays green).
public enum DemoWhiteboardBoards {
    public static func load(for boardID: String) -> WhiteboardSharedLoad {
        switch boardID {
        case "demo-tab-wb3":
            // The meeting demo shows the live-gated state.
            return .unavailable("Shared board unreachable in this demo (offline).")
        default:
            return .loaded(WhiteboardSharedBoard(
                board: WhiteboardBoard(
                    id: boardID, title: "Sprint board", ownerID: "demo-owner",
                    isShared: true),
                perms: WhiteboardPerms(canEdit: true, canRead: true),
                ops: 12, hasMoreOps: false,
                share: WhiteboardShareLink(
                    shareURI: "https://example.com/demo-share/\(boardID)", token: "demo-token")))
        }
    }
}
