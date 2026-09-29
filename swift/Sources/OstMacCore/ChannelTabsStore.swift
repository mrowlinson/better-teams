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

    @Published public private(set) var tabs: [ChannelTab] = []
    @Published public private(set) var state: ChannelTabsState = .idle
    public private(set) var channelID: String?

    private let listFetcher: ListFetcher
    private var openGeneration = 0

    public nonisolated init(
        list: @escaping ListFetcher = { try RustCore.tabs(channelID: $0) }
    ) {
        self.listFetcher = list
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

    static func message(for error: Error) -> String {
        if case CoreCallError.failed(let m) = error { return m }
        return String(describing: error)
    }
}
