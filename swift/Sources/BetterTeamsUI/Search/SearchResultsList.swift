// SearchResultsList.swift — search-mode list pane (UI-SPEC §5.5).
//
// Scope bar (All | Messages | People | Files, plus the ⌘F conversation
// when scoped) over one inset List: Top Hits (local fuzzy match over
// chats, channels, teams), Messages (server hits online, the offline
// index offline; "On This Mac" badge on interim indexed hits while the
// server window loads), People, Files.
// Selection goes through SearchModel; results come straight from the
// core stores (R3, R28).
import AppKit
import OstMacCore
import SwiftUI
import UniformTypeIdentifiers

struct SearchResultsList: View {
    @Environment(\.windowModel) private var model

    var body: some View {
        if let model, let app = model.app {
            SearchResultsContent(search: model.search, messages: app.messageSearch, local: app.localSearch,
                                 filePeople: app.filePeople, chats: model.graph.chats, presence: app.presence)
        } else {
            EmptyPane("Search Unavailable", systemImage: "magnifyingglass",
                      message: "Search this account from its own window.")
        }
    }
}

private struct SearchResultsContent: View {
    let search: SearchModel
    @ObservedObject var messages: MessageSearchStore
    @ObservedObject var local: LocalSearchStore
    @ObservedObject var filePeople: FilePeopleSearchStore
    @ObservedObject var chats: ChatListViewModel
    @ObservedObject var presence: PresenceStore
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            SearchScopeBar(search: search)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var offline: Bool { model?.connection == .offline }

    private var loading: Bool {
        offline ? local.isSearching : (messages.isSearching || filePeople.isSearching)
    }

    @ViewBuilder
    private var results: some View {
        let rows = search.rows()
        let empty = rows.topHits.isEmpty && rows.messages.isEmpty && rows.people.isEmpty && rows.files.isEmpty
        if empty && loading {
            LoadingPane("Searching\u{2026}")
        } else if empty, let err = messages.error, !offline, search.scope != .people, search.scope != .files {
            ErrorPane(title: "Couldn't Search Messages", message: err) { messages.retry() }
        } else if empty {
            ContentUnavailableView.search(text: search.query)
        } else {
            list(rows)
        }
    }

    private func list(_ rows: SearchModel.Rows) -> some View {
        let online = messages.onlineIDs
        let now = RelativeClock.shared.now
        // Under a single scope the scope bar already names the section;
        // a same-named header would repeat it (only the offline source
        // note stays).
        let headers = search.scope == .all && !search.inConversation
        let selection = Binding<String?>(
            get: { search.selected?.tag },
            set: { search.select($0.flatMap(SearchResultID.init(tag:))) })
        return List(selection: selection) {
            if !rows.topHits.isEmpty {
                section(headers ? "Top Hits" : nil) {
                    ForEach(rows.topHits) { t in
                        SearchTargetRow(target: t).tag(SearchResultID.target(t.id).tag)
                    }
                }
            }
            if !rows.messages.isEmpty {
                section(headers ? (offline ? "Messages \u{2014} On This Mac" : "Messages")
                        : (offline ? "On This Mac" : nil)) {
                    ForEach(rows.messages) { h in
                        // Online: badge the interim hits only the on-device
                        // index found. Offline: every hit is local; the header
                        // says so. ⌘F find: every hit is this conversation's.
                        SearchMessageRow(hit: h, place: placeName(h),
                                         onThisMac: !offline && !search.inConversation && !online.contains(h.id),
                                         now: now)
                            .tag(SearchResultID.message(h.id).tag)
                    }
                    if !offline, messages.isSearching {
                        // The local hits are listed; the server window is
                        // still on its way (merged when it lands).
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Searching online\u{2026}")
                                .font(AppFont.subheadline(scale))
                                .foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                    } else if search.scope == .messages || search.inConversation, !offline, messages.canLoadMore {
                        Button("Show More Results") { Task { await messages.loadMore() } }
                            .buttonStyle(.link)
                    }
                }
            }
            if !rows.people.isEmpty {
                section(headers ? "People" : nil) {
                    ForEach(rows.people) { p in
                        SearchPersonRow(person: p,
                                        presence: PeerPresence.status(presence, chatID: nil, userID: p.userId ?? p.id))
                            .tag(SearchResultID.person(p.id).tag)
                    }
                }
            }
            if !rows.files.isEmpty {
                section(headers ? "Files" : nil) {
                    ForEach(rows.files) { f in
                        SearchFileRow(file: f, now: now).tag(SearchResultID.file(f.id).tag)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { tags in
            if let id = tags.first.flatMap(SearchResultID.init(tag:)) {
                Button("Open") { search.activate(id) }
            }
        } primaryAction: { tags in
            search.activate(tags.first.flatMap(SearchResultID.init(tag:)))
        }
    }

    /// Every result section is built the same way, so Top Hits,
    /// Messages, People and Files match: the title is a plain,
    /// unselectable header row inside the section, not a `Section`
    /// header. List section headers are table group rows, and the first
    /// one (floating at the top) drew a full-width rule while the others
    /// drew inset rules.
    @ViewBuilder
    private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        Section {
            if let title {
                Text(title)
                    .font(AppFont.subheadline(scale).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
        }
        .listSectionSeparator(.hidden)
    }

    private func placeName(_ h: SearchHit) -> String {
        model?.app?.chatNameOrNil(for: h.chatID) ?? DemoData.name(for: h.chatID) ?? "Conversation"
    }
}

/// Segmented scope bar (§5.5 "Default to a broader scope"). With a ⌘F
/// conversation scope, that conversation is the leading segment
/// (Mail's "Search: All Mailboxes | Inbox" pattern). Segments never
/// shrink below their labels, so the bar takes the first that fits the
/// list pane: small segments (four scopes need 292 pt), mini segments
/// (240 pt: the default 300 pt pane), else the same choices in a pop-up
/// menu (the fifth, conversation segment needs 372 pt even at mini).
/// Nothing is clipped and every scope stays reachable.
struct SearchScopeBar: View {
    let search: SearchModel

    private enum Choice: Hashable {
        case conversation
        case scope(SearchScope)
    }

    var body: some View {
        let binding = Binding<Choice>(
            get: { search.inConversation ? .conversation : .scope(search.scope) },
            set: { c in
                switch c {
                case .conversation: search.setConversationScopeActive()
                case .scope(let s): search.setScope(s)
                }
            })
        ViewThatFits(in: .horizontal) {
            picker(binding)
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            picker(binding)
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
            picker(binding)
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private func picker(_ binding: Binding<Choice>) -> some View {
        Picker("Search Scope", selection: binding) {
            if let c = search.conversation {
                Text(c.name.count > 14 ? String(c.name.prefix(13)) + "\u{2026}" : c.name).tag(Choice.conversation)
            }
            ForEach(SearchScope.allCases, id: \.rawValue) { s in
                Text(s.title).tag(Choice.scope(s))
            }
        }
    }
}

extension SearchScope {
    var title: String {
        switch self {
        case .all: "All"
        case .messages: "Messages"
        case .people: "People"
        case .files: "Files"
        }
    }
}

// MARK: rows (R13: fixed slots; R5: lazy List)

struct SearchTargetRow: View {
    let target: JumpTarget
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            switch target.kind {
            case .channel, .team:
                Image(systemName: target.kind == .team ? "person.3" : "number")
                    .font(AppFont.body(scale))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            default:
                Avatar(name: target.title, isGroup: target.kind == .chat)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Channel titles carry "#"; the leading symbol already says it.
                Text(target.kind == .channel && target.title.hasPrefix("#") ? String(target.title.dropFirst()) : target.title)
                    .font(AppFont.body(scale)).lineLimit(1)
                Text(target.subtitle).font(AppFont.subheadline(scale)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct SearchMessageRow: View {
    let hit: SearchHit
    let place: String
    /// Found only by the on-device index (online search).
    let onThisMac: Bool
    let now: Date
    @Environment(\.contentTextScale) private var scale

    /// A 1:1 chat is named after the sender: the title already says it.
    private var showsPlace: Bool { !place.isEmpty && place != hit.sender }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(name: hit.sender.isEmpty ? place : hit.sender)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(hit.sender.isEmpty ? place : hit.sender)
                        .font(AppFont.bodyEmphasized(scale))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ChatListFormat.previewTime(hit.timestamp, now: now))
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                // Up to two lines; a one-line message takes one line.
                Text(hit.preview)
                    .font(AppFont.subheadline(scale))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if showsPlace || onThisMac {
                    HStack(spacing: 6) {
                        if showsPlace {
                            Text(place)
                                .font(AppFont.caption(scale))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if onThisMac {
                            Label("On This Mac", systemImage: "internaldrive")
                                .font(AppFont.caption(scale))
                                .foregroundStyle(.secondary)
                                .labelStyle(.titleAndIcon)
                                .fixedSize()
                                .help("Found in messages saved on this Mac")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct SearchPersonRow: View {
    let person: TeamMember
    let presence: PresenceStatus?
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            // Presence = shape + color on the avatar corner (§6, §10).
            Avatar(name: person.displayName)
                .overlay(alignment: .bottomTrailing) {
                    // 4 pt out: at 2 pt the ring clipped the monogram's
                    // trailing letter ("AL").
                    if let presence { PresenceBadge(status: presence).offset(x: 4, y: 4) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName).font(AppFont.body(scale)).lineLimit(1)
                if let email = person.email, !email.isEmpty {
                    Text(email).font(AppFont.subheadline(scale)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presence.map { "\(person.displayName), \(PeerPresence.label($0))" } ?? person.displayName)
    }
}

struct SearchFileRow: View {
    let file: SharedFile
    let now: Date
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(file: file, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(file.name).font(AppFont.body(scale)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(ChatListFormat.previewTime(file.modified ?? file.created, now: now))
                        .font(AppFont.caption(scale))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Text(Self.rowLine(file))
                    .font(AppFont.subheadline(scale)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Row line 2: where it was shared · who shared it (size when
    /// neither is known). A 1:1 chat is named after the person, so the
    /// place is dropped when it only repeats the sender.
    static func rowLine(_ f: SharedFile) -> String {
        let parts = [sharedPlace(f), f.sender].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? f.sizeLabel : parts.joined(separator: " \u{00B7} ")
    }

    /// Where it was shared, nil when unknown or the same as the sender.
    private static func sharedPlace(_ f: SharedFile) -> String? {
        guard let p = f.source_name, !p.isEmpty, p != f.sender else { return nil }
        return p
    }

    /// Card line: "Shared by ‹who› in ‹where›" (nil when neither known).
    static func sharedLine(_ f: SharedFile) -> String? {
        let who = f.sender.flatMap { $0.isEmpty ? nil : $0 }
        let place = sharedPlace(f)
        switch (who, place) {
        case let (w?, p?): return "Shared by \(w) in \(p)"
        case let (w?, nil): return "Shared by \(w)"
        case let (nil, p?): return "Shared in \(p)"
        default: return nil
        }
    }

    /// Card line: date · size.
    static func dateAndSize(_ f: SharedFile, now: Date) -> String {
        let date = ChatListFormat.previewTime(f.modified ?? f.created, now: now)
        return date.isEmpty ? f.sizeLabel : "\(date) \u{00B7} \(f.sizeLabel)"
    }
}

/// The system's icon for a file's type (Finder's icon): the MIME type
/// first, then the name's extension.
struct FileIcon: View {
    let file: SharedFile
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: Self.type(file)))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func type(_ f: SharedFile) -> UTType {
        if let m = f.mime, let t = UTType(mimeType: m), !t.isDynamic { return t }
        let ext = (f.name as NSString).pathExtension
        if let t = UTType(filenameExtension: ext), !t.isDynamic { return t }
        return .data
    }
}
