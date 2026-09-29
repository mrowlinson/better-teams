// ChatTabsStore.swift — CHATTABS: the tabs at the top of a chat.
//
// Built-in tabs follow the chat kind the way Teams shows them (Chat,
// Shared, Notes on every chat; Recap on meeting chats). Pinned tabs
// (Whiteboard, Q&A, file, website and app tabs) come from Graph
// `GET /chats/{id}/tabs?$expand=teamsApp` (read-only); `ChatTabCatalog`
// classifies each for its icon and how the host shows it.
import Combine
import Foundation

/// Chat kinds whose tab sets differ in Teams.
public enum ChatKind: Equatable, Sendable {
    case oneOnOne, group, meeting, selfChat

    /// `48:` = the self chat; `19:meeting_` = a meeting's chat; 1:1 chat
    /// ids end `@unq.gbl.spaces`; other `19:` threads are groups.
    public static func of(chatID: String, isGroup: Bool) -> ChatKind {
        let id = chatID.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("48:") { return .selfChat }
        if id.hasPrefix("19:meeting_") || DemoChatTabs.meetingChats.contains(id) { return .meeting }
        if id.hasSuffix("@unq.gbl.spaces") { return .oneOnOne }
        return isGroup ? .group : .oneOnOne
    }
}

/// What a pinned chat tab is (icon + host route).
public enum ChatTabKind: Equatable, Sendable {
    case whiteboard, questions, file, website, wiki, app
}

/// How the conversation view shows one pinned tab.
public enum ChatTabRoute: Equatable, Sendable {
    /// The app host's launch entry (catalog manifest match): the host
    /// decides native vs its Teams web page.
    case hosted
    /// An in-app web page: a website tab, or the tab's Teams web page.
    case web(URL)
    /// A native placeholder with "Open in Teams on the web".
    case placeholder
}

public enum ChatTabCatalog {
    static let whiteboardAppID = "95de633a-083e-42f5-b444-a4295d8e9314"
    /// Office/SharePoint document tabs (Word, Excel, PowerPoint, PDF…),
    /// the app id every live chat and channel file tab carries.
    static let officeFileAppID = "1c256a65-83a6-4b5c-9ccf-78f8afb6f1e8"
    static let websiteAppID = "com.microsoft.teamspace.tab.web"
    static let wikiAppID = "com.microsoft.teamspace.tab.wiki"
    static let fileExtensions: Set<String> = [
        "docx", "doc", "xlsx", "xls", "xlsm", "csv", "pptx", "ppt", "pdf", "vsdx", "one", "txt",
    ]

    /// Built-in tabs per chat kind, in Teams order. Notes stays on every
    /// chat (the app's own conversation notes).
    public static func builtins(for kind: ChatKind) -> [String] {
        kind == .meeting ? ["chat", "files", "notes", "recap"] : ["chat", "files", "notes"]
    }

    public static func kind(of t: ChannelTab) -> ChatTabKind {
        let app = t.appID?.lowercased() ?? ""
        let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let appName = t.appName?.lowercased() ?? ""
        if app == whiteboardAppID || appName == "whiteboard" { return .whiteboard }
        if appName == "q&a" || name == "q&a" { return .questions }
        if app == officeFileAppID || app.hasPrefix("com.microsoft.teamspace.tab.file.")
            || fileExtensions.contains(fileExtension(t.name)) { return .file }
        if app == wikiAppID { return .wiki }
        if app == websiteAppID { return .website }
        return .app
    }

    /// SF Symbol for a pinned tab (menus and placeholders).
    public static func symbol(for t: ChannelTab) -> String {
        switch kind(of: t) {
        case .whiteboard: "scribble.variable"
        case .questions: "questionmark.bubble"
        case .website: "globe"
        case .wiki: "text.book.closed"
        case .app: "square.grid.2x2"
        case .file:
            switch fileExtension(t.name) {
            case "xlsx", "xls", "xlsm", "csv": "tablecells"
            case "pptx", "ppt": "rectangle.on.rectangle.angled"
            case "pdf": "doc.richtext"
            default: "doc.text"
            }
        }
    }

    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Route for one pinned tab. Retired wiki tabs are placeholders.
    /// Website tabs load their page; a catalog match (Office file tabs
    /// included) goes to the app host; otherwise the tab's own page (its
    /// content or website address) loads directly. Never the tab's Teams
    /// web page (APPNATIVE4): a tab with no page of its own is a
    /// placeholder that says why.
    public static func route(for t: ChannelTab, hasManifest: Bool) -> ChatTabRoute {
        switch kind(of: t) {
        case .wiki: return .placeholder
        case .website:
            if let u = directURL(t.contentURL) ?? directURL(t.websiteURL) { return .web(u) }
            return .placeholder
        case .file, .whiteboard, .questions, .app:
            if hasManifest, let c = t.contentURL, !isTeamsTemplate(c) { return .hosted }
            if let u = directURL(t.contentURL) ?? directURL(t.websiteURL) { return .web(u) }
            return .placeholder
        }
    }

    /// A tab's own page address: http(s), and not the Teams web app.
    public static func directURL(_ s: String?) -> URL? {
        guard let u = webURL(s), !isTeamsHost(u) else { return nil }
        return u
    }

    public static func webURL(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil
        else { return nil }
        return u
    }

    /// Hosts the Teams web app runs on.
    public static let teamsHosts = ["teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com",
                                    "teams.microsoft.us"]
    /// First path segments of the Teams web app itself (the client, its
    /// deep links and launchers). Apps Microsoft hosts on the same hosts
    /// (Shifts at /shifts-web-app, …) are app pages, not the web app.
    public static let teamsWebRoutes: Set<String> = [
        "", "_", "l", "dl", "v2", "v1", "modern", "go", "multi-window", "meetup-join", "apps",
        "embed", "calendarv2", "join", "evergreen-assets", "?",
    ]

    /// The Teams web app (APPNATIVE4: never loaded in a pane): a Teams
    /// host's root or one of its web-client routes.
    public static func isTeamsWebApp(host: String, path: String) -> Bool {
        guard isTeamsHostName(host.lowercased()) else { return false }
        let first = path.split(separator: "/").first.map { $0.lowercased() } ?? ""
        return teamsWebRoutes.contains(first) || first.hasPrefix("_") || first.hasPrefix("#")
    }

    public static func isTeamsWebApp(_ u: URL) -> Bool {
        isTeamsWebApp(host: u.host ?? "", path: u.path)
    }

    /// A content template (placeholders allowed) that is the Teams web
    /// app: never hosted or loaded (APPNATIVE4).
    public static func isTeamsTemplate(_ s: String) -> Bool {
        guard let r = s.range(of: "://") else { return false }
        let rest = s[r.upperBound...]
        let end = rest.firstIndex { "/?#:{".contains($0) } ?? rest.endIndex
        var tail = rest[end...]
        if tail.hasPrefix(":") { tail = tail.drop { $0 != "/" && $0 != "?" && $0 != "#" } }
        let path = tail.hasPrefix("/") ? String(tail.prefix { $0 != "?" && $0 != "#" }) : ""
        return isTeamsWebApp(host: String(rest[..<end]), path: path)
    }

    static func isTeamsHost(_ u: URL) -> Bool {
        isTeamsWebApp(u)
    }

    static func isTeamsHostName(_ h: String) -> Bool {
        return teamsHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}

/// Pinned tabs per chat. Reopening a chat shows its cached tabs at
/// once and refreshes behind (never clears visibly); a failed fetch
/// keeps what was shown (the row just has no pinned tabs).
@MainActor
public final class ChatTabsStore: ObservableObject {
    public typealias ListFetcher = @Sendable (String) throws -> TabsResponse

    @Published public private(set) var byChat: [String: [ChannelTab]] = [:]
    private let listFetcher: ListFetcher
    private var generation: [String: Int] = [:]

    public nonisolated init(list: @escaping ListFetcher = { try RustCore.chatTabs(chatID: $0) }) {
        self.listFetcher = list
    }

    public func tabs(for chatID: String) -> [ChannelTab] { byChat[chatID] ?? [] }

    /// Only chat threads (`19:` but not channels) carry pinned tabs.
    public nonisolated static func hasTabs(_ chatID: String) -> Bool {
        let id = chatID.trimmingCharacters(in: .whitespaces)
        return id.hasPrefix("19:") && !ChannelTabsStore.isChannelID(id)
    }

    /// Loads one chat's pinned tabs; demo chats get their seeded tabs.
    public func load(chatID: String, demo: Bool) async {
        if demo {
            let seeded = DemoChatTabs.tabs(for: chatID)
            if byChat[chatID] != seeded { byChat[chatID] = seeded }
            return
        }
        guard Self.hasTabs(chatID) else { return }
        let gen = (generation[chatID] ?? 0) + 1
        generation[chatID] = gen
        let fetcher = listFetcher
        guard let resp = try? await Task.blocking(operation: { try fetcher(chatID) }).value,
              generation[chatID] == gen else { return }
        if byChat[chatID] != resp.tabs { byChat[chatID] = resp.tabs }
    }
}

/// Demo pinned tabs (offline).
public enum DemoChatTabs {
    /// Demo chats shown as meeting chats (Recap tab).
    public static let meetingChats: Set<String> = ["demo-3"]

    public static func tabs(for chatID: String) -> [ChannelTab] {
        switch chatID {
        case "demo":
            [
                ChannelTab(id: "demo-tab-wb", name: "Whiteboard", appID: ChatTabCatalog.whiteboardAppID,
                           contentURL: "https://app.whiteboard.microsoft.com/me/whiteboards/demo",
                           appName: "Whiteboard", teamsURL: "https://teams.microsoft.com/l/entity/demo-wb"),
                ChannelTab(id: "demo-tab-board", name: "Sprint Board", appID: ChatTabCatalog.websiteAppID,
                           contentURL: "https://example.com/sprint-board", appName: "Website"),
                ChannelTab(id: "demo-tab-plan", name: "Launch Plan.xlsx", appID: ChatTabCatalog.officeFileAppID,
                           contentURL: "https://www.microsoft365.com/launch-plan",
                           teamsURL: "https://teams.microsoft.com/l/entity/demo-plan"),
                ChannelTab(id: "demo-tab-remind", name: "Reminders", appID: "demo-reminders-app",
                           contentURL: "https://example.com/reminders", appName: "Reminders"),
                ChannelTab(id: "demo-tab-notes", name: "Release Notes.docx", appID: ChatTabCatalog.officeFileAppID,
                           contentURL: "https://www.microsoft365.com/release-notes",
                           teamsURL: "https://teams.microsoft.com/l/entity/demo-notes"),
            ]
        case "demo-3":
            [
                ChannelTab(id: "demo-tab-qa", name: "Q&A", appID: "demo-qa-app",
                           contentURL: "https://example.com/qna", appName: "Q&A",
                           teamsURL: "https://teams.microsoft.com/l/entity/demo-qa"),
                ChannelTab(id: "demo-tab-wb3", name: "Whiteboard", appID: ChatTabCatalog.whiteboardAppID,
                           contentURL: "https://app.whiteboard.microsoft.com/me/whiteboards/demo3",
                           appName: "Whiteboard", teamsURL: "https://teams.microsoft.com/l/entity/demo-wb3"),
            ]
        default: []
        }
    }
}
