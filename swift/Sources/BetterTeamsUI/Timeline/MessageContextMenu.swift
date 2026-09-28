// MessageContextMenu.swift — the message context menu (UI-SPEC §6.2.1)
// and the actions behind it.
//
// React ▸ (six quick + More…), Reply, Forward…, Copy, Copy Link ·
// Save/Unsave, Pin/Unpin, Translate, Mark Unread from Here · Edit,
// Delete… (own only). A failed send shows Retry and Delete instead.
// Three separator groups, one submenu level, no shortcuts (§6 context
// menus). Destructive actions confirm through `SheetPresenter` (R17).
import AppKit
import OstMacCore
import SwiftUI
import UniformTypeIdentifiers

struct MessageContextMenu: View {
    let row: MessageRowData
    let actions: TimelineActions

    var body: some View {
        let m = row.message
        if row.send == .failed {
            Button("Retry") { actions.retry(m) }
            Button("Copy") { actions.copy(m) }
            Divider()
            Button("Delete", role: .destructive) { actions.discard(m) }
        } else if m.deleted {
            Button("Copy Link") { actions.copyLink(m) }
        } else {
            Menu("React") {
                ForEach(Indexed.wrap(ConversationStore.reactionEmojis)) { e in
                    Button(e.value) { actions.react(m, e.value) }
                }
                Divider()
                Button("More…") { actions.moreReactions(m) }
            }
            Button("Reply") { actions.reply(m) }
            Button("Forward…") { actions.forward(m) }
            Button("Copy") { actions.copy(m) }
            Button("Copy Link") { actions.copyLink(m) }
            Divider()
            Button(SavedMessages.menuTitle(isSaved: row.isSaved)) { actions.toggleSave(m) }
            Button(PinnedMessages.menuTitle(isPinned: row.isPinned)) { actions.togglePin(m) }
            if MessageTranslation.isEligible(m) {
                Button(actions.translateTitle(m)) { actions.translate(m) }
            }
            Button("Mark Unread from Here") { actions.markUnread(from: m) }
            if m.isOwn && row.send == .none {
                Divider()
                Button("Edit") { actions.edit(m) }
                Button("Delete…", role: .destructive) { actions.delete(m) }
            }
        }
    }
}

/// Actions for timeline rows. Views call these; these call stores (R11).
@MainActor
final class TimelineActions {
    private let conv: ConversationStore
    private weak var model: WindowModel?
    private let services: ConversationServices
    /// Asks the timeline to center + highlight a row.
    var jumpHandler: ((String) -> Void)?

    init(conv: ConversationStore, model: WindowModel?, services: ConversationServices) {
        self.conv = conv
        self.model = model
        self.services = services
    }

    var media: MediaLoader { services.media }
    private var chatID: String? { conv.chatID }
    private var graph: (any AccountGraph)? { model?.graph }

    func jump(to id: String) { jumpHandler?(id) }

    func react(_ m: ChatMessage, _ emoji: String) { conv.react(messageID: m.id, emoji: emoji) }
    func toggleReaction(_ m: ChatMessage, _ emoji: String) { conv.toggleReaction(messageID: m.id, emoji: emoji) }
    func moreReactions(_ m: ChatMessage) { services.composer.show(.reaction(messageID: m.id)) }

    func reply(_ m: ChatMessage) {
        services.composer.editing = nil
        conv.beginReply(to: m)
        services.composer.focusRequest += 1
    }

    func forward(_ m: ChatMessage) {
        model?.presentSheet(SheetRequest(ChatCommands.forwardSheet, in: model?.nav.section ?? .chat, arg: m.id))
    }

    func copy(_ m: ChatMessage) {
        MessageActions.copy(m, highlighting: conv.ownDisplayName, write: MessageActions.liveCopyWriter)
    }

    func copyLink(_ m: ChatMessage) {
        let url = CardActions.fallbackURL(chatID: chatID, messageID: m.id)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    func toggleSave(_ m: ChatMessage) {
        graph?.savedMessages.toggle(chatID: chatID, message: m)
    }

    func togglePin(_ m: ChatMessage) {
        graph?.pinnedMessages.toggle(chatID: chatID, message: m)
    }

    func translateTitle(_ m: ChatMessage) -> String {
        guard let e = services.translation.entry(for: m.id) else { return MessageTranslation.menuTitle }
        switch e.state {
        case .translated, .sameLanguage: return e.isVisible ? "Show Original" : "Show Translation"
        case .failed: return "Try Translating Again"
        case .pending: return MessageTranslation.menuTitle
        }
    }

    func translate(_ m: ChatMessage) {
        let store = services.translation
        Task { await store.toggle(m) }
    }

    func markUnread(from m: ChatMessage) {
        guard let id = chatID else { return }
        graph?.unread.markUnread(chatID: id)
    }

    func edit(_ m: ChatMessage) {
        guard let id = chatID else { return }
        conv.cancelReply()
        services.composer.beginEdit(m, chatID: id)
    }

    func delete(_ m: ChatMessage) {
        guard let model else { return }
        Self.confirmDelete(m, conv: conv, model: model, services: services)
    }

    /// Delete… (§9.5 alert): the message stays marked in the timeline
    /// while the alert is up, so it is clear which one goes.
    static func confirmDelete(_ m: ChatMessage, conv: ConversationStore, model: WindowModel,
                              services: ConversationServices) {
        let oneToOne = conv.chatID.flatMap { model.graph.chats.chat(id: $0) }.map { !$0.is_group } ?? false
        services.composer.markedMessageID = m.id
        model.confirm(title: "Delete this message?",
                      message: "It will be deleted for everyone in the chat.",
                      action: "Delete", perform: { [conv] in
                          conv.deleteMessage(id: m.id, isOneToOne: oneToOne)
                      }, finished: { [weak composer = services.composer] in
                          composer?.markedMessageID = nil
                      })
    }

    /// Re-sends in place of the failed bubble (never a duplicate row).
    func retry(_ m: ChatMessage) {
        guard let text = conv.discardFailed(id: m.id) else { return }
        conv.send(text: text)
    }

    /// Failed sends never reached the server: dropped locally.
    func discard(_ m: ChatMessage) { conv.discardFailed(id: m.id) }

    // MARK: file chips (§6.2.1): the Files commands on the chip's file

    /// File chip: Open (demo previews instead), as Files ▸ Open.
    func openFile(_ d: InlineDoc) { runFile(FilesCommands.open, d) }

    /// File chip: Save to Downloads (Finder-style " 2" suffix, never
    /// overwriting) or Save As…; listed in Transfers and Files ▸
    /// Downloads. Demo writes to the demo tmp dir only.
    func saveFile(_ d: InlineDoc, choose: Bool) {
        runFile(choose ? FilesCommands.saveAs : FilesCommands.download, d)
    }

    /// File chip: Copy Link (sharing link to the pasteboard).
    func copyLink(file d: InlineDoc) { runFile(FilesCommands.copyLink, d) }

    private func runFile(_ c: CommandID, _ d: InlineDoc) {
        guard let m = model, let app = m.app, let files = m.provider(.files) as? FilesSection else { return }
        let chat = chatID
        let name = chat.map { id in
            m.graph.chats.chats.first { $0.id == id }?.name ?? FilesSection.channelName(id, app.teams.teams)
        } ?? "Chat"
        let source: UnifiedFileSource = ChannelTabsStore.isChannelID(chat ?? "") ? .channel : .chat
        files.perform(c, file: UnifiedFileRow(file: d.file, source: source, sourceName: name, sourceID: chat), m)
    }

    func preview(image model: RemoteImageModel) {
        guard let img = model.image else { return }
        ImageQuickLook.shared.show(img, name: model.messageID)
    }

    /// Saves a timeline image (a chat attachment) to ~/Downloads, or
    /// through a Save panel that opens there; the file is listed in
    /// Transfers and Files ▸ Downloads (TransferStore). Demo writes to
    /// the demo tmp dir only, never the chosen folder.
    func save(image media: RemoteImageModel, alt: String, choose: Bool) {
        guard let m = model, let app = m.app, let img = media.image, let png = ImageSave.png(img) else { return }
        let demo = m.options.demo
        let name = ImageSave.filename(alt: alt)
        let chat = chatID
        let origin = chat.map { id in
            m.graph.chats.chats.first { $0.id == id }?.name ?? FilesSection.channelName(id, app.teams.teams)
        } ?? "Chat"
        let transfers = app.transfers
        let record: (URL) -> Void = { dest in
            let id = transfers.begin(FileTransfer(name: dest.lastPathComponent, direction: .download, origin: origin,
                                                  originID: chat, path: dest.path, size: UInt64(png.count)))
            if (try? png.write(to: dest)) != nil {
                transfers.finish(id, path: dest.path)
            } else {
                transfers.fail(id, message: "The image couldn\u{2019}t be saved.")
            }
        }
        let demoDir = URL(fileURLWithPath: (UnifiedFilesStore.demoSaveDestination(filename: name) as NSString)
            .deletingLastPathComponent)
        let unique: (URL, String) -> URL = { dir, filename in
            ImageSave.uniqueDestination(dir: dir, name: filename) { FileManager.default.fileExists(atPath: $0) }
        }
        guard choose else {
            return record(unique(demo ? demoDir : TeamsFrameDownloads.defaultDirectory(), name))
        }
        guard let window = FilesSection.window(m) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.png]
        panel.directoryURL = TeamsFrameDownloads.defaultDirectory()
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            record(demo ? unique(demoDir, url.lastPathComponent) : url)
        }
    }
}
