// SearchIndexRebuild.swift — Settings ▸ Advanced ▸ Rebuild Index over
// every chat and channel stored on this Mac, not just the open one.
//
// The pass re-indexes each `LocalSearchStore.CachedThread` into a scratch
// store, one thread per main-actor turn (search keeps answering from the
// live index meanwhile), then hands the scratch store to `finish`, which
// swaps it in and saves. Live history and deletes that land mid-pass are
// mirrored into the scratch store so the swap loses nothing. Cancel (quit,
// account switch, the Settings button) drops the scratch store: the live
// index and its file stay exactly as they were. No network, no core.
import Foundation

@MainActor
public final class SearchIndexRebuild: ObservableObject {
    public struct Progress: Equatable, Sendable {
        public let done: Int
        public let total: Int
    }

    public enum Outcome: Equatable, Sendable {
        case finished(docs: Int)
        case cancelled
        case failed(String)
    }

    /// Threads done / total while a pass runs; nil when idle.
    @Published public private(set) var progress: Progress?
    /// How the last pass ended (nil before any pass, and while running).
    @Published public private(set) var outcome: Outcome?

    public var running: Bool { progress != nil }

    private var scratch: LocalSearchStore?
    /// Docs indexed live or deleted mid-pass: a thread still queued never
    /// overwrites (older copy) or re-adds (deleted) them.
    private var settled: Set<String> = []
    private var task: Task<Void, Never>?

    public init() {}

    /// Start a pass over `threads` (supersedes a running one). `finish`
    /// gets the rebuilt store and returns the outcome to publish.
    public func start(
        threads: [LocalSearchStore.CachedThread],
        finish: @escaping @MainActor (LocalSearchStore) -> Outcome
    ) {
        cancel()
        let store = LocalSearchStore()
        scratch = store
        settled = []
        outcome = nil
        progress = Progress(done: 0, total: threads.count)
        task = Task { @MainActor [weak self] in
            for (i, t) in threads.enumerated() {
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                let keep = t.messages.filter {
                    !self.settled.contains(LocalSearchStore.docKey(chatID: t.chatID, messageID: $0.id))
                }
                store.index(chatID: t.chatID, teamID: t.teamID, channelID: t.channelID, messages: keep)
                self.progress = Progress(done: i + 1, total: threads.count)
            }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.scratch = nil
            self.settled = []
            self.progress = nil
            self.outcome = finish(store)
        }
    }

    /// Stop a running pass; the live index is untouched.
    public func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        scratch = nil
        settled = []
        progress = nil
        outcome = .cancelled
    }

    /// Wait for the running pass (tests).
    public func wait() async {
        await task?.value
    }

    /// Live history batch while a pass runs: mirror it into the scratch store.
    func noteIndexed(chatID: String, messages: [ChatMessage]) {
        guard let scratch else { return }
        scratch.index(chatID: chatID, messages: messages)
        for m in messages { settled.insert(LocalSearchStore.docKey(chatID: chatID, messageID: m.id)) }
    }

    /// Live delete while a pass runs: drop it and keep it dropped.
    func noteRemoved(chatID: String, messageID: String) {
        guard let scratch else { return }
        scratch.remove(chatID: chatID, messageID: messageID)
        settled.insert(LocalSearchStore.docKey(chatID: chatID, messageID: messageID))
    }
}
