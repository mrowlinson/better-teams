// ConversationServices.swift — per-window conversation state that is
// not domain state (UI-SPEC §6.2, §11.3): composer model, translation
// store (session attached by ConversationDetail's translationTask),
// media loader, attachment staging, GIF key. One per WindowModel.
import AppKit
import Combine
import OstMacCore
import SwiftUI

/// Popovers anchored to the composer (§6.2.2), one at a time (R17) by
/// construction: the composer holds a single optional value.
enum ComposerPopover: Hashable, Identifiable {
    case mention
    case reaction(messageID: String)
    case gif
    case sendLater

    var id: String {
        switch self {
        case .mention: "mention"
        case .reaction(let m): "reaction:\(m)"
        case .gif: "gif"
        case .sendLater: "sendLater"
        }
    }

    /// Evidence route names (`popover=<name>`, demo only).
    init?(evidenceName: String, lastMessageID: String?) {
        switch evidenceName {
        case ChatCommands.mentionPopover: self = .mention
        case ChatCommands.gifPopover: self = .gif
        case ChatCommands.sendLaterPopover: self = .sendLater
        case ChatCommands.reactionPopover:
            guard let lastMessageID else { return nil }
            self = .reaction(messageID: lastMessageID)
        default: return nil
        }
    }
}

/// Composer UI state shared by the composer and the timeline's context
/// menu (Edit, React ▸ More…). Drafts are per chat.
@MainActor
final class ComposerModel: ObservableObject {
    @Published var drafts: [String: String] = [:]
    @Published var popover: ComposerPopover?
    /// Own message being edited (Return saves through `conv.edit`).
    @Published var editing: ChatMessage?
    /// Bumped to ask the composer's text view to take focus.
    @Published var focusRequest = 0
    /// The message a confirmation alert (Delete…) acts on: the timeline
    /// marks it while the alert is up.
    @Published var markedMessageID: String?
    /// Evidence `popover=` applied (once per window).
    var evidenceApplied = false
    /// The window's timelines in creation order (a channel's Posts and
    /// its thread inspector both show a thread's root): one of them
    /// presents the reaction picker.
    private var timelineRefs: [WeakTimeline] = []
    private struct WeakTimeline { weak var value: AnyObject? }

    func register(timeline: AnyObject) {
        timelineRefs.removeAll { $0.value == nil }
        timelineRefs.append(WeakTimeline(value: timeline))
    }

    var timelines: [AnyObject] { timelineRefs.compactMap(\.value) }

    func draft(_ chatID: String) -> String { drafts[chatID] ?? "" }

    func setDraft(_ text: String, for chatID: String) {
        if drafts[chatID] != text { drafts[chatID] = text }
    }

    func beginEdit(_ m: ChatMessage, chatID: String) {
        popover = nil
        editing = m
        setDraft(m.content, for: chatID)
        focusRequest += 1
    }

    func endEdit(chatID: String) {
        editing = nil
        setDraft("", for: chatID)
    }

    /// Opens a popover; a second request replaces the first (never two).
    func show(_ p: ComposerPopover) { popover = p }
}

/// Owns remote media models so rows never start network loads (R24):
/// the timeline controller prefetches when messages arrive, rows only
/// observe. Keyed by URL (+ message for images, the cache key).
@MainActor
final class MediaLoader {
    private var images: [String: RemoteImageModel] = [:]
    private var previews: [String: LinkPreviewModel] = [:]
    private let demo: Bool

    init(demo: Bool) { self.demo = demo }

    func image(url: String, messageID: String) -> RemoteImageModel {
        let key = messageID + "\n" + url
        if let m = images[key] { return m }
        let m = RemoteImageModel(url: url, messageID: messageID,
                                 fetcher: demo ? { @Sendable url in try DemoMedia.data(for: url) } : nil)
        images[key] = m
        return m
    }

    func preview(url: String) -> LinkPreviewModel {
        if let m = previews[url] { return m }
        // Demo stays offline: a canned page titled from the URL path.
        let m = LinkPreviewModel(urlString: url, fetcher: demo ? { @Sendable u in
            Data("<html><head><title>\(MediaLoader.demoTitle(u))</title></head></html>".utf8)
        } : nil)
        previews[url] = m
        return m
    }

    nonisolated static func demoTitle(_ url: URL) -> String {
        let words = url.path.split(separator: "/").map { $0.capitalized }
        return words.isEmpty ? (url.host ?? "Link") : words.joined(separator: " ")
    }

    /// Starts loads for every image and first link in `messages`
    /// (idempotent: models load once).
    func prefetch(_ messages: [ChatMessage]) {
        for m in messages where !m.deleted {
            for img in MessageRender.images(fromRaw: m.raw) where !img.isEmoticon {
                image(url: img.url, messageID: m.id).load()
            }
            if let link = LinkPreviewRules.previewURL(for: m) {
                preview(url: link).load()
            }
            for card in MessageBubbleState.cards(for: m) {
                for url in Self.imageURLs(card.body) { image(url: url, messageID: m.id).load() }
            }
        }
    }

    static func imageURLs(_ elements: [AdaptiveCard.Element]) -> [String] {
        elements.flatMap { e -> [String] in
            switch e {
            case .image(let i): [i.url]
            case .container(let items): imageURLs(items)
            case .columns(let cols): cols.flatMap { imageURLs($0) }
            case .text, .facts: []
            }
        }
    }
}

/// Which link gets a preview card: the first sanitized https URL of a
/// message without images, cards, or bot rows (pure, unit-tested).
enum LinkPreviewRules {
    static func previewURL(for m: ChatMessage) -> String? {
        guard !m.deleted, MessageRender.images(fromRaw: m.raw).isEmpty,
              MessageRender.botPosts(fromRaw: m.raw ?? m.content).isEmpty,
              !MessageBubbleState.shouldShowCards(for: m),
              let raw = LinkPreviewParse.firstCandidate(for: m),
              let url = LinkPreviewParse.sanitizedURL(from: raw),
              url.scheme?.lowercased() == "https"
        else { return nil }
        return url.absoluteString
    }
}

@MainActor
final class ConversationServices {
    let composer = ComposerModel()
    /// Demo translates with in-memory defaults, so a demo session never
    /// reads or writes the real target language.
    let translation: TranslationStore
    let media: MediaLoader
    let attachments: ComposeAttachmentsStore
    let isDemo: Bool
    private var gifKey: String?

    init(demo: Bool) {
        isDemo = demo
        translation = TranslationStore(defaults: demo ? MemoryDefaults() : .standard)
        media = MediaLoader(demo: demo)
        // Demo uploads are fabricated by `uploadPending(isDemo:)`.
        // §106: chat file sends keep one client message id across Retry.
        attachments = ComposeAttachmentsStore(uploadIdem: ComposeAttachmentsStore.liveIdemUpload)
    }

    /// GIF search needs a Klipy key (§6.2.2): demo uses canned GIFs and
    /// never reads the keychain; live reads it once, lazily.
    var hasGIFKey: Bool {
        if isDemo { return true }
        if gifKey == nil { gifKey = KlipyClient.storedKey() }
        return !(gifKey ?? "").isEmpty
    }

    func searchGIFs(_ query: String) async -> [KlipyGIF] {
        if isDemo {
            return [KlipyGIF(id: "demo-gif-1", title: "Celebrate", previewURL: DemoMedia.gif1,
                             fullURL: DemoMedia.gif1Full)]
        }
        guard hasGIFKey, let key = gifKey else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? await (q.isEmpty ? KlipyClient.trending(apiKey: key)
                                      : KlipyClient.search(query: q, apiKey: key))) ?? []
    }

    /// Demo keeps its own queue in the app's temporary directory, so a
    /// demo session never writes the real `scheduled.json`.
    private lazy var demoScheduled = ScheduledSendStore(
        path: FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterTeams-demo-scheduled-\(ProcessInfo.processInfo.processIdentifier).json").path)

    func scheduled(_ m: WindowModel?) -> ScheduledSendStore? {
        isDemo ? demoScheduled : m?.app?.scheduled
    }

    /// Per-chat notification level, mute and hide (§6.2 Info). Demo keeps
    /// its own rules file in the temporary directory, so a demo session
    /// never writes the real `rules.json`.
    /// Demo rows state their Teams mute state (DemoData chats), adopted
    /// like a fetched chat page.
    private lazy var localRules: RulesStore = {
        let r = RulesStore(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("BetterTeams-demo-rules-\(ProcessInfo.processInfo.processIdentifier).json").path)
        if isDemo { r.adoptServerMutes(DemoData.chats) }
        return r
    }()

    func rules(_ m: WindowModel?) -> RulesStore {
        if !isDemo, let r = m?.app?.rules { return r }
        return localRules
    }

    /// Per-chat snooze (§6.2 Info). Snoozes are keyed by chat id and
    /// always expire. The no-app fallback is in memory in demo, so a
    /// demo session never touches the real snooze expiries.
    private lazy var localSnooze = SnoozeStore(defaults: isDemo ? MemoryDefaults() : .standard)

    func snooze(_ m: WindowModel?) -> SnoozeStore {
        m?.app?.snooze ?? localSnooze
    }

    /// Chat list rows follow the open conversation (one source): when
    /// its newest message is newer than the row's last message (a send,
    /// a queued own message), the row takes its preview and time.
    private var previewSync: AnyCancellable?
    /// Chats whose newest message failed to send, from the same source
    /// as the timeline's "Not Sent" (the open conversation's
    /// `failedIDs`); a row keeps the mark until its chat is reopened
    /// without a failed newest message.
    let sendFailures = SendFailures()

    func syncListPreviews(_ m: WindowModel) {
        guard previewSync == nil else { return }
        let conv = m.graph.conv
        let chats = m.graph.chats
        let failures = sendFailures
        // Demo chats ship pre-failed sends: their rows carry the mark
        // before the chat is ever opened (the list never lies about it).
        if m.options.demo {
            for c in DemoData.chats {
                let failed = DemoData.failedIDs(for: c.id)
                if let last = DemoData.messages(for: c.id).last(where: { !$0.deleted }), failed.contains(last.id) {
                    failures.set(chatID: c.id, failed: true)
                }
            }
        }
        previewSync = conv.$messages.combineLatest(conv.$failedIDs)
            .receive(on: DispatchQueue.main)
            .sink { [weak conv, weak chats] _ in
                guard let conv, let chats, let id = conv.chatID else { return }
                let last = conv.messages.last(where: { !$0.deleted })
                failures.set(chatID: id, failed: last.map { conv.failedIDs.contains($0.id) } ?? false)
                guard let row = chats.chat(id: id), let last else { return }
                let rowTime = row.last_message_time.flatMap(TeamsTime.parseISO)
                guard let t = TeamsTime.parseISO(last.timestamp), rowTime.map({ t > $0 }) ?? true else { return }
                chats.ingest(realtime: RealtimeMessage(
                    chatID: id, msgId: last.id, sender: last.sender,
                    text: MessageRender.bubbleText(for: last), time: last.timestamp,
                    isEdit: false, raw: last.raw))
            }
    }

    private static var registry: [ObjectIdentifier: ConversationServices] = [:]

    /// The window's services (created on first use, live as long as the
    /// window model: one per account window).
    static func of(_ m: WindowModel) -> ConversationServices {
        let k = ObjectIdentifier(m)
        if let s = registry[k] { return s }
        let s = ConversationServices(demo: m.options.demo)
        registry[k] = s
        s.syncListPreviews(m)
        return s
    }
}

/// Chat ids whose newest message is marked "Not Sent" (§6.2 row, R13).
@MainActor
final class SendFailures: ObservableObject {
    @Published private(set) var chatIDs: Set<String> = []

    func set(chatID: String, failed: Bool) {
        guard chatIDs.contains(chatID) != failed else { return }
        if failed { chatIDs.insert(chatID) } else { chatIDs.remove(chatID) }
    }
}
