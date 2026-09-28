// FileTable.swift — cross-lane seam (UI-SPEC §6.6, §11.3). Final
// signature. A chat's and a channel's Files tab are the Files table
// (`FileTableView`: same columns, sorting, context menu, Quick Look)
// over the account's shared-files store, which opens with the
// conversation (R24: no fetch here). `.source` shows a Files source.
import AppKit
import OstMacCore
import SwiftUI

public enum FileScope: Hashable, Sendable {
    case conversation(ConversationRef)
    case channel(team: String, channel: String)
    case source(String)
}

public struct FileTable: View {
    public let scope: FileScope
    @Environment(\.windowModel) private var model

    public init(scope: FileScope) { self.scope = scope }

    public var body: some View {
        if let model, let app = model.app {
            switch scope {
            case .conversation(let ref):
                ConversationFiles(store: app.shared, chatID: ref,
                                  name: model.graph.chats.chats.first { $0.id == ref }?.name ?? "")
            case .channel(_, let channel):
                ConversationFiles(store: app.shared, chatID: channel,
                                  name: FilesSection.channelName(channel, app.teams.teams))
            case .source:
                if let files = model.provider(.files) as? FilesSection {
                    FilesDetailPane(unified: app.unifiedFiles, library: files.library, transfers: app.transfers,
                                    teams: app.teams, section: files)
                }
            }
        } else {
            EmptyPane("No Files", systemImage: "folder", message: "No files have been shared yet.")
        }
    }
}

/// Files shared in one conversation: the Files table with the folder
/// breadcrumb; Location is the conversation itself (plain text).
private struct ConversationFiles: View {
    @ObservedObject var store: SharedFilesStore
    let chatID: String
    let name: String
    @State private var selection: Set<String> = []
    @Environment(\.windowModel) private var model

    var body: some View {
        let current = store.chatID == chatID
        let items = current
            ? store.files.map {
                FileItem.remote(UnifiedFileRow(file: $0, source: .chat, sourceName: name, sourceID: chatID))
            }
            : []
        let state = current
            ? FilesPaneState.resolve(store.state, count: items.count, forced: nil, forcedOffline: false,
                                     offline: model?.connection == .offline)
            : .loading
        VStack(spacing: 0) {
            if current, !store.crumbs.isEmpty {
                FolderCrumbs(store: store, root: name.isEmpty ? "Files" : name)
                Divider()
            }
            FileTableView(items: state == .files ? items : [], selection: $selection, state: state,
                          emptyMessage: "No files have been shared yet.", canUpload: false,
                          argPrefix: FilesSection.conversationPrefix, linksLocation: false) {
                if model?.options.demo != true { store.refresh() }
            }
        }
    }
}
