// TimelineViewController.swift — the conversation timeline, an AppKit
// island (UI-SPEC §6.2.1, DL4).
//
// NSScrollView + view-based NSTableView: one column, no header, no
// selection highlight, no focus ring. Rows are reused cells hosting
// SwiftUI through `Hosting` (R22). Row heights are explicit
// (`usesAutomaticRowHeights = false`) and come from `RowHeightCache`,
// measured once per (id, revision, width, scale) with an off-screen
// sizing host. Updates diff by item ID into insert/remove/reload with
// no animation, and `ScrollAnchor` restores the scroll position in the
// same pass. Width changes re-measure once, at the end of live resize.
import AppKit
import Combine
import OstMacCore
import SwiftUI

/// One row's SwiftUI content.
struct TimelineRowContent: View {
    let item: TimelineItem
    let row: MessageRowData?
    let highlighted: Bool
    let staticHighlight: Bool
    let actions: TimelineActions?
    /// On screen the row fills its cell (explicit height) with content
    /// at the top; the off-screen sizer measures the bare content.
    var fills = false
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        if fills {
            rowBody.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            rowBody
        }
    }

    @ViewBuilder
    private var rowBody: some View {
        switch item {
        case .daySeparator(_, let label):
            HStack(spacing: 8) {
                Palette.dayRule.frame(height: 1)
                Text(label).font(AppFont.caption(scale)).foregroundStyle(.secondary).fixedSize()
                Palette.dayRule.frame(height: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        case .newMessagesDivider:
            HStack(spacing: 8) {
                VStack { Divider().overlay(Palette.newMessages) }
                Text("New Messages").font(AppFont.caption(scale)).foregroundStyle(Palette.failed).fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        case .message:
            if let row {
                MessageRowView(row: row, highlighted: highlighted, staticHighlight: staticHighlight,
                               actions: actions)
            }
        case .typing:
            // The composer's reserved status line shows typing (§6.2.2).
            Color.clear.frame(height: 1)
        case .threadSummary(let root, let replies, let last):
            ThreadSummaryRow(rootID: root, replies: replies, lastReply: last) // P2c, Sections/Teams
        }
    }
}

/// "Jump to latest" overlay (§6.2.1): bottom-trailing, with the count of
/// messages that arrived while scrolled away.
struct JumpToLatestButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down.circle.fill")
                if count > 0 { Text("\(count)").monospacedDigit() }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help("Jump to Latest")
        .accessibilityLabel(count > 0 ? "Jump to latest, \(count) new" : "Jump to latest")
        .padding(12)
    }
}

@MainActor
private final class TimelineCell: NSTableCellView {
    let host: NSHostingView<HostedRoot<TimelineRowContent>>
    /// Row 0 of a short thread sits below `topSlack` (bottom-anchored
    /// thread); every other row keeps 0.
    private(set) var top: NSLayoutConstraint!

    /// The host fills the cell (all four edges, no intrinsic size): the
    /// row height is the measured height, so SwiftUI lays the row out at
    /// exactly the size it was measured at, whatever the column width.
    init(content: TimelineRowContent, model: WindowModel?) {
        host = Hosting.view(content, role: .row, model: model)
        super.init(frame: .zero)
        identifier = TimelineViewController.cellID
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        top = host.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            top,
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
}

@MainActor
final class TimelineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSPopoverDelegate
{
    static let cellID = NSUserInterfaceItemIdentifier("TimelineCell")

    private let conv: ConversationStore
    /// Chats, channel Posts, or one channel thread (P2c, §6.3).
    private var scope: TimelineScope
    private weak var model: WindowModel?
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var items: [TimelineItem] = []
    private var messagesByID: [String: ChatMessage] = [:]
    private var rowData: [String: MessageRowData] = [:]
    /// File chips: the conversation's shared files by `attachment_id`,
    /// accumulated while its Files list loads or drills (a folder view
    /// never drops a chip), reset when the conversation changes.
    private var docIndex: [String: SharedFile] = [:]
    private var docChatID: String?
    private var failed: Set<String> = []
    private var chatID: String?
    private let heights = RowHeightCache()
    private var measureWidth: CGFloat = 0
    private lazy var sizer = Hosting.controller(
        TimelineRowContent(item: .typing, row: nil, highlighted: false, staticHighlight: true, actions: nil),
        role: .cell, model: model)
    private var highlightID: String?
    /// The message an open reaction picker or delete alert acts on
    /// (static highlight while it is up, §9.5 "anchored to its control").
    private var markedID: String?
    private var alertTargetID: String?
    private var reactionTargetID: String?
    /// The message the composer is editing (§6.2.2): marked while the
    /// edit chip is up, so the timeline shows which message changes.
    private var editTargetID: String?
    private var reactionPopover: NSPopover?
    private var pendingReactionID: String?
    private var pendingJump: String?
    private var cancellables = Set<AnyCancellable>()
    private let staticHighlight: Bool

    private let services: ConversationServices?
    private let actions: TimelineActions?
    private let container = NSView()
    private var jumpHost: NSHostingView<HostedRoot<JumpToLatestButton>>?
    /// The scroll view's bottom: raised by the Jump to Latest strip while
    /// the button shows, so the button never covers a message (§6.2.1).
    private var scrollBottom: NSLayoutConstraint?
    private var pinnedToBottom = true
    private var lastClipSize: NSSize = .zero
    private var newWhileAway = 0
    /// Short threads sit on the composer (chat convention): the space
    /// above them is added to row 0's height, and the scroll view gets
    /// no insets, so nothing scrolls and no scroller shows.
    private var topSlack: CGFloat = 0
    private static let overflowInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
    private static let fitBottomGap: CGFloat = 8

    init(conv: ConversationStore, model: WindowModel?, scope: TimelineScope = .conversation) {
        self.conv = conv
        self.scope = scope
        self.model = model
        staticHighlight = model?.options.evidence ?? false
        services = model.map(ConversationServices.of)
        actions = services.map { TimelineActions(conv: conv, model: model, services: $0) }
        super.init(nibName: nil, bundle: nil)
        actions?.jumpHandler = { [weak self] id in self?.jump(to: id) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.focusRingType = .none // §10
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.gridStyleMask = []
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // No scroller track when the content fits (legacy scroller style).
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = Self.overflowInsets
        scroll.focusRingType = .none
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        let jumpView = Hosting.view(JumpToLatestButton(count: 0) { [weak self] in self?.jumpToLatest() },
                                    role: .cell, model: model)
        jumpView.translatesAutoresizingMaskIntoConstraints = false
        jumpView.isHidden = true
        container.addSubview(jumpView)
        jumpHost = jumpView
        let bottom = scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        scrollBottom = bottom
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            bottom,
            jumpView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            jumpView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // @Published fires in willSet: use the delivered values.
        conv.$messages
            .sink { [weak self] msgs in self?.apply(messages: msgs) }
            .store(in: &cancellables)
        conv.$failedIDs
            .sink { [weak self] ids in
                guard let self, ids != self.failed else { return }
                self.failed = ids
                self.apply(messages: self.conv.messages)
            }
            .store(in: &cancellables)
        conv.$jumpTargetID
            .compactMap { $0 }
            .sink { [weak self] id in self?.jump(to: id) }
            .store(in: &cancellables)
        // Row-state stores (receipts, translation, pins, saves): their
        // @Published fires in willSet, so rows rebuild on the next turn
        // from the stored values; only changed rows reload.
        var side: [AnyPublisher<Void, Never>] = []
        if let t = services?.translation { side.append(t.$entries.map { _ in () }.eraseToAnyPublisher()) }
        if let r = model?.app?.receipts { side.append(r.$map.map { _ in () }.eraseToAnyPublisher()) }
        if let g = model?.graph {
            side.append(g.pinnedMessages.$map.map { _ in () }.eraseToAnyPublisher())
            side.append(g.savedMessages.$saves.map { _ in () }.eraseToAnyPublisher())
        }
        // File chips resolve against the conversation's shared files
        // (loaded with the conversation): delivered value, own chat only.
        if let shared = model?.app?.shared {
            if noteSharedFiles(shared.files, chat: shared.chatID) { apply(messages: conv.messages) }
            side.append(shared.$files
                .compactMap { [weak self, weak shared] files -> Void? in
                    guard let self, let shared else { return nil }
                    return self.noteSharedFiles(files, chat: shared.chatID) ? () : nil
                }
                .eraseToAnyPublisher())
            // Refs past the first page: files looked up by message.
            side.append(shared.$attachmentFiles
                .compactMap { [weak self, weak shared] files -> Void? in
                    guard let self, let shared else { return nil }
                    return self.noteSharedFiles(files, chat: shared.attachmentsChatID) ? () : nil
                }
                .eraseToAnyPublisher())
            // The first page landed for this conversation: unmatched refs
            // can now be looked up.
            side.append(shared.$state
                .compactMap { [weak self, weak shared] state -> Void? in
                    guard let self, let shared, state != .loading, shared.chatID == self.conv.chatID else { return nil }
                    return ()
                }
                .eraseToAnyPublisher())
        }
        Publishers.MergeMany(side)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.apply(messages: self.conv.messages)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in self?.scrolled() }
            .store(in: &cancellables)
        scroll.contentView.postsBoundsChangedNotifications = true
        // The viewport resized (window, composer growth, first layout):
        // bounds notifications do not fire for frame-driven changes, so
        // re-fit and keep a pinned timeline on its newest row.
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in self?.viewportChanged() }
            .store(in: &cancellables)
        // Programmatic width changes (window placement, pane collapse,
        // inspector toggle) re-measure once; live resize waits for its end.
        table.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: table)
            .sink { [weak self] _ in
                guard let self, !self.view.inLiveResize else { return }
                self.widthSettled()
                if self.pinnedToBottom { self.scrollToBottom() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)
            .sink { [weak self] note in self?.liveResizeEnded(note) }
            .store(in: &cancellables)
        // Reaction More… opens at its message; Delete… marks its message
        // while the alert is up. Delivered values (willSet publishers).
        if let composer = services?.composer {
            composer.register(timeline: self)
            composer.$popover
                .sink { [weak self] p in self?.popoverChanged(p) }
                .store(in: &cancellables)
            composer.$markedMessageID
                .sink { [weak self] id in
                    self?.alertTargetID = id
                    self?.updateMarked()
                }
                .store(in: &cancellables)
            composer.$editing
                .sink { [weak self] m in
                    self?.editTargetID = m?.id
                    self?.updateMarked()
                }
                .store(in: &cancellables)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        retryPendingReaction()
    }

    // MARK: reaction picker + marked row

    private func popoverChanged(_ p: ComposerPopover?) {
        if case .reaction(let id)? = p {
            pendingReactionID = id
            // Next turn: the store's willSet is still running.
            DispatchQueue.main.async { [weak self] in self?.retryPendingReaction() }
        } else {
            pendingReactionID = nil
            reactionTargetID = nil
            if let pop = reactionPopover {
                reactionPopover = nil
                pop.close()
            }
            updateMarked()
        }
    }

    /// Shows the reaction picker anchored at its message (stock
    /// `NSPopover`, transient), once the row and the window exist.
    private func retryPendingReaction() {
        guard let id = pendingReactionID, reactionPopover == nil, isViewLoaded,
              let window = view.window, window.isVisible,
              let i = items.firstIndex(where: { $0.messageID == id }) else { return }
        pendingReactionID = nil
        guard isReactionPresenter(for: id) else { return }
        reactionTargetID = id
        updateMarked()
        let visible = table.rows(in: scroll.contentView.bounds)
        if !(visible.location..<(visible.location + visible.length)).contains(i) { restore(.jump(id: items[i].id)) }
        let picker = ReactionPicker { [weak self] emoji in
            guard let self else { return }
            self.conv.react(messageID: id, emoji: emoji)
            self.services?.composer.popover = nil
        }
        let pop = NSPopover()
        pop.contentViewController = Hosting.controller(picker, role: .popover, model: model)
        pop.behavior = .transient
        pop.delegate = self
        reactionPopover = pop
        // The message column: past the avatar gutter, over the text;
        // own chat messages sit trailing, so their anchor does too.
        let r = table.rect(ofRow: i)
        let lead: CGFloat = 54
        let w = max(1, min(240, r.width - lead - 56))
        let trailing = scope == .conversation && (messagesByID[id]?.isOwn ?? false)
        var anchor = NSRect(x: trailing ? r.maxX - 16 - w : r.minX + lead, y: r.minY, width: w,
                            height: r.height)
        // The popover centers on its anchor: narrow the anchor to a point
        // whose x keeps the whole popover inside the window (8 pt margin),
        // so a trailing own message never pushes it past the edge.
        let popWidth = pop.contentViewController?.view.fittingSize.width ?? 0
        if let content = window.contentView, popWidth > 0 {
            let inWindow = table.convert(anchor, to: content)
            let x = Self.popoverAnchorX(preferred: inWindow.midX, popoverWidth: popWidth,
                                        windowWidth: content.bounds.width)
            let local = table.convert(NSPoint(x: x, y: inWindow.midY), from: content)
            anchor = NSRect(x: local.x, y: r.minY, width: 1, height: r.height)
        }
        pop.show(relativeTo: anchor, of: table, preferredEdge: .minY)
    }

    /// Anchor x (window coordinates) for a popover of `popoverWidth`
    /// centered on it: `preferred`, clamped so the popover stays 8 pt
    /// inside both window edges (centered when the window is narrower).
    static func popoverAnchorX(preferred: CGFloat, popoverWidth: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let half = popoverWidth / 2 + 8
        guard windowWidth > 2 * half else { return windowWidth / 2 }
        return min(max(preferred, half), windowWidth - half)
    }

    /// One presenter per window: of the timelines showing the message
    /// (Posts and the thread inspector share a thread's root), the one
    /// under the pointer, else the first created.
    private func isReactionPresenter(for id: String) -> Bool {
        let showing = (services?.composer.timelines ?? []).compactMap { $0 as? TimelineViewController }
            .filter { $0.shows(messageID: id) }
        guard let pick = showing.first(where: \.containsPointer) ?? showing.first else { return true }
        return pick === self
    }

    private func shows(messageID id: String) -> Bool {
        isViewLoaded && view.window?.isVisible == true && items.contains { $0.messageID == id }
    }

    private var containsPointer: Bool {
        guard let w = view.window else { return false }
        return view.bounds.contains(view.convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// Closed by the person (transient click-away, Esc): clear the state.
    func popoverDidClose(_ notification: Notification) {
        guard let pop = notification.object as? NSPopover, pop === reactionPopover else { return }
        reactionPopover = nil
        reactionTargetID = nil
        updateMarked()
        if case .reaction? = services?.composer.popover { services?.composer.popover = nil }
    }

    private func updateMarked() {
        let next = alertTargetID ?? reactionTargetID ?? editTargetID
        guard next != markedID else { return }
        var rows = IndexSet()
        for m in [markedID, next].compactMap({ $0 }) {
            if let i = items.firstIndex(where: { $0.messageID == m }) { rows.insert(i) }
        }
        markedID = next
        guard isViewLoaded, !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    // MARK: updates

    private var ownName: String? { conv.ownDisplayName }

    private func apply(messages: [ChatMessage]) {
        let newChat = conv.chatID
        messagesByID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        services?.media.prefetch(messages)
        let next = rowsWithState(TimelineSnapshot.items(messages: messages, failed: failed, scope: scope),
                               messages: messages)
        guard isViewLoaded else { items = next; return }
        ensureWidth()
        if newChat != chatID || items.isEmpty {
            chatID = newChat
            highlightID = nil
            pinnedToBottom = true
            newWhileAway = 0
            items = next
            premeasure(next)
            table.reloadData()
            scrollToBottom()
            retryPendingJump()
            retryPendingReaction()
            return
        }
        let anchor = updateAnchor()
        let oldItems = items
        if !pinnedToBottom, let last = next.last?.messageID, last != oldItems.last?.messageID {
            newWhileAway += 1
            updateJumpButton()
        }
        let diff = next.map(\.id).difference(from: oldItems.map(\.id))
        let oldRevisions = Dictionary(oldItems.map { ($0.id, $0.revision) }, uniquingKeysWith: { a, _ in a })
        premeasure(next)
        items = next
        if !diff.isEmpty {
            table.beginUpdates()
            for change in diff {
                switch change {
                case .remove(let offset, _, _):
                    table.removeRows(at: IndexSet(integer: offset), withAnimation: [])
                case .insert(let offset, _, _):
                    table.insertRows(at: IndexSet(integer: offset), withAnimation: [])
                }
            }
            table.endUpdates()
        }
        var changed = IndexSet()
        for (i, item) in next.enumerated() {
            if let r = oldRevisions[item.id], r != item.revision { changed.insert(i) }
        }
        if !changed.isEmpty {
            table.noteHeightOfRows(withIndexesChanged: changed)
            table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }
        restore(anchor)
        retryPendingJump()
        retryPendingReaction()
    }

    /// Builds each message row's data and folds its extra state into the
    /// item revision, so the diff reloads (and re-measures) exactly the
    /// rows whose receipts, translation, pin, or save state changed.
    /// Merges `files` into the chip index when they belong to this
    /// timeline's conversation; true when a new attachment id arrived.
    @discardableResult
    private func noteSharedFiles(_ files: [SharedFile], chat: String?) -> Bool {
        guard let chat, chat == conv.chatID else { return false }
        if docChatID != chat {
            docChatID = chat
            docIndex = [:]
        }
        var added = false
        for (id, f) in InlineDocs.index(files: files) where docIndex[id] != f {
            docIndex[id] = f
            added = true
        }
        return added
    }

    private func rowsWithState(_ list: [TimelineItem], messages: [ChatMessage]) -> [TimelineItem] {
        let chat = conv.chatID
        let docs = docChatID == chat ? docIndex : [:]
        // "Seen by" is a chat receipt: channel posts and threads have none.
        let receiptTarget = scope == .conversation ? TimelineRowState.receiptTarget(messages, failed: failed) : nil
        var receipt = ReceiptDisplay.none
        if let target = receiptTarget {
            // Before the list row is known, more than one other sender
            // means a group (a 1:1 reads "Seen", never "Seen by 1").
            let isGroup = chat.flatMap { model?.graph.chats.chat(id: $0) }?.is_group
                ?? (Set(messages.lazy.filter { !$0.isOwn }.map(\.sender)).count > 1)
            var readers: [String] = []
            if let r = model?.app?.receipts, let chat {
                var pos: [String: Int] = [:]
                for (i, m) in messages.enumerated() where pos[m.id] == nil { pos[m.id] = i }
                readers = r.readers(chatID: chat, messageID: target, position: pos)
            }
            let enabled = !(model?.app?.ghost.shouldSuppressReceipts ?? false)
            receipt = ReceiptDisplay.resolve(isOwn: true, failed: false,
                                             isChannel: ChannelTabsStore.isChannelID(chat ?? ""),
                                             receiptsEnabled: enabled, isGroup: isGroup, readers: readers)
        }
        let pins = model?.graph.pinnedMessages
        let saves = model?.graph.savedMessages
        var data: [String: MessageRowData] = [:]
        var unmatched: [String] = []
        let out = list.map { item -> TimelineItem in
            guard case .message(let id, let rev, let header) = item, let m = messagesByID[id] else { return item }
            let refs = InlineDocs.refs(fromRaw: m.raw)
            let chips = refs.isEmpty || docs.isEmpty ? [] : InlineDocs.resolve(refs: refs, filesByAttachmentID: docs)
            if chips.count < min(refs.count, InlineDocs.maxRows), !failed.contains(id) { unmatched.append(id) }
            let row = MessageRowData(
                message: m, showsHeader: header, send: SendState.of(m, failed: failed),
                quote: TimelineSnapshot.showsQuote(m, scope: scope) ? TimelineRowState.quote(for: m, in: messagesByID) : nil,
                receipt: id == receiptTarget ? receipt : .none,
                translation: services?.translation.entry(for: id),
                isPinned: pins?.isPinned(chatID: chat, messageID: id) ?? false,
                isSaved: saves?.isSaved(chatID: chat, messageID: id) ?? false,
                ownName: ownName, chatID: chat,
                bubble: RowBubble.of(m, scope: scope),
                docs: chips)
            data[id] = row
            return .message(id: id, revision: TimelineRowState.combine(rev, row.extraRevision), showsHeader: header)
        }
        rowData = data
        lookUpAttachments(unmatched)
        return out
    }

    /// File chips past the Shared list's first page: once that page has
    /// landed for this conversation, each message whose attachment refs
    /// still miss is looked up by message id (the store asks once per
    /// message). Live only; thread replies have no lookup path.
    private func lookUpAttachments(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        if case .thread = scope { return }
        guard model?.options.demo != true, let shared = model?.app?.shared, let chat = conv.chatID,
              shared.chatID == chat, shared.state != .loading else { return }
        for id in ids { shared.resolveAttachments(chatID: chat, messageID: id) }
    }

    private func premeasure(_ list: [TimelineItem]) {
        for item in list { _ = height(of: item) }
    }

    // MARK: heights

    private var scale: Double { model?.textScale ?? 1.0 }

    private func ensureWidth() {
        let w = table.bounds.width > 0 ? table.bounds.width : scroll.contentSize.width
        if measureWidth == 0 { measureWidth = w > 0 ? w : 600 }
    }

    private func height(of item: TimelineItem) -> CGFloat {
        let key = RowHeightKey(id: item.id, revision: item.revision, width: measureWidth, scale: scale)
        return heights.height(for: key) {
            sizer.rootView = Hosting.root(content(for: item, highlighted: false), model: model)
            return sizer.sizeThatFits(in: NSSize(width: measureWidth, height: .greatestFiniteMagnitude)).height
        }
    }

    private func content(for item: TimelineItem, highlighted: Bool, marked: Bool = false,
                         fills: Bool = false) -> TimelineRowContent {
        let marked = marked || (item.messageID != nil && item.messageID == selectedID)
        return TimelineRowContent(item: item, row: item.messageID.flatMap { rowData[$0] },
                           highlighted: highlighted || marked, staticHighlight: staticHighlight || marked,
                           actions: actions, fills: fills)
    }

    /// Re-measure once when the width settles (never during live resize).
    /// Not re-entrant: re-measuring lays the table out, which can move
    /// its frame and post the frame notification that calls this again
    /// (a narrow pane toggling the scroller recursed until the stack
    /// overflowed). The outer call loops instead, at most 3 passes.
    private func widthSettled() {
        guard !settlingWidth else { return }
        settlingWidth = true
        defer { settlingWidth = false }
        for _ in 0..<3 {
            let w = table.bounds.width
            guard w > 0, abs(w - measureWidth) >= 1 else { return }
            let anchor = updateAnchor()
            measureWidth = w
            heights.retain(width: w, scale: scale)
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
            restore(anchor)
        }
    }

    private var settlingWidth = false

    override func viewDidLayout() {
        super.viewDidLayout()
        if !view.inLiveResize { widthSettled() }
        retryPendingJump()
    }

    private var lastScale: Double = 1.0

    /// A new scope (another thread) rebuilds like a new chat (P2c).
    func setScope(_ s: TimelineScope) {
        guard s != scope else { return }
        scope = s
        items = []
        apply(messages: conv.messages)
    }

    /// Text size changed (View ▸ Zoom): re-measure every row once.
    func scaleChanged(_ s: Double) {
        guard s != lastScale else { return }
        lastScale = s
        guard isViewLoaded, !items.isEmpty else { return }
        let anchor = updateAnchor()
        heights.retain(width: measureWidth, scale: s)
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        restore(anchor)
    }

    /// The window's live resize ended: re-measure once.
    private func liveResizeEnded(_ note: Notification) {
        guard let w = note.object as? NSWindow, w === view.window else { return }
        widthSettled()
    }

    // MARK: scrolling

    private func rows() -> [ScrollAnchor.Row] {
        let visible = scroll.contentView.bounds
        let range = table.rows(in: visible)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).map { i in
            let r = table.rect(ofRow: i)
            return ScrollAnchor.Row(id: items[i].id, minY: r.minY, maxY: r.maxY)
        }
    }

    /// Anchor for an update: a timeline pinned to the newest message
    /// stays pinned whatever the geometry did (first layout, window or
    /// pane resize, text size); otherwise the visible row keeps its place.
    private func updateAnchor() -> ScrollAnchor {
        pinnedToBottom ? .pinnedToBottom : captureAnchor()
    }

    private func captureAnchor() -> ScrollAnchor {
        let b = scroll.contentView.bounds
        return ScrollAnchor.capture(visibleMinY: b.minY, visibleHeight: b.height,
                                    contentHeight: table.frame.height, rows: rows())
    }

    private func restore(_ anchor: ScrollAnchor) {
        fitShortThread()
        table.layoutSubtreeIfNeeded()
        let b = scroll.contentView.bounds
        let contentHeight = table.frame.height
        let origin = ScrollAnchor.restoreOriginY(anchor, contentHeight: contentHeight, visibleHeight: b.height) { id in
            guard let i = self.items.firstIndex(where: { $0.id == id }) else { return nil }
            let r = self.table.rect(ofRow: i)
            return (r.minY, r.maxY)
        }
        guard var y = origin else { return }
        // Pinned: the bottom inset stays visible under the newest row.
        if case .pinnedToBottom = anchor, contentHeight > b.height { y += scroll.contentInsets.bottom }
        guard abs(y - b.minY) >= 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollToBottom() { restore(.pinnedToBottom) }

    private func viewportChanged() {
        guard isViewLoaded, !items.isEmpty else { return }
        if pinnedToBottom { scrollToBottom() } else { fitShortThread() }
        retryPendingJump()
    }

    /// Bottom-anchors a thread shorter than the viewport: row 0 takes
    /// the slack and the scroll view drops its insets (nothing to
    /// scroll, no scroller). A thread that overflows gets the normal
    /// insets and no slack. Idempotent; heights come from the cache.
    private func fitShortThread() {
        let clipH = scroll.contentView.frame.height
        guard clipH > 0 else { return }
        let natural = items.reduce(CGFloat(0)) { $0 + height(of: $1) }
        let pad = Self.overflowInsets.top + Self.overflowInsets.bottom
        let fits = !items.isEmpty && natural + pad <= clipH
        // A thread reads from its root down: it heads the pane (§6.3),
        // so only chats and Posts sit on the composer.
        let slack = fits && !scope.isThread ? (clipH - natural - Self.fitBottomGap).rounded(.down) : 0
        let insets = fits ? NSEdgeInsetsZero : Self.overflowInsets
        if scroll.contentInsets.top != insets.top || scroll.contentInsets.bottom != insets.bottom {
            scroll.contentInsets = insets
        }
        if scroll.hasVerticalScroller == fits { scroll.hasVerticalScroller = !fits }
        let old = topSlack
        topSlack = slack
        // Any row may have held the slack before an insert shifted it.
        if old != slack || old > 0, !items.isEmpty {
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
            let visible = table.rows(in: scroll.contentView.bounds)
            for i in visible.location..<(visible.location + visible.length) {
                (table.view(atColumn: 0, row: i, makeIfNecessary: false) as? TimelineCell)?
                    .top.constant = i == 0 ? slack : 0
            }
        }
    }

    /// Selection API (CALTEAMS): the row whose detail another pane shows
    /// (the open thread's root post) keeps a static highlight, so the
    /// two panes read as linked (HIG split views: persistent selection).
    private var selectedID: String?

    func setSelected(_ messageID: String?) {
        guard messageID != selectedID else { return }
        let rows = IndexSet([selectedID, messageID].compactMap { m in
            m.flatMap { m in items.firstIndex { $0.messageID == m } }
        })
        selectedID = messageID
        guard isViewLoaded, !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    /// Jump API: center the row and highlight it; a row not yet loaded
    /// is retried after the next update (the store pages toward it).
    func jump(to target: String) {
        let messageID = TimelineSnapshot.visibleTarget(target, scope: scope, in: messagesByID)
        let id = "msg:\(messageID)"
        guard let i = items.firstIndex(where: { $0.id == id }) else {
            pendingJump = messageID
            return
        }
        // No viewport yet (Activity/Search open the pane with the target
        // already set): a jump now lands against a zero-size clip and
        // the first real layout leaves the timeline mid-thread. Hold it
        // (not pinned, so layout never re-pins the newest row) and land
        // it once the pane has its size.
        guard scroll.contentView.bounds.height > 0, table.bounds.width > 0 else {
            pendingJump = messageID
            pinnedToBottom = false
            return
        }
        pendingJump = nil
        let old = highlightID.flatMap { h in items.firstIndex(where: { $0.messageID == h }) }
        highlightID = messageID
        var rows = IndexSet(integer: i)
        if let old { rows.insert(old) }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        restore(.jump(id: id))
        // A jump leaves the newest message: the timeline is pinned only
        // if the target landed at the bottom anyway, so a later frame
        // change (layout, composer growth) keeps the target in view
        // instead of re-pinning to the newest row.
        let b = scroll.contentView.bounds
        pinnedToBottom = table.frame.height - b.maxY <= 24
        if !pinnedToBottom { newWhileAway = 0 }
        updateJumpButton()
        // The sink runs inside the store's willSet: clearing here would be
        // overwritten by the setter, so the handled target clears on the
        // next main-actor turn (state cleanup only, not layout).
        Task { @MainActor [conv] in
            if conv.jumpTargetID == target { conv.clearJumpTarget() }
        }
    }

    /// Message ids of the rows inside the visible viewport (tests).
    var visibleMessageIDs: [String] {
        let r = table.rows(in: scroll.contentView.bounds)
        guard r.length > 0 else { return [] }
        return (r.location..<(r.location + r.length)).compactMap { items[$0].messageID }
    }

    private func retryPendingJump() {
        if let p = pendingJump { jump(to: p) }
    }

    /// History paging near the top (user scroll, not a view-appearance
    /// fetch; the store dedupes in-flight pages). Prefetches once the
    /// viewport is within one screen of the top (histload), so the
    /// older page usually lands before the top is reached; the prepend
    /// keeps the visible rows in place (anchor restore in `apply`).
    private func scrolled() {
        let b = scroll.contentView.bounds
        // A size change is a resize, not a scroll: keep the pinned state
        // (and the bottom) instead of reading it from the new geometry.
        if b.size != lastClipSize {
            lastClipSize = b.size
            if pinnedToBottom { scrollToBottom() }
            return
        }
        let pinned = table.frame.height - b.maxY <= 24
        if pinned != pinnedToBottom {
            pinnedToBottom = pinned
            if pinned { newWhileAway = 0 }
            updateJumpButton()
        }
        guard Self.shouldPrefetchOlder(offsetFromTop: b.minY, viewportHeight: b.height),
              conv.canLoadMore, !conv.loadingMore,
              !items.isEmpty else { return }
        conv.loadMore()
    }

    /// Older-page prefetch gate: within one viewport (at least 120pt)
    /// of the top. Pure, testable.
    nonisolated static func shouldPrefetchOlder(offsetFromTop: CGFloat, viewportHeight: CGFloat) -> Bool {
        offsetFromTop < max(120, viewportHeight)
    }

    private func updateJumpButton() {
        guard let jumpHost else { return }
        let hidden = pinnedToBottom || items.isEmpty
        jumpHost.isHidden = hidden
        jumpHost.rootView = Hosting.root(JumpToLatestButton(count: newWhileAway) { [weak self] in
            self?.jumpToLatest()
        }, model: model)
        // The button sits in its own strip under the scroll view: the
        // viewport ends above it, so no message text runs under it. The
        // strip only shows while unpinned, and the viewport shrinks from
        // the bottom, so visible rows keep their place.
        let strip = hidden ? 0 : jumpHost.fittingSize.height
        if let scrollBottom, abs(scrollBottom.constant + strip) >= 0.5 { scrollBottom.constant = -strip }
    }

    private func jumpToLatest() {
        scrollToBottom()
        pinnedToBottom = true
        newWhileAway = 0
        updateJumpButton()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return 1 }
        return height(of: items[row]) + (row == 0 ? topSlack : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let c = content(for: item, highlighted: item.messageID != nil && item.messageID == highlightID,
                        marked: item.messageID != nil && item.messageID == markedID, fills: true)
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? TimelineCell
            ?? TimelineCell(content: c, model: model)
        cell.host.rootView = Hosting.root(c, model: model)
        cell.top.constant = row == 0 ? topSlack : 0
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// Evidence captures only (demo): a bottom-pinned timeline that
    /// overflows usually cuts through its top row, leaving a sender name
    /// half under the pane header. Scroll up to the start of that run
    /// (its header row or day separator) so the top shows a whole header.
    func evidenceRevealTopHeader() {
        let b = scroll.contentView.bounds
        guard !items.isEmpty, table.frame.height > b.height else { return }
        let top = b.minY + scroll.contentInsets.top
        let cut = table.row(at: NSPoint(x: 1, y: top))
        guard cut >= 0, table.rect(ofRow: cut).minY < top - 0.5 else { return }
        let start = (0...cut).reversed().first { i in
            switch items[i] {
            case .message(_, _, let header): header
            case .daySeparator: true
            default: false
            }
        } ?? cut
        let y = table.rect(ofRow: start).minY - scroll.contentInsets.top
        // A deliberate scroll, not a resize: no re-pin to the bottom.
        lastClipSize = b.size
        pinnedToBottom = false
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Evidence geometry (§11.4): rows whose laid-out height differs
    /// from a fresh measure at the current width (stale = clip/overlap),
    /// row 0's header, slack and top.
    func geometryAudit() -> String {
        let w = table.bounds.width
        var stale = 0
        var worst: CGFloat = 0
        for (i, item) in items.enumerated() {
            sizer.rootView = Hosting.root(content(for: item, highlighted: false), model: model)
            let fresh = sizer.sizeThatFits(in: NSSize(width: w, height: .greatestFiniteMagnitude)).height
            let laid = table.rect(ofRow: i).height - (i == 0 ? topSlack : 0)
            if abs(fresh - laid) >= 1 { stale += 1; worst = max(worst, abs(fresh - laid)) }
        }
        // First message row (after its day separator) shows its header.
        var head0 = false
        if case .message(_, _, let h)? = items.first(where: { $0.messageID != nil }) { head0 = h }
        let y0 = items.isEmpty ? 0 : Int(table.rect(ofRow: 0).minY)
        return "scope=\(scope) rows=\(items.count) w=\(Int(w)) stale=\(stale) maxDelta=\(Int(worst)) "
            + "head0=\(head0) slack=\(Int(topSlack)) row0y=\(y0) clipY=\(Int(scroll.contentView.bounds.minY)) "
            + "clipH=\(Int(scroll.contentView.bounds.height)) contentH=\(Int(table.frame.height)) "
            + "hiddenBelow=\(Int(table.frame.height - scroll.contentView.bounds.maxY)) "
            + "insetB=\(Int(scroll.contentInsets.bottom)) pinned=\(pinnedToBottom) measureW=\(Int(measureWidth))"
    }
}

/// SwiftUI bridge for the timeline island.
struct TimelineRepresentable: NSViewControllerRepresentable {
    let conv: ConversationStore
    var scope: TimelineScope = .conversation
    /// Row shown selected (static highlight), e.g. the open thread's root.
    var selectedID: String?
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale

    func makeNSViewController(context: Context) -> TimelineViewController {
        TimelineViewController(conv: conv, model: model, scope: scope)
    }

    func updateNSViewController(_ vc: TimelineViewController, context: Context) {
        vc.setScope(scope)
        vc.setSelected(selectedID)
        vc.scaleChanged(scale)
    }
}
