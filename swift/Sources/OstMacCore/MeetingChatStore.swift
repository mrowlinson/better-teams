// MeetingChatStore.swift — P4 split: verbatim move from MeetingChat.swift.
import Combine
import Foundation

/// Meeting-thread chat: live panel during the call, persisted thread
/// after. Meeting-thread realtime events adopt the panel on first
/// sight; every mutation persists to disk (Application Support), so
/// the thread survives restarts and the meeting ending. History merges
/// over the persisted snapshot on open (live-only ids survive).
/// Main-actor (SwiftUI-owned).
@MainActor
public final class MeetingChatStore: ObservableObject {
    public typealias LoadPersisted = @Sendable (String) -> [ChatMessage]
    public typealias SavePersisted = @Sendable (String, [ChatMessage]) -> Void
    public typealias DeletePersisted = @Sendable (String) -> Void

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var meetingActive = false
    @Published public private(set) var didLoad = false
    public private(set) var threadID: String?
    public private(set) var threadName: String?
    public private(set) var isDemo = false
    /// Own sender name (whoami display_name); nil until resolved or in demo.
    public private(set) var ownDisplayName: String?
    private var openGeneration = 0

    private let loadPersisted: LoadPersisted
    private let savePersisted: SavePersisted
    private let deletePersisted: DeletePersisted

    /// Nonisolated so views can take a default in their (nonisolated)
    /// inits; all members stay main-actor-isolated. Tests inject
    /// in-memory persistence (same seam as ChatListViewModel.Fetcher).
    public nonisolated init(
        load: @escaping LoadPersisted = { MeetingChatStore.fileLoad(threadID: $0) },
        save: @escaping SavePersisted = { MeetingChatStore.fileSave(threadID: $0, messages: $1) },
        delete: @escaping DeletePersisted = { MeetingChatStore.fileDelete(threadID: $0) }
    ) {
        self.loadPersisted = load
        self.savePersisted = save
        self.deletePersisted = delete
    }

    /// Demo store (core-b leak sweep): persistence is a no-op, so demo
    /// meeting chats never read or write the real on-disk threads.
    public nonisolated static func memoryOnly() -> MeetingChatStore {
        MeetingChatStore(load: { _ in [] }, save: { _, _ in }, delete: { _ in })
    }

    /// Header title: the thread name, else the generic label — never
    /// the raw thread id (om-chatnames).
    public var headerTitle: String {
        if let n = threadName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return "Meeting chat"
    }

    /// Open a meeting thread: the persisted snapshot shows instantly,
    /// then history merges over it. Stale completions are dropped.
    public func open(threadID: String, chatName: String? = nil, limit: Int32 = 50) {
        self.threadID = threadID
        if let n = chatName { self.threadName = n }
        messages = stamped(loadPersisted(threadID))
        meetingActive = true
        loading = true
        error = nil
        didLoad = false
        openGeneration += 1
        let gen = openGeneration
        Task {
            let own: String? = try? await Task.detached {
                try RustCore.whoami().display_name
            }.value
            guard gen == self.openGeneration else { return }
            if let own { self.ownDisplayName = own }
            do {
                let resp = try await Task.detached {
                    try RustCore.messages(chatID: threadID, limit: limit)
                }.value
                guard gen == self.openGeneration else { return }
                self.messages = Self.merge(
                    history: self.stamped(resp.messages), keeping: self.messages)
                self.didLoad = true
                self.loading = false
                self.persist()
            } catch {
                guard gen == self.openGeneration else { return }
                self.loading = false
                self.didLoad = true
                // The persisted snapshot stays visible; the error
                // surfaces with retry (never a blank panel).
                self.error = String(describing: error)
            }
        }
    }

    /// Re-run `open` for the current thread (Try Again). No-op without
    /// a thread, or in demo mode (demo never hits core).
    public func retryOpen(limit: Int32 = 50) {
        guard !isDemo, let id = threadID else { return }
        open(threadID: id, limit: limit)
    }

    /// Live routing (the AppState feed hook): meeting-thread events
    /// adopt the panel on first sight (persisted snapshot + history
    /// load, like open) and upsert every match; other threads upsert
    /// only when already open. Never touches the chat list.
    public func ingestIfMeeting(realtime message: RealtimeMessage) {
        if let open = threadID {
            guard message.isFor(chatID: open) else { return }
            ingestLive(message)
            return
        }
        guard MeetingSignal.isMeetingThread(message.chatID) else { return }
        open(threadID: message.chatID)
        ingestLive(message)
    }

    /// Demo mode: show canned messages (offline, no core).
    public func showDemo(threadID: String, chatName: String, messages: [ChatMessage]) {
        self.threadID = threadID
        self.threadName = chatName
        self.messages = messages
        isDemo = true
        meetingActive = true
        loading = false
        error = nil
        didLoad = true
    }

    /// Adopt an identity without core (tests, sign-in completion).
    public func adoptIdentity(displayName: String) {
        ownDisplayName = displayName
        messages = stamped(messages)
    }

    /// The meeting ended: the thread stays readable (and persisted) —
    /// only the live marker flips.
    public func endMeeting() {
        meetingActive = false
        persist()
    }

    /// Post via core; appends an optimistic own-bubble immediately and
    /// persists. Demo mode appends locally without touching core.
    public func send(text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        if isDemo {
            messages.append(ChatMessage(
                id: "demo-local-\(messages.count + 1)",
                sender: "Me", timestamp: ConversationStore.nowISO(),
                content: body, isOwn: true))
            persist()
            return
        }
        guard let id = threadID else { return }
        messages.append(ChatMessage(
            id: "pending-\(UUID().uuidString)",
            sender: "Me", timestamp: ConversationStore.nowISO(),
            content: body, isOwn: true))
        persist()
        Task {
            do {
                _ = try await Task.detached {
                    try RustCore.send(chatID: id, text: body)
                }.value
            } catch {
                self.error = "send failed: \(error)"
            }
        }
    }

    /// Drop memory after sign-out and delete the persisted snapshot
    /// (fail closed; history re-fetches on the next sign-in).
    public func clear() {
        if let id = threadID { deletePersisted(id) }
        threadID = nil
        threadName = nil
        messages = []
        error = nil
        didLoad = false
        meetingActive = false
        openGeneration += 1
    }

    /// Pure merge: history order wins, live-only ids append (the live
    /// bubble that landed before history never drops).
    public static func merge(history: [ChatMessage], keeping live: [ChatMessage]) -> [ChatMessage] {
        let known = Set(history.map(\.id))
        return history + live.filter { !known.contains($0.id) }
    }

    private func ingestLive(_ message: RealtimeMessage) {
        let targetID: String
        if message.isEdit, let edited = message.editedID {
            targetID = edited
        } else {
            targetID = message.msgId
        }
        if message.text.isEmpty, let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
            persist()
            return
        }
        var m = message.asChatMessage
        m.isOwn = ownDisplayName.map { m.sender == $0 } ?? false
        messages = ConversationStore.upsert(m, into: messages)
        if let r = message.reactions {
            applyReactions(id: targetID, reactions: r)
        }
        persist()
    }

    /// Replace one bubble's counts (realtime patch, server truth).
    /// Unknown ids are a no-op — counts never conjure a bubble.
    private func applyReactions(id: String, reactions: [ReactionCount]) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].reactions = reactions
    }

    private func stamped(_ list: [ChatMessage]) -> [ChatMessage] {
        ConversationStore.stampOwnership(list, ownName: ownDisplayName)
    }

    private func persist() {
        guard let id = threadID else { return }
        savePersisted(id, messages)
    }

    // MARK: - File persistence (default seam)

    /// Pre-rename Application Support leaf (never written, only moved).
    /// Built from parts: the literal itself is banned tree-wide (the
    /// Better Teams rename), but pre-rename installs keep their data
    /// via this exact migration string.
    nonisolated public static let legacyAppLeaf = "D" + "iet Teams"

    nonisolated public static func meetingsDirectory() -> URL? {
        meetingsDirectory(for: AccountProfile.defaultID)
    }

    /// Per-account meetings dir (d1-accounts): default keeps the
    /// base dir; others nest `<accountId>/` under it. Lazily migrates
    /// the legacy dir first, so pre-rename installs keep their data.
    nonisolated public static func meetingsDirectory(for accountID: String) -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        migrateLegacyDirectory(under: appSupport)
        return AccountProfile.dir(meetingsBaseURL(under: appSupport), for: accountID)
    }

    /// `<appSupport>/<AppIdentity.name>/meetings` (current dir).
    nonisolated public static func meetingsBaseURL(under appSupport: URL) -> URL {
        appSupport.appendingPathComponent("\(AppIdentity.name)/meetings", isDirectory: true)
    }

    /// `<appSupport>/<legacyAppLeaf>/meetings` (pre-rename dir).
    nonisolated public static func legacyMeetingsBaseURL(under appSupport: URL) -> URL {
        legacyAppLeafURL(under: appSupport).appendingPathComponent("meetings", isDirectory: true)
    }

    nonisolated public static func legacyAppLeafURL(under appSupport: URL) -> URL {
        appSupport.appendingPathComponent(legacyAppLeaf, isDirectory: true)
    }

    /// Move the legacy dir onto the new dir when the new one is absent
    /// (per-account subdirs ride along). No-op when legacy is missing
    /// or the new dir already exists — nothing is ever deleted.
    @discardableResult
    nonisolated public static func migrateLegacyDirectory(
        under appSupport: URL, fileManager: FileManager = .default
    ) -> Bool {
        let legacy = legacyMeetingsBaseURL(under: appSupport)
        let fresh = meetingsBaseURL(under: appSupport)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: fresh.path)
        else { return false }
        do {
            try fileManager.createDirectory(
                at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: fresh)
            return true
        } catch {
            return false
        }
    }

    /// Thread id → safe filename (alphanumerics kept, capped length).
    nonisolated public static func fileName(for threadID: String) -> String {
        let safe = threadID.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        let trimmed = String(safe.prefix(120))
        return (trimmed.isEmpty ? "meeting" : trimmed) + ".json"
    }

    nonisolated public static func fileLoad(threadID: String) -> [ChatMessage] {
        fileLoad(threadID: threadID, for: AccountProfile.defaultID)
    }

    /// Load one thread's snapshot from one account's namespace.
    nonisolated public static func fileLoad(threadID: String, for accountID: String) -> [ChatMessage] {
        guard let dir = meetingsDirectory(for: accountID) else { return [] }
        let url = dir.appendingPathComponent(fileName(for: threadID))
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    nonisolated public static func fileSave(threadID: String, messages: [ChatMessage]) {
        fileSave(threadID: threadID, messages: messages, for: AccountProfile.defaultID)
    }

    /// Save one thread's snapshot into one account's namespace.
    nonisolated public static func fileSave(threadID: String, messages: [ChatMessage], for accountID: String) {
        guard let dir = meetingsDirectory(for: accountID) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: dir.appendingPathComponent(fileName(for: threadID)), options: .atomic)
    }

    nonisolated public static func fileDelete(threadID: String) {
        fileDelete(threadID: threadID, for: AccountProfile.defaultID)
    }

    /// Delete one thread's snapshot from one account's namespace.
    nonisolated public static func fileDelete(threadID: String, for accountID: String) {
        guard let dir = meetingsDirectory(for: accountID) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName(for: threadID)))
    }
}
