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

    static func action(shift: Bool, command: Bool = false, markedText: Bool, returnSends: Bool = true) -> Action {
        if markedText { return .passThrough }
        // ⌘Return always sends, whichever way Return itself is set.
        if command { return .send }
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
    @State private var fieldHeight: CGFloat = ComposerTextView.minFieldHeight(1)
    @State private var mentionIndex = 0
    /// Format bar visibility (Mail-style `textformat` toggle) + the last
    /// requested action (bar button or ⌘B/I/U).
    @State private var showFormat = false
    @State private var formatSeq = 0
    @State private var formatAction: ComposerFormatAction = .bold

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
        let query = MentionTrigger.query(in: composer.draft(chatID)) ?? ""
        let people = MentionCompose.filtered(MentionCompose.roster(from: conv.messages.filter { !$0.isOwn },
                                                                   excluding: conv.ownDisplayName),
                                             query: query)
        // TAGS: team tags after people (demo only — live is
        // scope-blocked, so the picker never fakes tag rows).
        let tags = tagNames.filter { !people.contains($0) }
        // COMPOSER-B: broadcast specials after people (channel-gated).
        let specials = MentionWire.displays(channel: isChannel).filter { display in
            query.isEmpty || display.lowercased().contains(query.lowercased())
        }
        return people + tags + specials.filter { !people.contains($0) && !tags.contains($0) }
    }

    /// Demo tag names for this channel's team (live: []).
    private var tagNames: [String] {
        guard let model, model.options.demo,
              let teams = model.app?.teams.teams,
              let (team, _) = TeamsListPane.locate(chatID, in: teams) else { return [] }
        let query = MentionTrigger.query(in: composer.draft(chatID)) ?? ""
        return TeamTags.mentionCandidates(TeamTagsStore.demoTags(teamID: team.teamId), query: query)
    }

    /// COMPOSER-B: channel posts get team/channel broadcasts + subject.
    private var isChannel: Bool {
        ConversationStore.isChannelConversation(chatID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            if showFormat { formatBar }
            if isChannel { subjectField }
            // Reaction More… opens at its message (the timeline owns it).
            // Both accessory strips top-align with the field: at 6 rows
            // the left strip is much taller than the 2-line field, so
            // centering on the last text line would leave the field
            // floating mid-strip.
            HStack(alignment: .top, spacing: 8) {
                leadingStrip
                field
                    .layoutPriority(1)
                sendButton
            }
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
            if evidenceFormatBar { showFormat = true }
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

    /// Toolbar-like icon strip: the same 24 pt targets, stacked
    /// vertically (2 pt apart) so the cluster costs one 24 pt column
    /// instead of ~150 pt of horizontal buttons. Same buttons, same
    /// order, same actions — geometry only.
    private var leadingStrip: some View {
        VStack(spacing: 2) {
            Button(action: { showFormat.toggle() }) {
                Image(systemName: "textformat.size").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .foregroundStyle(showFormat ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .help(showFormat ? "Hide Formatting" : "Show Formatting")
            .accessibilityLabel(showFormat ? "Hide Formatting" : "Show Formatting")
            importanceMenu
            iconButton("paperclip", "Attach Files") { attach() }
            iconButton("face.smiling", "Emoji & Symbols") {
                composer.focusRequest += 1
                NSApp.orderFrontCharacterPalette(nil)
            }
            iconButton("chart.bar", "Create Poll") { composer.showPollSheet = true }
                .sheet(isPresented: $composer.showPollSheet) {
                    PollComposerSheet(conv: conv)
                }
            if services.hasGIFKey {
                iconButton("photo.on.rectangle.angled", "GIF") { composer.show(.gif) }
                    .popover(item: popoverBinding(only: [.gif]), arrowEdge: .top) { p in popoverContent(p) }
            }
            // PRAISE: badge picker + note (popover, same 24 pt targets).
            iconButton("medal", "Praise") { composer.show(.praise) }
                .popover(item: popoverBinding(only: [.praise]), arrowEdge: .top) { p in popoverContent(p) }
            // LOOPBUILD: component URL + gated send (popover, same targets).
            iconButton("infinity", "Loop") { composer.show(.loop) }
                .popover(item: popoverBinding(only: [.loop]), arrowEdge: .top) { p in popoverContent(p) }
            iconButton("star.bubble", "Sticker") { composer.show(.sticker) }
                .popover(item: popoverBinding(only: [.sticker]), arrowEdge: .top) { p in popoverContent(p) }
            if let canned = model?.app?.canned {
                TemplatesMenu(store: canned) { body in
                    let d = composer.draft(chatID)
                    composer.setDraft(d.isEmpty ? body : d + (d.hasSuffix(" ") ? "" : " ") + body, for: chatID)
                    composer.focusRequest += 1
                }
            }
        }
    }

    /// Format bar (COMPOSER-A): markdown markers behind native icon
    /// buttons, same 24 pt targets as the row below. Bold/italic/
    /// underline match ⌘B/I/U; the rest are bar-only.
    private var formatBar: some View {
        HStack(spacing: 6) {
            formatButton(.bold, "bold", "Bold", "⌘B")
            formatButton(.italic, "italic", "Italic", "⌘I")
            formatButton(.underline, "underline", "Underline", "⌘U")
            formatButton(.strike, "strikethrough", "Strikethrough", nil)
            Divider().frame(height: 18)
            formatButton(.bulletList, "list.bullet", "Bulleted List", nil)
            formatButton(.numberedList, "list.number", "Numbered List", nil)
            formatButton(.quote, "text.quote", "Quote", nil)
            formatButton(.inlineCode, "chevron.left.forwardslash.chevron.right", "Inline Code", nil)
            formatButton(.table, "tablecells", "Table", nil)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting")
    }

    private func formatButton(_ action: ComposerFormatAction, _ symbol: String,
                              _ label: String, _ shortcut: String?) -> some View {
        Button(action: { requestFormat(action) }) {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .help(shortcut == nil ? label : "\(label) (\(shortcut!))")
        .accessibilityLabel(shortcut == nil ? label : "\(label), \(shortcut!)")
    }

    /// COMPOSER-B: importance picker (native Menu + Picker checkmarks,
    /// same 24 pt targets as its neighbors).
    private var importanceMenu: some View {
        let level = composer.importance(for: chatID)
        return Menu {
            Picker("Importance", selection: importanceBinding) {
                ForEach(MessageImportance.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: level == .normal ? "exclamationmark.circle" : "exclamationmark.circle.fill")
                .frame(width: 24, height: 24)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.large)
        .foregroundStyle(level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
        .help("Importance: \(level.label)")
        .accessibilityLabel("Message importance, \(level.label)")
    }

    private var importanceBinding: Binding<MessageImportance> {
        Binding(get: { composer.importance(for: chatID) },
                set: { composer.setImportance($0, for: chatID) })
    }

    /// COMPOSER-B: announcement subject (channels only). The wire
    /// carries it when non-blank; blank posts are unchanged.
    private var subjectField: some View {
        TextField("Subject", text: subjectBinding)
            .textFieldStyle(.roundedBorder)
            .font(AppFont.body(scale))
            .help("Announcement subject")
            .accessibilityLabel("Announcement subject")
    }

    private var subjectBinding: Binding<String> {
        Binding(get: { composer.subject(for: chatID) },
                set: { composer.setSubject($0, for: chatID) })
    }

    /// Routes a bar tap or shortcut through the text view (single path,
    /// so both see the same selection + IME guard).
    private func requestFormat(_ action: ComposerFormatAction) {
        formatAction = action
        formatSeq += 1
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
            formatSeq: formatSeq, formatAction: formatAction,
            onSubmit: submit, onCommand: handleCommand,
            onFormat: requestFormat,
            onPasteFiles: { attachments.stage(urls: $0) })
            .frame(minWidth: Self.minFieldWidth)
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
            .chromeBackground(.composerField, in: RoundedRectangle(cornerRadius: 8, style: .continuous)) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.fill.quinary)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 1)
                    }
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
            sendColumn
        }
    }

    /// Send + chevron as a vertical pair: the paperplane sends, the
    /// chevron below it opens the Send Now / Send Later menu. Same two
    /// actions, same order (send first) — geometry only.
    private var sendColumn: some View {
        VStack(spacing: 2) {
            Button(action: submit) {
                Image(systemName: "paperplane.fill").frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .disabled(!canSend)
            .help("Send")
            .accessibilityLabel("Send")
            Menu {
                Button("Send Now", action: submit)
                Button("Send Later…") { composer.show(.sendLater) }
                    .disabled(trimmed.isEmpty || services.scheduled(model) == nil)
            } label: {
                Image(systemName: "chevron.down").frame(width: 24, height: 24)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .controlSize(.large)
            // Anchored to the chevron that opens it (§9.5 "anchored to
            // its control"), not to a point over the field.
            .popover(item: popoverBinding(only: [.sendLater]),
                     attachmentAnchor: .point(UnitPoint(x: Self.chevronX, y: 0)),
                     arrowEdge: .top) { p in popoverContent(p) }
            .disabled(!canSend)
            .help("Send options")
            .accessibilityLabel("Send options")
        }
    }

    /// Text inset inside the field's rounded box (top and bottom).
    static let fieldInset: CGFloat = 7

    /// The field's pinned minimum usable width: ~20 average glyphs at
    /// body size (~7 pt each at 13 pt), ~6x the 24 pt accessory target,
    /// so the field stays dominant over the chrome at narrow windows.
    /// Density guard pins the value; the row's strips are fixed at
    /// 24 pt + 8 pt spacing, so below ~236 pt the window itself clips.
    static let minFieldWidth: CGFloat = 140

    /// The Send Later chevron's center, as a fraction of its button's
    /// width (the chevron sits centered under the paperplane).
    static let chevronX: CGFloat = 0.5

    /// Status line: typing on the leading side, queue and ghost state
    /// trailing. Each piece draws nothing when idle, so the line has zero
    /// height then (no blank band under the field) and grows only while
    /// something is shown.
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
                               tagNames: Set(tagNames),
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
        // COMPOSER-B: thread importance/subject/mentions, then reset (a
        // fresh post starts plain).
        conv.send(text: body,
                  importance: composer.importance(for: chatID),
                  subject: isChannel ? composer.subject(for: chatID) : "",
                  mentions: MentionWire.resolve(in: body, channel: isChannel))
        composer.resetSendOptions(chatID: chatID)
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

    /// Evidence `formatbar=1` (demo only): forces the format bar on.
    private var evidenceFormatBar: Bool {
        guard let model, model.options.demo,
              let raw = model.options.route, let route = Route(string: raw) else { return false }
        return route.query["formatbar"] == "1"
    }

    /// Evidence (`popover=<name>`, demo only): opens that popover once.
    /// `draft=multi` prefills three lines (accessory alignment check);
    /// `draft=rich` prefills formatted markdown (format-bar evidence).
    private func applyEvidencePopover() {
        guard let model, model.options.demo, !composer.evidenceApplied,
              let raw = model.options.route, let route = Route(string: raw) else { return }
        composer.evidenceApplied = true
        if route.query["draft"] == "multi" {
            composer.setDraft("Draft line one\nDraft line two\nDraft line three", for: chatID)
        }
        if route.query["draft"] == "rich" {
            composer.setDraft("**Budget** approved, *see notes*\n__Sign here__ and ~~old total~~\n`deploy.sh` at 10", for: chatID)
        }
        // COMPOSER-B evidence: `subject=1` prefills an announcement
        // subject (channels only), `importance=<level>` presets the
        // picker for captures.
        if route.query["subject"] == "1", isChannel {
            composer.setSubject("Weekly sync — ship notes", for: chatID)
        }
        if let level = route.query["importance"] {
            composer.setImportance(MessageImportance.parse(level), for: chatID)
        }
        guard let name = route.query["popover"],
              let p = ComposerPopover(evidenceName: name, lastMessageID: conv.messages.last?.id) else { return }
        // `mentionq=<q>` narrows the picker (exercises the filter path;
        // captures the below-the-fold broadcast specials).
        if p == .mention { composer.setDraft("Thanks @\(route.query["mentionq"] ?? "")", for: chatID) }
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
            Text(line).lineLimit(1).truncationMode(.tail).padding(.top, 4)
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
            .padding(.top, 4)
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
                .padding(.top, 4)
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
    var onFormat: ((ComposerFormatAction) -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    /// Focus asked for before the view had a window, or while its window
    /// was not key.
    var wantsFocus = false
    /// Evidence captures: the field never becomes first responder (a
    /// window restoring focus under a sheet drew the system input-source
    /// badge over the composer, undimmed by the sheet's scrim).
    var refusesFocus = false
    override var acceptsFirstResponder: Bool { refusesFocus ? false : super.acceptsFirstResponder }
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

    /// ⌘Return sends (owner spec; the Return setting only swaps plain
    /// Return and ⇧Return). AppKit has no default binding for it.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘B/I/U (COMPOSER-A): same path as the format bar buttons.
        // Only where the composer wired a handler; elsewhere AppKit
        // keeps the keys.
        if let onFormat, !hasMarkedText(),
           let action = ComposerFormat.shortcutAction(keyCode: event.keyCode, modifiers: event.modifierFlags)
        {
            onFormat(action)
            return
        }
        if flags.contains(.command), event.keyCode == 36 || event.keyCode == 76,
           ComposerKeyPolicy.action(shift: flags.contains(.shift), command: true, markedText: hasMarkedText()) == .send
        {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Applies one format action at the current selection (bar + shortcut
    /// share this path). No-op under marked text (IME guard).
    func applyFormat(_ action: ComposerFormatAction) {
        guard !hasMarkedText() else { return }
        let sel = selectedRange()
        let (newText, newSel) = ComposerFormat.apply(action, to: string, selection: sel)
        guard newText != string else { return }
        // AppKit path (not `string =`): the change flows through
        // `didChangeText`, so the coordinator remeasures and the draft
        // binding updates exactly like a typed edit.
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: newText) else { return }
        textStorage?.replaceCharacters(in: full, with: newText)
        didChangeText()
        setSelectedRange(newSel)
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
    /// Format request (COMPOSER-A): the conversation composer drives
    /// these; other islands (channel reply) leave the defaults, which
    /// disable formatting there.
    let formatSeq: Int
    let formatAction: ComposerFormatAction
    let onSubmit: () -> Void
    let onCommand: (Selector) -> Bool
    /// Nil outside the conversation composer (channel reply island):
    /// without it ⌘B/I/U fall through to AppKit untouched.
    let onFormat: ((ComposerFormatAction) -> Void)?
    let onPasteFiles: ([URL]) -> Void

    init(text: Binding<String>, height: Binding<CGFloat>, focusRequest: Int, scale: Double,
         formatSeq: Int = 0, formatAction: ComposerFormatAction = .bold,
         onSubmit: @escaping () -> Void, onCommand: @escaping (Selector) -> Bool,
         onFormat: ((ComposerFormatAction) -> Void)? = nil,
         onPasteFiles: @escaping ([URL]) -> Void)
    {
        _text = text
        _height = height
        self.focusRequest = focusRequest
        self.scale = scale
        self.formatSeq = formatSeq
        self.formatAction = formatAction
        self.onSubmit = onSubmit
        self.onCommand = onCommand
        self.onFormat = onFormat
        self.onPasteFiles = onPasteFiles
    }

    static let maxLines: CGFloat = 8
    /// The field is always at least this many lines tall (owner: "2 lines
    /// tall"); ComposerLayoutTests guards it.
    static let minLines: CGFloat = 2

    /// Shortest field height at `scale`: `minLines` lines.
    static func minFieldHeight(_ scale: Double) -> CGFloat {
        lineHeight(scale) * minLines
    }

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
        tv.refusesFocus = context.environment.windowModel?.options.evidence == true
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
        tv.onFormat = onFormat
        tv.onPasteFiles = onPasteFiles
        if formatSeq != c.lastFormatSeq {
            c.lastFormatSeq = formatSeq
            let action = formatAction
            // Outside the update cycle: applying mutates the draft
            // binding (same as a typed edit).
            DispatchQueue.main.async { tv.applyFormat(action) }
        }
        tv.refusesFocus = context.environment.windowModel?.options.evidence == true
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

    /// Height for `text` at `width`: `minLines`…`maxLines` lines of `font`.
    static func height(for text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: font)
        guard width > 1 else { return (line * minLines).rounded(.up) }
        var measured = text.isEmpty ? " " : text
        if measured.hasSuffix("\n") { measured += " " }
        let h = (measured as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return min(max(h, line * minLines), line * maxLines).rounded(.up)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        weak var scroll: NSScrollView?
        var lastFocus = -1
        var lastFormatSeq = 0
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

