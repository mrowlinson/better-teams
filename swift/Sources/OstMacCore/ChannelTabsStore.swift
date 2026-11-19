// ChannelTabsStore.swift — channel tabs store (moved verbatim from
// TeamsTabsView.swift in the scratch-ui rebuild; the view was
// deleted, the store API is frozen).
import Combine
import Foundation

/// Channel-tabs content state.
public enum ChannelTabsState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case error(String)
}

@MainActor
public final class ChannelTabsStore: ObservableObject {
    public typealias ListFetcher = @Sendable (String) throws -> TabsResponse
    public typealias AddFetcher = @Sendable (String, String, String?, String?) throws -> TabManageResponse
    public typealias RenameFetcher = @Sendable (String, String, String) throws -> TabManageResponse
    public typealias RemoveFetcher = @Sendable (String, String) throws -> TabRemoveResponse

    @Published public private(set) var tabs: [ChannelTab] = []
    @Published public private(set) var state: ChannelTabsState = .idle
    /// Last add/rename/remove failure (list state is untouched).
    @Published public private(set) var manageError: String?
    public private(set) var channelID: String?

    private let listFetcher: ListFetcher
    private let addFetcher: AddFetcher
    private let renameFetcher: RenameFetcher
    private let removeFetcher: RemoveFetcher
    private var openGeneration = 0

    public nonisolated init(
        list: @escaping ListFetcher = { try RustCore.tabs(channelID: $0) },
        add: @escaping AddFetcher = { try RustCore.channelTabAdd(channelID: $0, name: $1, appID: $2, url: $3) },
        rename: @escaping RenameFetcher = { try RustCore.channelTabRename(channelID: $0, tabID: $1, name: $2) },
        remove: @escaping RemoveFetcher = { try RustCore.channelTabRemove(channelID: $0, tabID: $1) }
    ) {
        self.listFetcher = list
        self.addFetcher = add
        self.renameFetcher = rename
        self.removeFetcher = remove
    }

    /// Channel ids are `19:...@thread.tacv2` (ost files.rs parity).
    /// Plain chat ids never open the tabs row. Nonisolated: pure
    /// string test, callable from any context (views, stores, tests).
    public nonisolated static func isChannelID(_ id: String) -> Bool {
        let t = id.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("19:") && t.hasSuffix("@thread.tacv2")
    }

    /// Open a channel: fetch its tabs via core, replace the row.
    /// Non-channel ids reset to idle (no fetch). Stale completions are
    /// dropped (fast channel-switching lands newest).
    public func open(channelID: String) {
        openGeneration += 1
        let gen = openGeneration
        guard Self.isChannelID(channelID) else {
            self.channelID = nil
            tabs = []
            state = .idle
            return
        }
        self.channelID = channelID
        state = .loading
        Task {
            let fetcher = listFetcher
            do {
                let resp = try await Task.blocking { try fetcher(channelID) }.value
                guard gen == openGeneration else { return }
                tabs = resp.tabs
                state = resp.tabs.isEmpty ? .empty : .loaded
            } catch {
                guard gen == openGeneration else { return }
                state = .error(Self.message(for: error))
            }
        }
    }

    /// Fire-and-forget reload.
    public func refresh() {
        guard let id = channelID else { return }
        open(channelID: id)
    }

    /// Clear a surfaced manage failure (after the UI shows it).
    public func clearManageError() { manageError = nil }

    /// Add a website/app tab to the open channel. On success the
    /// returned tab is appended without a full reload; failure lands
    /// in `manageError` and the list is untouched.
    public func add(name: String, url: String? = nil, appID: String? = nil) async {
        guard let id = channelID else { return }
        manageError = nil
        let (add, channelID) = (addFetcher, id)
        do {
            let response = try await Task.blocking {
                try add(channelID, name, appID, url)
            }.value
            tabs.append(response.tab)
            state = .loaded
        } catch {
            manageError = Self.message(for: error)
        }
    }

    /// Rename one of the open channel's tabs (configure). On success
    /// the row is replaced in place; failure lands in `manageError`.
    public func rename(tabID: String, name: String) async {
        guard let id = channelID else { return }
        manageError = nil
        let (rename, channelID) = (renameFetcher, id)
        do {
            let response = try await Task.blocking {
                try rename(channelID, tabID, name)
            }.value
            if let i = tabs.firstIndex(where: { $0.id == response.tab.id }) {
                tabs[i] = response.tab
            }
        } catch {
            manageError = Self.message(for: error)
        }
    }

    /// Remove one of the open channel's tabs. On success the row is
    /// dropped locally (empty list flips to `.empty`); failure lands
    /// in `manageError` and keeps the row.
    public func remove(tabID: String) async {
        guard let id = channelID else { return }
        manageError = nil
        let (remove, channelID) = (removeFetcher, id)
        do {
            _ = try await Task.blocking {
                try remove(channelID, tabID)
            }.value
            tabs.removeAll { $0.id == tabID }
            if tabs.isEmpty { state = .empty }
        } catch {
            manageError = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
