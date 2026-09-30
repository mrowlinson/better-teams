// ChatTabs.swift — CHATTABS: the tab row of a chat and its pinned tabs.
//
// Built-ins per chat kind (`ChatTabCatalog.builtins`), then the chat's
// pinned tabs (Graph, read-only), as a native segmented control (system
// accent on the selected segment; pinned segments show their symbol
// beside the title). Tabs that do not fit the pane go into
// a "More" pull-down with their icons; the selected tab is always a
// segment, and one opened from "More" shows as a temporary tab that the
// menu's "Close" item dismisses (TABS2). A pinned tab opens through the app host's launch
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
    /// Most pinned tabs shown as segments before "More".
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

    /// Longest segment title, in characters, before it truncates in the middle.
    static let maxSegmentTitle = 24
    /// The last-resort row's title length: a narrow pane keeps the
    /// selected tab as one short segment beside "More".
    static let compactSegmentTitle = 14

    /// A tab name as a segment title: names past `maxSegmentTitle`
    /// characters truncate in the middle with "\u{2026}", keeping a file
    /// extension (".docx") intact at the end. Pure.
    static func segmentTitle(_ name: String, limit: Int = maxSegmentTitle) -> String {
        guard name.count > limit else { return name }
        var stem = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let tail = name[dot...]
            if (2...6).contains(tail.count), tail.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) {
                stem = String(name[..<dot])
                ext = String(tail)
            }
        }
        let room = max(2, limit - ext.count - 1)
        let tailCount = room / 3
        return String(stem.prefix(room - tailCount)) + "\u{2026}" + String(stem.suffix(tailCount)) + ext
    }

    /// The "More" menu shows when tabs overflow, or when a temporary tab
    /// is open (its "Close" item lives there: no close button inside a segment).
    static func showsMore(fold: Fold, temporary: ChatTabKey?) -> Bool {
        !fold.more.isEmpty || temporary != nil
    }

    /// One way to split the row: segments in row order, the rest in "More".
    struct Fold: Identifiable, Equatable {
        let segments: [ChatTabEntry]
        let more: [ChatTabEntry]
        var id: Int { segments.count }
    }

    /// A pinned tab past the widest fold's pinned tabs. Only these open
    /// as temporary tabs from "More"; the first `maxPinnedVisible` are
    /// the chat's standing tabs and are just selected.
    func isOverflowPinned(_ key: ChatTabKey) -> Bool {
        guard case .pinned = key, pinned.contains(where: { $0.key == key }) else { return false }
        return !pinned.prefix(Self.maxPinnedVisible).contains { $0.key == key }
    }

    /// The row's folds, widest first; the bar shows the first that fits
    /// (`ChatTabBar`). Every fold keeps the selected tab, then the tab
    /// opened from "More", as segments; the others fill in row order, and
    /// what does not fit goes into "More" in row order. The widest fold is
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

/// The tab row: a native segmented control plus a "More" pull-down for
/// the overflow. The widest fold that fits wins and the last one always
/// fits, so the row never pushes past the pane and reflows as the pane
/// resizes. A pinned tab picked from "More" opens as a temporary tab;
/// the menu's "Close" item closes it and puts it back in the menu.
struct ChatTabBar: View {
    let layout: ChatTabLayout
    @Binding var selection: ChatTabKey
    /// The tab opened from "More", shown as a temporary tab.
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
                row(fold, limit: ChatTabLayout.maxSegmentTitle)
            }
            // Last resort in a narrow pane: the selected tab alone, shorter.
            if let narrowest = layout.folds(selected: selection, opened: temporary).last {
                row(narrowest, limit: ChatTabLayout.compactSegmentTitle)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    private func name(of key: ChatTabKey?) -> String? {
        key.flatMap { k in layout.all.first { $0.key == k }?.name }
    }

    private func row(_ fold: ChatTabLayout.Fold, limit: Int) -> some View {
        HStack(spacing: 8) {
            ChatTabSegments(
                segments: fold.segments.map { e in
                    let pinned: Bool = if case .pinned = e.key { true } else { false }
                    return .init(title: ChatTabLayout.segmentTitle(e.name, limit: limit),
                                 symbol: pinned ? e.symbol : nil, help: e.name)
                },
                selected: fold.segments.firstIndex { $0.key == selection },
                pick: { i in if fold.segments.indices.contains(i) { selection = fold.segments[i].key } })
            .accessibilityLabel("Tabs")
            if ChatTabLayout.showsMore(fold: fold, temporary: temporary) {
                Menu {
                    ForEach(fold.more) { e in
                        Button { pick(e.key) } label: { Label(e.name, systemImage: e.symbol) }
                    }
                    if let temporary, let title = name(of: temporary) {
                        if !fold.more.isEmpty { Divider() }
                        Button("Close \(title)", action: close)
                    }
                } label: {
                    Text("More")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("More Tabs")
                .accessibilityLabel(fold.more.isEmpty ? "More Tabs" : "\(fold.more.count) More Tabs")
            }
        }
    }

    /// A pinned tab past the standing ones opens from "More" as a temporary
    /// tab; a built-in or standing tab there (narrow panes) is just selected.
    private func pick(_ key: ChatTabKey) {
        if layout.isOverflowPinned(key) { open(key) } else { selection = key }
    }
}

/// The tab row's NSSegmentedControl. AppKit directly because SwiftUI's
/// segmented Picker drops a Label's image on macOS, and a pinned tab's
/// segment shows its symbol beside the title (image + label per segment).
/// Sized to its content, like the fixed-size Picker it replaces, so
/// ViewThatFits can fold the row.
struct ChatTabSegments: NSViewRepresentable {
    struct Segment: Equatable {
        let title: String
        let symbol: String?
        /// Full tab name (titles are truncated): the segment's tooltip.
        let help: String
    }

    let segments: [Segment]
    let selected: Int?
    let pick: (Int) -> Void

    final class Coordinator: NSObject {
        var pick: (Int) -> Void = { _ in }
        var shown: [Segment] = []
        @objc func changed(_ sender: NSSegmentedControl) { pick(sender.selectedSegment) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fit
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.pick = pick
        if context.coordinator.shown != segments {
            control.segmentCount = segments.count
            for (i, s) in segments.enumerated() {
                control.setLabel(s.title, forSegment: i)
                control.setImage(s.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) },
                                 forSegment: i)
                control.setImageScaling(.scaleProportionallyDown, forSegment: i)
                control.setToolTip(s.help, forSegment: i)
                control.setWidth(0, forSegment: i)
            }
            context.coordinator.shown = segments
            control.invalidateIntrinsicContentSize()
        }
        control.selectedSegment = selected ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
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
