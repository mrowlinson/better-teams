// SearchDetail.swift — search-mode detail pane (UI-SPEC §5.5, §6).
//
// Shows the selected result: a conversation (landed on the hit's
// message by the jump API), a person (Call, Video, Chat, Email), or a
// file (Open, Quick Look, Download, Show in Chat, Open in Browser).
// Results but nothing selected = "No Result Selected"; a finished search
// with no results = "No Results" (R18: never a blank pane).
import AppKit
import OstMacCore
import Quartz
import SwiftUI

struct SearchDetailPane: View {
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let app = model.app {
            SearchDetailContent(search: model.search, conv: model.graph.conv, chats: model.graph.chats,
                                messages: app.messageSearch, local: app.localSearch,
                                filePeople: app.filePeople, presence: app.presence)
        } else if let model {
            SearchDetailContent(search: model.search, conv: model.graph.conv, chats: model.graph.chats,
                                messages: nil, local: nil, filePeople: nil, presence: nil)
        }
    }
}

private struct SearchDetailContent: View {
    let search: SearchModel
    @ObservedObject var conv: ConversationStore
    @ObservedObject var chats: ChatListViewModel
    // Observed so the empty/no-selection choice follows the results.
    let messages: MessageSearchStore?
    let local: LocalSearchStore?
    let filePeople: FilePeopleSearchStore?
    let presence: PresenceStore?

    var body: some View {
        if let messages, let local, let filePeople, let presence {
            ObservedDetail(search: search, conv: conv, chats: chats, messages: messages, local: local,
                           filePeople: filePeople, presence: presence)
        } else {
            NoSelectionPane("No Result Selected")
        }
    }
}

private struct ObservedDetail: View {
    let search: SearchModel
    @ObservedObject var conv: ConversationStore
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var messages: MessageSearchStore
    @ObservedObject var local: LocalSearchStore
    @ObservedObject var filePeople: FilePeopleSearchStore
    @ObservedObject var presence: PresenceStore
    @Environment(\.windowModel) private var model

    var body: some View {
        if search.orderedResults().isEmpty {
            if search.isSearching {
                // The first results are on their way (the list spins).
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                NoSelectionPane("No Results")
            }
        } else {
            selected
        }
    }

    @ViewBuilder
    private var selected: some View {
        switch search.selected {
        case .target(let id):
            if let open = search.target(id)?.openID {
                ConversationDetail(ref: open, conv: conv, chats: chats)
            } else {
                NoSelectionPane("No Result Selected")
            }
        case .message(let id):
            if let hit = search.messageHit(id) {
                ConversationDetail(ref: hit.chatID, conv: conv, chats: chats)
            } else {
                NoSelectionPane("No Result Selected")
            }
        case .person(let id):
            if let p = search.person(id) {
                PersonCard(name: p.displayName,
                           presence: PeerPresence.status(presence, chatID: nil, userID: p.userId ?? p.id),
                           detail: p.email ?? "", note: nil) {
                    if let model {
                        // Calls ▸ person detail's set (Call, Video, Chat).
                        Button("Call") { SearchPersonActions.call(p, model) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!(model.call.map(\.ended) ?? true))
                        Button("Video") {}
                            .disabled(true)
                            .help("Video calls aren\u{2019}t available yet")
                        Button("Chat") { SearchPersonActions.chat(p, model) }
                    }
                    if let email = p.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                        Button("Email") { NSWorkspace.shared.open(url) }
                    }
                }
            } else {
                NoSelectionPane("No Result Selected")
            }
        case .file(let id):
            if let f = search.file(id), let shared = model?.app?.shared {
                FileCard(file: f, shared: shared) { search.activate(.file(f.id)) }
            } else {
                NoSelectionPane("No Result Selected")
            }
        case nil:
            NoSelectionPane("No Result Selected")
        }
    }
}

/// Someone else's presence (§6: shape + color): the 1:1 chat pin first
/// (the chat row/header source), else the directory dot by user id.
enum PeerPresence {
    @MainActor
    static func status(_ p: PresenceStore, chatID: String?, userID: String?) -> PresenceStatus? {
        let r = chatID.flatMap { p.chatPeers[$0] } ?? userID.flatMap { p.peers[$0] }
        return r.flatMap { PresenceStatus.from(availability: $0.availability) }
    }

    /// A person's status in words. `PresenceStatus.title` is the own
    /// status picker's wording ("Appear away"), wrong for someone else.
    static func label(_ s: PresenceStatus) -> String {
        switch s {
        case .away: "Away"
        case .offline: "Offline"
        default: s.title
        }
    }
}

/// A person, centered: avatar (with presence), name, presence, one
/// detail line (optionally led by a symbol), actions (search People
/// results and Activity missed calls).
struct PersonCard<Actions: View>: View {
    let name: String
    var presence: PresenceStatus? = nil
    let detail: String
    var detailSymbol: String? = nil
    let note: String?
    @ViewBuilder let actions: () -> Actions
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        PaneAnchorLayout {
            VStack(spacing: 10) {
                Avatar(name: name, diameter: 64)
                    .overlay(alignment: .bottomTrailing) {
                        if let presence { PresenceBadge(status: presence, size: 16) }
                    }
                VStack(spacing: 4) {
                    Text(name).font(AppFont.title3(scale))
                    if let presence {
                        Text(PeerPresence.label(presence))
                            .font(AppFont.subheadline(scale))
                            .foregroundStyle(.secondary)
                    }
                }
                if !detail.isEmpty {
                    if let detailSymbol {
                        Label {
                            Text(detail).foregroundStyle(.secondary)
                        } icon: {
                            // Missed call: red symbol + the word (§10).
                            Image(systemName: detailSymbol).foregroundStyle(Palette.failed)
                        }
                        .font(AppFont.body(scale))
                    } else {
                        Text(detail).font(AppFont.body(scale)).foregroundStyle(.secondary)
                    }
                }
                if let note {
                    Text(note).font(AppFont.subheadline(scale)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) { actions() }
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
        }
    }
}

/// A file, centered: system type icon, name, who shared it where, date
/// and size; Open, Quick Look, Download (Files ▸ context menu wording),
/// Show in Chat (the conversation it was shared in, `source_id`) and
/// Open in Browser.
struct FileCard: View {
    let file: SharedFile
    @ObservedObject var shared: SharedFilesStore
    let showInChat: () -> Void
    @Environment(\.contentTextScale) private var scale
    @Environment(\.windowModel) private var model
    /// Local copy on its way for Open / Quick Look (destination path).
    @State private var pending: (dest: String, quickLook: Bool)?

    var body: some View {
        PaneAnchorLayout {
            VStack(spacing: 10) {
                FileIcon(file: file, size: 64)
                Text(file.name)
                    .font(AppFont.title3(scale))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                VStack(spacing: 4) {
                    if let shared = SearchFileRow.sharedLine(file) {
                        Text(shared).font(AppFont.body(scale)).foregroundStyle(.secondary)
                    }
                    Text(SearchFileRow.dateAndSize(file, now: RelativeClock.shared.now))
                        .font(AppFont.subheadline(scale)).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("Open") { fetch(quickLook: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canFetch)
                    Button("Quick Look") { fetch(quickLook: true) }
                        .disabled(!canFetch)
                    Button("Download", action: download)
                        .disabled((file.drive_id == nil && file.download_url == nil)
                                  || shared.savingIDs.contains(file.id))
                }
                .controlSize(.large)
                .padding(.top, 6)
                HStack(spacing: 8) {
                    Button("Show in Chat", action: showInChat)
                        .disabled(file.source_id?.isEmpty ?? true)
                    if let url = file.web_url.flatMap(URL.init(string:)) {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
        }
        .onChange(of: shared.savedPath) { _, path in
            guard let p = pending, path == p.dest else { return }
            pending = nil
            let url = URL(fileURLWithPath: p.dest)
            if p.quickLook { FileQuickLook.shared.show(url) } else { NSWorkspace.shared.open(url) }
        }
    }

    /// Download to ~/Downloads, listed in Transfers and Files ▸ Downloads
    /// like Files ▸ Download (TransferStore). A file without a drive item
    /// opens its pre-signed link in the browser, which downloads it.
    private func download() {
        guard file.drive_id != nil, !shared.isDemo, !shared.savingIDs.contains(file.id),
              let transfers = model?.app?.transfers else {
            shared.save(file)
            return
        }
        let id = transfers.begin(FileTransfer(name: file.name, direction: .download,
                                              origin: file.source_name ?? "OneDrive",
                                              originID: file.source_id, size: file.size))
        shared.saveAs(file, to: SharedFilesStore.downloadDestination(filename: file.name)) { [weak transfers] path, failure in
            if let path {
                transfers?.finish(id, path: path)
            } else {
                transfers?.fail(id, message: failure ?? "The file couldn\u{2019}t be saved.")
            }
        }
    }

    /// Open and Quick Look need the bytes: a drive item downloads first.
    private var canFetch: Bool { file.drive_id != nil && !shared.savingIDs.contains(file.id) }

    /// Downloads to a private temporary folder, then opens it (default
    /// app) or previews it once `savedPath` reports that destination.
    private func fetch(quickLook: Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterTeams-Open", isDirectory: true)
            .appendingPathComponent(CardLinks.safeName(file.id), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((file.name as NSString).lastPathComponent).path
        pending = (dest, quickLook)
        shared.saveAs(file, to: dest)
    }
}

/// Quick Look for a downloaded search file (QLPreviewPanel, the system
/// panel §5.7 allows).
@MainActor
final class FileQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = FileQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

/// Search People result actions (Calls ▸ person detail's Call / Chat):
/// the person's 1:1 chat, started when there is none yet.
@MainActor
enum SearchPersonActions {
    static func chat(_ p: TeamMember, _ m: WindowModel) {
        withThread(p, m) { id in
            m.navigator?.select(SectionSelection(id: id), in: .chat)
            m.navigator?.select(section: .chat)
        }
    }

    static func call(_ p: TeamMember, _ m: WindowModel) {
        withThread(p, m) { id in
            let key = (p.userId ?? p.id).lowercased()
            CallsSection.call(CallsSection.Person(name: p.displayName, personID: p.userId ?? p.id,
                                                  personKey: key, thread: id), m)
        }
    }

    private static func withThread(_ p: TeamMember, _ m: WindowModel, _ then: @escaping @MainActor (String) -> Void) {
        if let id = CallsSection.oneToOne(named: p.displayName, m) { return then(id) }
        guard let app = m.app else { return }
        Task { @MainActor in
            guard await app.openNewChat(people: [p]), let id = app.openChatID else {
                NSSound.beep()
                return
            }
            then(id)
        }
    }
}
