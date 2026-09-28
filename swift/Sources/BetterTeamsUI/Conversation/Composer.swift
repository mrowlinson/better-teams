// Composer.swift — the message composer (UI-SPEC §6.2.2).
//
// Field: an `NSTextView` island (`ComposerTextView`), 1–8 lines. P2a's
// check of the spec's `TextField(axis: .vertical)` failed on both counts
// the spec names: `onKeyPress(.return)` fires before the input method,
// so Return sent the message while IME text was still marked, and a
// TextField cannot take a pasted image. The text view commits marked
// text first (the input context consumes Return), inserts ⇧Return at
// the caret, and turns a pasted image into an attachment. Same API.
//
// Leading: Attach (NSOpenPanel), Emoji (Character Viewer), GIF (only
// with a Klipy key), Templates menu. Send with a pull-down: Send Now,
// Send Later…. Status: reply/edit chip, attachment chips, a reserved
// status line (typing, "N Scheduled", ghost glyph). Popovers anchored
// here, one at a time (`ComposerPopover`).
import AppKit
import OstMacCore
import SwiftUI

/// Return-key policy (pure, unit-tested).
enum ComposerKeyPolicy {
    enum Action: Equatable { case send, newline, passThrough }

    static func action(shift: Bool, markedText: Bool, returnSends: Bool = true) -> Action {
        if markedText { return .passThrough }
        if shift { return returnSends ? .newline : .send }
        return returnSends ? .send : .newline
    }
}

/// @-mention trigger over the draft's trailing token (pure, unit-tested).
enum MentionTrigger {
    /// The text typed after a trailing `@` (nil when the last token is
    /// not a mention in progress).
    static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        let q = draft[draft.index(after: at)...]
        guard !q.contains(where: { $0.isNewline }), q.count <= 40,
              !q.hasPrefix(" "), !(q.count > 1 && q.hasSuffix("  "))
        else { return nil }
        return String(q)
    }

    /// Replaces the trailing `@query` with `@Name `.
    static func complete(_ draft: String, with name: String) -> String {
        guard let q = query(in: draft) else { return MentionCompose.insert(name, into: draft) }
        let base = String(draft.dropLast(q.count + 1))
        return MentionCompose.insert(name, into: base)
    }
}

struct Composer: View {
    let chatID: String
    let chatName: String
    let placeholder: String
    @ObservedObject var conv: ConversationStore
    @ObservedObject var composer: ComposerModel
    @ObservedObject var attachments: ComposeAttachmentsStore
    let services: ConversationServices
    @Environment(\.windowModel) private var model
    @Environment(\.contentTextScale) private var scale
    @State private var fieldHeight: CGFloat = 18
    @State private var mentionIndex = 0

    private var draft: Binding<String> {
        Binding(get: { composer.draft(chatID) }, set: { composer.setDraft($0, for: chatID); draftChanged($0) })
    }

    private var trimmed: String {
        composer.draft(chatID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmed.isEmpty || (!attachments.attachments.isEmpty && composer.editing == nil && !attachments.uploading)
    }

    /// People to mention: other people in this conversation (you are
    /// never offered), newest speaker first.
    private var roster: [String] {
        MentionCompose.filtered(MentionCompose.roster(from: conv.messages.filter { !$0.isOwn },
                                                      excluding: conv.ownDisplayName),
                                query: MentionTrigger.query(in: composer.draft(chatID)) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let editing = composer.editing {
                chip(symbol: "pencil", title: "Editing Message", detail: ConversationStore.quotePreview(editing.content),
                     cancel: "Cancel Editing") { composer.endEdit(chatID: chatID) }
            } else if let reply = conv.replyTarget {
                chip(symbol: "arrowshape.turn.up.left", title: "Replying to \(reply.isOwn ? "yourself" : reply.sender)",
                     detail: ConversationStore.quotePreview(MessageRender.bubbleText(for: reply)),
                     cancel: "Cancel Reply") { conv.cancelReply() }
            }
            if !attachments.attachments.isEmpty {
                AttachmentChips(store: attachments)
            }
            // Reaction More… opens at its message (the timeline owns it).
            // Both accessory groups center on the field's last text line
            // (its center while single-line), whatever their heights.
            HStack(alignment: .composerLine, spacing: 8) {
                leadingButtons
                    .alignmentGuide(.composerLine) { $0[VerticalAlignment.center] }
                field
                    .alignmentGuide(.composerLine) { [line = ComposerTextView.lineHeight(scale)] d in
                        d[.bottom] - Self.fieldInset - line / 2
                    }
                sendButton
                    .alignmentGuide(.composerLine) { $0[VerticalAlignment.center] }
            }
            statusLine
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onAppear {
            // Evidence captures leave the field unfocused: a focused
            // field draws the system input-source bubble at its caret,
            // over the accessory buttons.
            if !(model?.options.evidence ?? false) { composer.focusRequest += 1 }
            applyEvidencePopover()
        }
        .onChange(of: chatID) {
            composer.popover = nil
            composer.editing = nil
            // Same evidence guard as onAppear: a route that lands on a
            // chat after launch must not focus the field either.
            if !(model?.options.evidence ?? false) { composer.focusRequest += 1 }
        }
    }

    // MARK: pieces

    private func chip(symbol: String, title: String, detail: String, cancel: String,
                      action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(AppFont.caption(scale).weight(.semibold))
                Text(detail).font(AppFont.caption(scale)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: action) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(cancel)
                .accessibilityLabel(cancel)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Toolbar-like icon row: 24 pt targets, 6 pt apart (HIG spacing).
    private var leadingButtons: some View {
        HStack(spacing: 6) {
            iconButton("paperclip", "Attach Files") { attach() }
            iconButton("face.smiling", "Emoji & Symbols") {
                composer.focusRequest += 1
                NSApp.orderFrontCharacterPalette(nil)
            }
            if services.hasGIFKey {
                iconButton("photo.on.rectangle.angled", "GIF") { composer.show(.gif) }
                    .popover(item: popoverBinding(only: [.gif]), arrowEdge: .top) { p in popoverContent(p) }
            }
            if let canned = model?.app?.canned {
                TemplatesMenu(store: canned) { body in
                    let d = composer.draft(chatID)
                    composer.setDraft(d.isEmpty ? body : d + (d.hasSuffix(" ") ? "" : " ") + body, for: chatID)
                    composer.focusRequest += 1
                }
            }
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .help(label)
        .accessibilityLabel(label)
    }

    private var field: some View {
        ComposerTextView(
            text: draft, height: $fieldHeight, focusRequest: composer.focusRequest, scale: scale,
            onSubmit: submit, onCommand: handleCommand,
            onPasteFiles: { attachments.stage(urls: $0) })
            .frame(height: fieldHeight)
            .overlay(alignment: .topLeading) {
                if composer.draft(chatID).isEmpty {
                    Text(composer.editing != nil ? "Edit message" : placeholder)
                        .font(AppFont.body(scale))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Self.fieldInset)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 1)
            }
            // Mention suggestions open near the start of the field, where
            // the text is; reactions More… anchors to the composer (§6.2.2).
            .popover(item: popoverBinding(only: [.mention]), attachmentAnchor: .point(UnitPoint(x: 0.12, y: 0)),
                     arrowEdge: .top) { p in popoverContent(p) }

            .accessibilityElement(children: .contain)
            .accessibilityLabel(placeholder)
    }

    @ViewBuilder
    private var sendButton: some View {
        if composer.editing != nil {
            // Editing saves in place: no Send Later, so no pull-down
            // chevron (§6.2.2), just the Save Edit button.
            Button(action: submit) {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .fixedSize()
            .disabled(!canSend)
            .help("Save Edit")
            .accessibilityLabel("Save Edit")
        } else {
            sendMenu
        }
    }

    private var sendMenu: some View {
        Menu {
            Button("Send Now", action: submit)
            Button("Send Later…") { composer.show(.sendLater) }
                .disabled(trimmed.isEmpty || services.scheduled(model) == nil)
        } label: {
            Image(systemName: "paperplane.fill")
        } primaryAction: {
            submit()
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .controlSize(.large)
        .fixedSize()
        // Anchored to the pull-down chevron that opens it (§9.5 "anchored
        // to its control"), not to a point over the field.
        .popover(item: popoverBinding(only: [.sendLater]),
                 attachmentAnchor: .point(UnitPoint(x: Self.chevronX, y: 0)),
                 arrowEdge: .top) { p in popoverContent(p) }
        .disabled(!canSend)
        .help("Send")
        .accessibilityLabel("Send")
    }

    /// Text inset inside the field's rounded box (top and bottom).
    static let fieldInset: CGFloat = 7

    /// The Send pull-down's chevron, as a fraction of the button's width
    /// (glyph leading, menu indicator trailing).
    static let chevronX: CGFloat = 0.8

    /// Reserved status line (R13): typing on the leading side, queue and
    /// ghost state trailing. Always present, so nothing shifts.
    private var statusLine: some View {
        HStack(spacing: 8) {
            if let typing = model?.app?.typing {
                TypingLine(store: typing, chatID: chatID)
            }
            Spacer(minLength: 8)
            if let scheduled = services.scheduled(model) {
                ScheduledButton(store: scheduled, chatID: chatID) {
                    composer.popover = nil
                    model?.presentSheet(SheetRequest(ChatCommands.scheduledSheet, in: model?.nav.section ?? .chat))
                }
            }
            if let ghost = model?.app?.ghost { GhostGlyph(store: ghost) }
        }
        .font(AppFont.caption(scale))
        .foregroundStyle(.secondary)
        .frame(height: 22)
    }

    // MARK: popovers (one state value, so never two at once — R17)

    /// The shared popover state, narrowed to the cases one anchor shows.
    private func popoverBinding(only cases: Set<ComposerPopover>) -> Binding<ComposerPopover?> {
        popoverBinding(where: { cases.contains($0) })
    }

    private func popoverBinding(where match: @escaping (ComposerPopover) -> Bool) -> Binding<ComposerPopover?> {
        Binding(get: { composer.popover.flatMap { match($0) ? $0 : nil } },
                set: { v in if v == nil, let p = composer.popover, match(p) { composer.popover = nil } })
    }

    private func popoverContent(_ p: ComposerPopover) -> some View {
        ComposerPopoverContent(popover: p, chatID: chatID, chatName: chatName, conv: conv,
                               composer: composer, services: services, roster: roster,
                               mentionIndex: mentionIndex, pickMention: pickMention)
    }

    // MARK: behavior

    private func draftChanged(_ text: String) {
        if MentionTrigger.query(in: text) != nil {
            if composer.popover == nil { mentionIndex = 0; composer.show(.mention) }
        } else if composer.popover == .mention {
            composer.popover = nil
        }
    }

    /// Keys the text view offers first: the mention list takes arrows,
    /// Return/Tab (pick) and Esc while it is open.
    private func handleCommand(_ sel: Selector) -> Bool {
        guard composer.popover == .mention else { return false }
        let names = roster
        switch sel {
        case #selector(NSResponder.moveDown(_:)):
            mentionIndex = names.isEmpty ? 0 : min(mentionIndex + 1, names.count - 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            mentionIndex = max(mentionIndex - 1, 0)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            guard names.indices.contains(mentionIndex) else { return false }
            pickMention(names[mentionIndex])
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            composer.popover = nil
            return true
        default:
            return false
        }
    }

    private func pickMention(_ name: String) {
        composer.setDraft(MentionTrigger.complete(composer.draft(chatID), with: name), for: chatID)
        composer.popover = nil
        composer.focusRequest += 1
    }

    private func submit() {
        let text = composer.draft(chatID)
        if let editing = composer.editing {
            let body = CodeBlocks.sendBody(for: text)
            guard !body.isEmpty else { return }
            if body != editing.content { conv.edit(messageID: editing.id, text: body) }
            composer.endEdit(chatID: chatID)
            return
        }
        let body = CodeBlocks.sendBody(for: text)
        if !attachments.attachments.isEmpty {
            let store = attachments
            let demo = services.isDemo
            let id = chatID
            Task { @MainActor in
                let files = await store.uploadPending(chatID: id, isDemo: demo)
                if demo, !files.isEmpty {
                    conv.send(text: files.map { "📎 \($0.name)" }.joined(separator: "\n"))
                }
                store.clearFinished()
            }
        }
        guard !body.isEmpty else { composer.setDraft("", for: chatID); return }
        conv.send(text: body)
        composer.setDraft("", for: chatID)
        composer.popover = nil
    }

    private func attach() {
        composer.popover = nil
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.beginSheetModal(for: window) { response in
            if response == .OK { attachments.stage(urls: panel.urls) }
        }
    }

    /// Evidence (`popover=<name>`, demo only): opens that popover once.
    /// `draft=multi` prefills three lines (accessory alignment check).
    private func applyEvidencePopover() {
        guard let model, model.options.demo, !composer.evidenceApplied,
              let raw = model.options.route, let route = Route(string: raw) else { return }
        composer.evidenceApplied = true
        if route.query["draft"] == "multi" {
            composer.setDraft("Draft line one\nDraft line two\nDraft line three", for: chatID)
        }
        guard let name = route.query["popover"],
              let p = ComposerPopover(evidenceName: name, lastMessageID: conv.messages.last?.id) else { return }
        if p == .mention { composer.setDraft("Thanks @", for: chatID) }
        if p == .sendLater { composer.setDraft("Reminder: review deck at 10", for: chatID) }
        composer.show(p)
    }
}

// MARK: - Status pieces (each observes only its own store, R28)

private struct TypingLine: View {
    @ObservedObject var store: TypingStore
    let chatID: String

    var body: some View {
        if let line = store.line(chatID: chatID) {
            Text(line).lineLimit(1).truncationMode(.tail)
        }
    }
}

private struct ScheduledButton: View {
    @ObservedObject var store: ScheduledSendStore
    let chatID: String
    let open: () -> Void

    var body: some View {
        let n = store.pending(for: chatID).count
        if n > 0 {
            // A real button (§6.2.2 "2 scheduled" button), not a caption.
            Button(action: open) {
                Label("\(n) Scheduled", systemImage: "clock")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Show Scheduled Messages")
        }
    }
}

private struct GhostGlyph: View {
    @ObservedObject var store: GhostStore

    var body: some View {
        if store.master {
            Image(systemName: "eye.slash")
                .help("Ghost mode is on: read receipts and presence are hidden")
                .accessibilityLabel("Ghost mode on")
        }
    }
}

/// Templates (§6.2.2 `text.badge.plus`): the same borderless icon
/// button as its neighbors, opening a native pull-down `NSMenu`.
private struct TemplatesMenu: View {
    @ObservedObject var store: CannedResponsesStore
    let insert: (String) -> Void

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "text.badge.plus").frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .help("Insert Template")
        .accessibilityLabel("Insert Template")
    }

    private func showMenu() {
        let menu = NSMenu()
        if store.templates.isEmpty {
            let empty = NSMenuItem(title: "No Templates", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for t in store.templates {
                menu.addItem(ClosureMenuItem(title: t.title) { insert(t.body) })
            }
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// NSMenuItem that runs a closure (menus built on demand).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    @objc private func fire() { run() }
}

private struct AttachmentChips: View {
    @ObservedObject var store: ComposeAttachmentsStore
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(store.attachments) { a in chip(a) }
            }
        }
        .frame(height: 34)
    }

    private func chip(_ a: ComposeAttachment) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: a.path))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(a.name).font(AppFont.caption(scale)).lineLimit(1).truncationMode(.middle)
                Text(status(a)).font(AppFont.caption(scale)).foregroundStyle(statusStyle(a))
            }
            .frame(maxWidth: 160, alignment: .leading)
            switch a.state {
            case .uploading:
                ProgressView().controlSize(.small)
            case .failed:
                Button("Retry") { store.retry(id: a.id) }.buttonStyle(.borderless).controlSize(.small)
            default:
                EmptyView()
            }
            Button { store.remove(id: a.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(a.name)")
                .accessibilityLabel("Remove \(a.name)")
                .disabled(a.state == .uploading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func status(_ a: ComposeAttachment) -> String {
        switch a.state {
        case .staged: ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)
        case .tooLarge(let n): "\(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)) · large upload"
        case .uploading: "Uploading…"
        case .uploaded: "Attached"
        case .failed: "Upload failed"
        }
    }

    private func statusStyle(_ a: ComposeAttachment) -> AnyShapeStyle {
        if case .failed = a.state { return AnyShapeStyle(Palette.failed) }
        return AnyShapeStyle(.secondary)
    }
}

// MARK: - Text view island

/// Pasteboard → attachment files (images become PNG files).
enum ComposerPaste {
    static func files(from pb: NSPasteboard) -> [URL]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty
        {
            return urls
        }
        guard pb.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BetterTeams-Paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Pasted Image \(f.string(from: Date())).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return [url]
    }
}

final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCommand: ((Selector) -> Bool)?
    var onPasteFiles: (([URL]) -> Void)?
    /// Focus asked for before the view had a window, or while its window
    /// was not key.
    var wantsFocus = false
    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A pending wait belongs to the old window.
        if let o = keyObserver { NotificationCenter.default.removeObserver(o) }
        keyObserver = nil
        if wantsFocus { requestFocus() }
    }

    /// Takes focus now in a key window; otherwise when the window next
    /// becomes key. The system's input-source indicator (a separate
    /// window beside the caret, drawn at the field's leading edge over
    /// the icon row, and above any sheet) appears whenever a text view
    /// takes focus; in a window that is not key it never fades, so an
    /// inactive window (a background window, every evidence capture)
    /// showed it stuck over the Templates button. A non-key window has
    /// no caret anyway: focus waits for key status.
    func requestFocus() {
        guard let window else { wantsFocus = true; return }
        if window.isKeyWindow {
            wantsFocus = false
            if window.firstResponder !== self { window.makeFirstResponder(self) }
            return
        }
        wantsFocus = true
        guard keyObserver == nil else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let o = self.keyObserver { NotificationCenter.default.removeObserver(o) }
                self.keyObserver = nil
                if self.wantsFocus, self.window?.isKeyWindow == true { self.requestFocus() }
            }
        }
    }

    /// The accessory's own placement hook (kept: some macOS versions
    /// honor it for the Caps Lock glyph).
    override func preferredTextAccessoryPlacement() -> NSTextCursorAccessoryPlacement {
        .invisible
    }

    override func doCommand(by selector: Selector) {
        if let onCommand, onCommand(selector) { return }
        super.doCommand(by: selector)
    }

    override func insertNewline(_ sender: Any?) {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        switch ComposerKeyPolicy.action(shift: shift, markedText: hasMarkedText(),
                                        returnSends: AppSettings.shared.returnSends) {
        case .send: onSubmit?()
        case .newline, .passThrough: super.insertNewline(sender)
        }
    }

    override func paste(_ sender: Any?) {
        if let files = ComposerPaste.files(from: .general), let onPasteFiles {
            onPasteFiles(files)
            return
        }
        pasteAsPlainText(sender)
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusRequest: Int
    let scale: Double
    let onSubmit: () -> Void
    let onCommand: (Selector) -> Bool
    let onPasteFiles: ([URL]) -> Void

    static let maxLines: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.focusRingType = .none
        let tv = ComposerNSTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.focusRingType = .none // §10
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.textColor = .labelColor
        tv.font = Self.font(scale)
        tv.string = text
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Message")
        scroll.documentView = tv
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.attach(scroll: scroll, textView: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        tv.onSubmit = onSubmit
        tv.onCommand = onCommand
        tv.onPasteFiles = onPasteFiles
        var changed = false
        let f = Self.font(scale)
        if tv.font != f { tv.font = f; changed = true }
        if tv.string != text, !tv.hasMarkedText() {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            changed = true
        }
        if changed { c.remeasure() }
        if focusRequest != c.lastFocus {
            c.lastFocus = focusRequest
            c.focus()
        }
    }

    static func font(_ scale: Double) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize * scale)
    }

    /// One line of the field at `scale` (the single-line field height).
    static func lineHeight(_ scale: Double) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font(scale)).rounded(.up)
    }

    /// Height for `text` at `width`: 1…8 lines of `font`.
    static func height(for text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: font)
        guard width > 1 else { return line.rounded(.up) }
        var measured = text.isEmpty ? " " : text
        if measured.hasSuffix("\n") { measured += " " }
        let h = (measured as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return min(max(h, line), line * maxLines).rounded(.up)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        weak var scroll: NSScrollView?
        var lastFocus = -1
        private var observer: NSObjectProtocol?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func attach(scroll: NSScrollView, textView: ComposerNSTextView) {
            self.scroll = scroll
            self.textView = textView
            // The field wraps at its width: a width change re-measures.
            observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.remeasure() } }
        }

        func textDidChange(_ note: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            remeasure()
        }

        func remeasure() {
            guard let tv = textView, let scroll else { return }
            let h = ComposerTextView.height(for: tv.string, width: scroll.contentSize.width,
                                            font: tv.font ?? ComposerTextView.font(parent.scale))
            if abs(h - parent.height) >= 0.5 { parent.height = h }
        }

        func focus() {
            textView?.requestFocus()
        }
    }
}

extension VerticalAlignment {
    /// The composer field's last text line center: the accessory
    /// buttons on both sides of the field align to it.
    private enum ComposerLine: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    static let composerLine = VerticalAlignment(ComposerLine.self)
}
