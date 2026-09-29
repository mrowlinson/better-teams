// ChatTabs.swift — CHATTABS: the tab row of a chat and its pinned tabs.
//
// Built-ins per chat kind (`ChatTabCatalog.builtins`), then the chat's
// pinned tabs (Graph, read-only), as Teams underline tabs. Tabs that do
// not fit the pane go into a "+N" menu with their icons, as in Teams; the
// selected tab is always visible, and one opened from "+N" shows as a
// temporary tab with a close button (TABS2). A pinned tab opens through the app host's launch
// entry (`FrameHost.registerHostedTab`, the one pinned apps use), as a
// web page, or as a native placeholder with "Open in Teams on the web".
import AppKit
import OstMacCore
import SwiftUI

enum ChatTabKey: Hashable {
    case builtin(ConversationTab)
    case pinned(String)
}

struct ChatTabEntry: Identifiable, Equatable {
    let key: ChatTabKey
    let name: String
    let symbol: String
    var id: String {
        switch key {
        case .builtin(let t): "b:\(t.rawValue)"
        case .pinned(let i): "p:\(i)"
        }
    }
}

/// The row's entries and fold. Pure.
struct ChatTabLayout: Equatable {
    let builtins: [ChatTabEntry]
    let pinned: [ChatTabEntry]
    /// Most pinned tabs shown as segments before "+N".
    static let maxPinnedVisible = 3

    init(kind: ChatKind, tabs: [ChannelTab]) {
        builtins = ChatTabCatalog.builtins(for: kind).compactMap(ConversationTab.init(rawValue:)).map {
            ChatTabEntry(key: .builtin($0), name: $0.title, symbol: Self.symbol($0))
        }
        pinned = tabs.map { ChatTabEntry(key: .pinned($0.id), name: $0.name, symbol: ChatTabCatalog.symbol(for: $0)) }
    }

    static func symbol(_ t: ConversationTab) -> String {
        switch t {
        case .chat: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .notes: "note.text"
        case .recap: "play.rectangle.on.rectangle"
        }
    }

    /// Resolves a stored selection against what this chat shows: a
    /// pinned tab that is gone, or a built-in this kind lacks, is Chat.
    func resolve(builtin: ConversationTab, pinned id: String?) -> ChatTabKey {
        if let id, pinned.contains(where: { $0.key == .pinned(id) }) { return .pinned(id) }
        return builtins.contains(where: { $0.key == .builtin(builtin) }) ? .builtin(builtin) : .builtin(.chat)
    }

    /// Every entry in row order: built-ins, then pinned tabs.
    var all: [ChatTabEntry] { builtins + pinned }

    /// Widest a tab's title runs before it truncates in the middle.
    static let maxTitleWidth: CGFloat = 160

    /// One way to split the row: segments in row order, the rest in "+N".
    struct Fold: Identifiable, Equatable {
        let segments: [ChatTabEntry]
        let more: [ChatTabEntry]
        var id: Int { segments.count }
    }

    /// A pinned tab past the widest fold's pinned tabs. Only these open
    /// as temporary tabs from "+N"; the first `maxPinnedVisible` are
    /// the chat's standing tabs and are just selected.
    func isOverflowPinned(_ key: ChatTabKey) -> Bool {
        guard case .pinned = key, pinned.contains(where: { $0.key == key }) else { return false }
        return !pinned.prefix(Self.maxPinnedVisible).contains { $0.key == key }
    }

    /// The row's folds, widest first; the bar shows the first that fits
    /// (`ChatTabBar`). Every fold keeps the selected tab, then the tab
    /// opened from "+N", as segments; the others fill in row order, and
    /// what does not fit goes into "+N" in row order. The widest fold is
    /// the built-ins plus the first `maxPinnedVisible` pinned tabs; the
    /// last is the selected tab alone, which truncates, so one always fits.
    func folds(selected: ChatTabKey, opened: ChatTabKey?) -> [Fold] {
        let entries = all
        let keys = entries.map(\.key)
        var priority = keys.contains(selected) ? [selected] : []
        if let opened, opened != selected, keys.contains(opened) { priority.append(opened) }
        let order = priority + keys.filter { !priority.contains($0) }
        let natural = Set(builtins.map(\.key) + pinned.prefix(Self.maxPinnedVisible).map(\.key) + priority)
        let widest = max(1, order.prefix { natural.contains($0) }.count)
        return (1...max(1, min(widest, order.count))).reversed().map { n in
            let shown = Set(order.prefix(n))
            return Fold(segments: entries.filter { shown.contains($0.key) }, more: entries.filter { !shown.contains($0.key) })
        }
    }
}

/// The tab row (Teams underline tabs) plus the "+N" overflow menu. The
/// widest fold that fits wins and the last one always fits, so the row
/// never pushes past the pane and reflows as the pane resizes. A pinned
/// tab picked from "+N" opens as a temporary tab with a close button;
/// closing it puts it back in "+N" (Teams).
struct ChatTabBar: View {
    let layout: ChatTabLayout
    @Binding var selection: ChatTabKey
    /// The tab opened from "+N", shown with a close button.
    let opened: ChatTabKey?
    let open: (ChatTabKey) -> Void
    let close: () -> Void

    /// The opened tab, while it is one that shows as temporary.
    private var temporary: ChatTabKey? {
        opened.flatMap { layout.isOverflowPinned($0) ? $0 : nil }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(layout.folds(selected: selection, opened: temporary)) { fold in
                row(fold)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func row(_ fold: ChatTabLayout.Fold) -> some View {
        HStack(spacing: 16) {
            ForEach(fold.segments) { e in
                ChatTabItem(entry: e, on: e.key == selection, closable: e.key == temporary,
                            select: { selection = e.key }, close: close)
            }
            if !fold.more.isEmpty {
                Menu {
                    ForEach(fold.more) { e in
                        Button { pick(e.key) } label: { Label(e.name, systemImage: e.symbol) }
                    }
                } label: {
                    Text("+\(fold.more.count)")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("More Tabs")
                .accessibilityLabel("\(fold.more.count) More Tabs")
            }
        }
    }

    /// A pinned tab past the standing ones opens from "+N" as a temporary
    /// tab; a built-in or standing tab there (narrow panes) is just selected.
    private func pick(_ key: ChatTabKey) {
        if layout.isOverflowPinned(key) { open(key) } else { selection = key }
    }
}

/// One underline tab: icon for pinned tabs, title truncated in the middle
/// (file names keep their extension) with the full name as its tooltip,
/// and a close button on a tab opened from "+N".
private struct ChatTabItem: View {
    let entry: ChatTabEntry
    let on: Bool
    let closable: Bool
    let select: () -> Void
    let close: () -> Void
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 5) {
                    if case .pinned = entry.key {
                        Image(systemName: entry.symbol).imageScale(.small)
                    }
                    WidthCap(limit: ChatTabLayout.maxTitleWidth) {
                        Text(entry.name)
                            .font(on ? AppFont.bodyEmphasized(scale) : AppFont.body(scale))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .foregroundStyle(on ? Palette.mention : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.name)
            .accessibilityLabel(entry.name)
            .accessibilityAddTraits(on ? .isSelected : [])
            if closable {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close \(entry.name)")
                .accessibilityLabel("Close \(entry.name)")
            }
        }
        // The bar under the selected tab takes the label's width and
        // never sizes the tab itself.
        .padding(.bottom, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(on ? Palette.mention : Color.clear)
                .frame(height: 2)
        }
    }
}

/// Offers its content at most `limit` wide and takes the content's own
/// width (a `.frame(maxWidth:)` would grow to the limit).
private struct WidthCap: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// One pinned tab's pane.
struct ChatPinnedTabPane: View {
    let tab: ChannelTab
    let chatID: String
    @Environment(\.windowModel) private var model

    var body: some View {
        if let m = model {
            let launch = Self.launch(tab, store: m.frameHost.library.store, chatID: chatID)
            switch ChatTabCatalog.route(for: tab, hasManifest: launch != nil) {
            case .hosted:
                if let launch { hosted(launch, m) } else { placeholder }
            case .web(let url): web(url, m)
            case .placeholder: placeholder
            }
        }
    }

    private var key: FrameKey { .tab("chat-\(tab.id)") }

    private func hosted(_ l: TeamsAppLaunch, _ m: WindowModel) -> some View {
        m.frameHost.registerHostedTab(key, launch: l, title: tab.name)
        return FrameContainer(key: key)
    }

    private func web(_ url: URL, _ m: WindowModel) -> some View {
        m.frameHost.registerTab(key, url: url, title: tab.name)
        return FrameContainer(key: key)
    }

    private var placeholder: some View {
        let wiki = ChatTabCatalog.kind(of: tab) == .wiki
        return ChatTabPlaceholder(
            title: tab.name, symbol: ChatTabCatalog.symbol(for: tab),
            message: wiki ? "Microsoft retired wiki tabs, so this tab has no pages to show."
                : "This tab has no page of its own to show here: Teams saved no address for it.")
    }

    /// Launch for a pinned chat tab through the app host: a catalog
    /// manifest match, else the tab's own content page (demo: the local
    /// sample page), no channel context. Nil = nothing to host.
    static func launch(_ t: ChannelTab, store: AppStoreModel, chatID: String) -> TeamsAppLaunch? {
        guard let content = t.contentURL, URL(string: content) != nil else { return nil }
        if store.demo {
            return TeamsAppLaunch(appID: t.appID ?? t.id, entityID: t.entityID ?? t.id, contentTemplate: content,
                                  demoHTML: DemoTeamsJSApp.html(title: t.name))
        }
        // No catalog match: the tab's own content page, same host
        // (APPNATIVE4: never the Teams web app).
        let m = store.app(forTab: t)
        guard m != nil || AppStoreModel.hostableTabPage(content) else { return nil }
        var domains = m?.validDomains ?? []
        if let h = AppStoreModel.templateHost(content), !domains.contains(where: { AppStoreModel.domain($0, matches: h) }) {
            domains.append(h)
        }
        return TeamsAppLaunch(appID: m?.id ?? t.appID ?? t.id, entityID: t.entityID ?? t.id, contentTemplate: content,
                              resource: m?.webApplicationInfo?.resource, webAppID: m?.webApplicationInfo?.id,
                              validDomains: domains, website: t.websiteURL)
    }
}

/// Themed native stand-in for a tab with nothing to show in-window (no
/// Teams web page: APPNATIVE4).
struct ChatTabPlaceholder: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        EmptyPane(title, systemImage: symbol, message: message)
    }
}
