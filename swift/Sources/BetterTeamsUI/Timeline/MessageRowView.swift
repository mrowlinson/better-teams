// MessageRowView.swift — one timeline message row (UI-SPEC §6.2.1).
//
// Header name (`.headline`) + time (`.caption`); body from MessageRender
// with mentions tinted and code monospaced on `.fill.quaternary`; reply
// quote; images in reserved slots (R13); file chips; adaptive/bot cards with native
// buttons; link preview; reaction chips; edited marker; translation;
// "Seen by …" on the last own message. In chats every message sits on
// a bubble, no tails: own trailing on the accent wash, others leading on
// a neutral fill under avatar + name/time (first of a run only);
// reactions hang under the bubble. Channel posts stay unbubbled. Send state is one cue on its own
// line under the card (symbol + words), so it never shifts the text.
// Rows are values: everything that changes height is in
// `MessageRowData`, whose `extraRevision` feeds the height cache.
import OstMacCore
import SwiftUI

/// Send state of one bubble (reserved slot, R13).
enum SendState: Equatable {
    case none, sending, failed

    static func of(_ m: ChatMessage, failed: Set<String>) -> SendState {
        if failed.contains(m.id) { return .failed }
        return m.isOwn && m.id.hasPrefix("pending-") ? .sending : .none
    }
}

/// Reply-quote block content.
struct QuoteData: Equatable {
    let sender: String
    let preview: String
    /// Parent still in history (click jumps), else nil.
    let jumpID: String?
}

/// Everything one row renders (pure value; `TimelineViewController`
/// builds it from the stores).
struct MessageRowData {
    let message: ChatMessage
    let showsHeader: Bool
    let send: SendState
    let quote: QuoteData?
    let receipt: ReceiptDisplay
    let translation: TranslatedEntry?
    let isPinned: Bool
    let isSaved: Bool
    let ownName: String?
    let chatID: String?
    /// Chat bubble style (Teams chats): own messages trailing on an
    /// accent-tinted bubble, no avatar or name; everyone else leading on
    /// a neutral bubble with avatar + name/time on the first of a run.
    /// Channel posts and threads keep every post leading, unbubbled.
    var bubble: RowBubble = .none
    var ownTrailing: Bool { bubble == .own }
    /// Shared files the message's `<attachment id>` refs resolve to
    /// (file chips); empty until the conversation's files load.
    var docs: [InlineDoc] = []

    /// Revision of the row state not covered by `TimelineItem.revision`
    /// (FNV-1a, stable across launches).
    var extraRevision: Int { MessageRowData.extraRevision(send: send, receipt: receipt,
                                                          translation: translation,
                                                          pinned: isPinned, saved: isSaved, docs: docs) }

    static func extraRevision(send: SendState, receipt: ReceiptDisplay, translation: TranslatedEntry?,
                              pinned: Bool, saved: Bool, docs: [InlineDoc] = []) -> Int {
        var h: UInt64 = 14_695_981_039_346_656_037
        func mix(_ s: String) {
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
            h = (h ^ 0xff) &* 1_099_511_628_211
        }
        mix("\(send)")
        mix(receipt.accessibilityLabel)
        if let t = translation { mix("\(t.state.rawValue)\(t.isVisible)\(t.text)") } else { mix("-") }
        mix("\(pinned)\(saved)")
        if !docs.isEmpty { mix(docs.map { "\($0.id)|\($0.name)|\($0.file.size)" }.joined(separator: "/")) }
        return Int(truncatingIfNeeded: h & 0x7fff_ffff_ffff_ffff)
    }
}

/// Bubble a timeline row sits on.
enum RowBubble: Equatable {
    /// Channel posts and thread replies: plain leading rows.
    case none
    /// Own chat message: trailing, accent-tinted.
    case own
    /// Someone else's chat message: leading, neutral fill.
    case other

    static func of(_ m: ChatMessage, scope: TimelineScope) -> RowBubble {
        guard scope == .conversation else { return .none }
        return m.isOwn ? .own : .other
    }
}

/// One body segment: prose (inline code stays inline) or a code block.
struct BodySegment: Identifiable {
    let id: Int
    let text: AttributedString
    let isBlock: Bool
}

struct MessageRowView: View {
    let row: MessageRowData
    let highlighted: Bool
    let staticHighlight: Bool
    let actions: TimelineActions?
    @Environment(\.contentTextScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.windowModel) private var model

    private var message: ChatMessage { row.message }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.ownTrailing {
                Spacer(minLength: 78)
                VStack(alignment: .trailing, spacing: 4) {
                    if row.showsHeader { ownHeader }
                    card
                    bubbleReactions
                    sendStatus
                    if row.receipt.isVisible { receipt }
                }
            } else {
                Group {
                    // Own posts (channels, threads): initials from the owner's name.
                    if row.showsHeader {
                        Avatar(name: message.isOwn ? (model?.ownDisplayName ?? message.sender) : message.sender)
                    } else { Color.clear }
                }
                .frame(width: 28, height: row.showsHeader ? 28 : 1)
                VStack(alignment: .leading, spacing: 4) {
                    if row.showsHeader { header }
                    card
                    bubbleReactions
                    sendStatus
                    if row.receipt.isVisible { receipt }
                }
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, row.showsHeader ? 8 : 2)
        .padding(.bottom, 2)
        .background { highlight }
        .contentShape(Rectangle())
        .onHover { inside in actions?.hover.pointer(inside, id: message.id) }
        .contextMenu { if let actions { MessageContextMenu(row: row, actions: actions) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .modifier(MessageAccessibilityActions(row: row, actions: actions))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(message.isOwn ? "You" : message.sender)
                .font(AppFont.headline(scale))
                .lineLimit(1)
            Text(Self.time(message.timestamp))
                .font(AppFont.caption(scale))
                .foregroundStyle(.secondary)
                .fixedSize()
            if message.edited && !message.deleted {
                Text("Edited").font(AppFont.caption(scale)).foregroundStyle(.secondary).fixedSize()
            }
            if row.isPinned {
                Image(systemName: "pin.fill").font(AppFont.caption(scale)).foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
    }

    /// Own chat messages: time (and Edited, pin) over the card, no name.
    private var ownHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if row.isPinned {
                Image(systemName: "pin.fill").font(AppFont.caption(scale)).foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            if message.edited && !message.deleted {
                Text("Edited").font(AppFont.caption(scale)).foregroundStyle(.secondary).fixedSize()
            }
            Text(Self.time(message.timestamp))
                .font(AppFont.caption(scale))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// The message content. Chat messages sit on a bubble — own on the
    /// accent tint, others on a neutral fill — with one set of metrics
    /// (padding, radius, max width) so both read as one design.
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let q = row.quote { QuoteBlock(quote: q, jump: { actions?.jump(to: $0) }) }
            content
            if let t = row.translation, t.isVisible { translation(t) }
            if !row.showsHeader && message.edited && !message.deleted {
                Text("Edited").font(AppFont.caption(scale)).foregroundStyle(.secondary)
            }
            if row.bubble == .none { reactions }
        }
        .padding(.horizontal, row.bubble == .none ? 0 : 12)
        .padding(.vertical, row.bubble == .none ? 0 : 8)
        .background {
            switch row.bubble {
            case .none: EmptyView()
            case .own: RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ownCard)
            case .other: RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.otherCard)
            }
        }
        .overlay {
            // Increased contrast: an edge, so the bubble never rests on fill alone.
            if row.bubble != .none && contrast == .increased {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator)
            }
        }
        // Hover toolbar over the bubble's top edge; an overlay, so no layout shift.
        .overlay(alignment: HoverToolbarRules.alignment(ownTrailing: row.ownTrailing)) {
            if let actions { HoverToolbarSlot(row: row, actions: actions) }
        }
    }

    /// Reaction chips: under a chat bubble (Teams), inside a plain post.
    @ViewBuilder
    private var reactions: some View {
        if !message.reactions.isEmpty && !message.deleted {
            ReactionChips(reactions: message.reactions) { actions?.toggleReaction(message, $0) }
        }
    }

    @ViewBuilder
    private var bubbleReactions: some View {
        if row.bubble != .none { reactions }
    }

    @ViewBuilder
    private var content: some View {
        if message.deleted {
            Text("This message has been deleted.")
                .font(AppFont.body(scale))
                .italic()
                .foregroundStyle(.secondary)
        } else {
            let text = MessageRender.bubbleText(for: message)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(Self.segments(MessageRender.attributedBody(text: text, raw: message.raw,
                                                                   highlighting: row.ownName),
                                      scale: scale)) { seg in
                    if seg.isBlock {
                        CodeBlockView(text: seg.text)
                    } else {
                        Text(seg.text)
                            .font(AppFont.body(scale))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let images = MessageRender.images(fromRaw: message.raw).filter { !$0.isEmoticon }
            if !images.isEmpty, let actions {
                MessageImages(images: images, messageID: message.id, media: actions.media,
                              open: { actions.preview(image: $0) },
                              save: { actions.save(image: $0, alt: $1, choose: $2) })
            }
            if !row.docs.isEmpty {
                FileChips(docs: row.docs, actions: actions)
            }
            let cards = MessageBubbleState.cards(for: message)
            ForEach(Indexed.wrap(cards)) { c in
                AdaptiveCardView(card: c.value, media: actions?.media, messageID: message.id,
                                 open: actions.map { a in { a.preview(image: $0) } })
            }
            let posts = MessageRender.botPosts(fromRaw: message.raw ?? message.content)
            if MessageBubbleState.shouldShowFallbackRows(posts: posts, cards: cards) {
                BotPostRows(posts: posts)
            }
            if let url = LinkPreviewRules.previewURL(for: message), let actions {
                LinkPreviewCard(model: actions.media.preview(url: url))
            }
            if row.docs.isEmpty && MessageRender.showsPlaceholder(for: message) {
                HStack(spacing: 8) {
                    Text("This message can't be shown here.")
                        .font(AppFont.body(scale))
                        .foregroundStyle(.secondary)
                    Button("Open in Teams") {
                        CardLinks.open(CardActions.fallbackURL(chatID: row.chatID, messageID: message.id).absoluteString)
                    }
                    .buttonStyle(.link)
                    .font(AppFont.body(scale))
                }
            }
        }
    }

    private func translation(_ t: TranslatedEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch t.state {
            case .pending:
                Text("Translating…").font(AppFont.caption(scale)).foregroundStyle(.secondary)
            case .failed:
                Text("Couldn't translate this message.").font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
            case .sameLanguage:
                Text("Already in \(MessageTranslation.displayName(for: t.targetCode)).")
                    .font(AppFont.caption(scale)).foregroundStyle(.secondary)
            case .translated:
                Label("Translated from \(t.sourceCode.map(MessageTranslation.displayName(for:)) ?? "another language")",
                      systemImage: "translate")
                    .font(AppFont.caption(scale))
                    .foregroundStyle(.secondary)
                Text(t.text)
                    .font(AppFont.body(scale))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 2)
        }
    }

    private var receipt: some View {
        HStack(spacing: 4) {
            switch row.receipt {
            case .none: EmptyView()
            case .sent:
                Image(systemName: "checkmark")
                Text("Sent")
            case .seen:
                Image(systemName: "eye")
                Text("Seen")
            case .seenBy(let readers):
                Image(systemName: "eye")
                Text("Seen by \(readers.count)")
            }
        }
        .font(AppFont.caption(scale))
        .foregroundStyle(.secondary)
        .help(Self.readersHelp(row.receipt))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.receipt.accessibilityLabel)
    }

    static func readersHelp(_ r: ReceiptDisplay) -> String {
        if case .seenBy(let readers) = r { return "Seen by " + readers.joined(separator: ", ") }
        return r.accessibilityLabel
    }

    /// Send state (§6.2.1, R13): one cue — symbol and words together —
    /// on its own line under the card, leading-aligned with it, so the
    /// message text never moves when the state changes.
    @ViewBuilder
    private var sendStatus: some View {
        switch row.send {
        case .none: EmptyView()
        case .sending:
            Label("Sending…", systemImage: "clock")
                .font(AppFont.caption(scale))
                .foregroundStyle(.secondary)
                .help("Sending")
        case .failed:
            Label("Not Sent", systemImage: "exclamationmark.circle")
                .font(AppFont.caption(scale))
                .foregroundStyle(Palette.failed)
                .help("Not sent. Retry or delete it from the message's context menu.")
        }
    }

    @ViewBuilder
    private var highlight: some View {
        if highlighted {
            if staticHighlight || reduceMotion {
                Rectangle().fill(Palette.messageHighlight)
            } else {
                Rectangle().fill(Palette.messageHighlight)
                    .keyframeAnimator(initialValue: 1.0, repeating: false) { v, opacity in
                        v.opacity(opacity)
                    } keyframes: { _ in
                        LinearKeyframe(1.0, duration: 0.6)
                        LinearKeyframe(0.0, duration: 0.9)
                    }
            }
        }
    }

    private var accessibilityText: String {
        var parts = [message.isOwn ? "You" : message.sender, Self.time(message.timestamp),
                     message.deleted ? "Deleted message" : MessageRender.bubbleText(for: message)]
        for d in row.docs { parts.append("File \(d.name), \(d.sizeLabel)") }
        let n = message.reactions.reduce(0) { $0 + $1.count }
        if n > 0 { parts.append(n == 1 ? "1 reaction" : "\(n) reactions") }
        if row.send == .failed { parts.append("Not Sent") }
        if row.send == .sending { parts.append("Sending") }
        return parts.joined(separator: ", ")
    }

    /// Splits the semantic body into prose and code-block segments and
    /// maps runs to the palette: mentions tinted (own: tinted
    /// background too), inline code monospaced on `.fill.quaternary`.
    /// AppKit font for selectable text. `NSFont` is not `Sendable`, so
    /// the typed `appKit.font` setter (which requires a `Sendable` value)
    /// warns; the attribute-dictionary container sets the same `.font`
    /// attribute without that requirement (NSFont is immutable and
    /// thread-safe).
    private static func setAppKitFont(_ font: NSFont, on piece: inout AttributedString) {
        piece.mergeAttributes(AttributeContainer([.font: font]))
    }

    static func segments(_ s: AttributedString, scale: Double) -> [BodySegment] {
        var out: [BodySegment] = []
        var current = AttributedString()
        var currentIsBlock = false
        func flush() {
            var t = current
            // Trim the newline that separated a block from prose.
            while t.characters.last == "\n" { t.removeSubrange(t.characters.index(before: t.endIndex)..<t.endIndex) }
            while t.characters.first == "\n" { t.removeSubrange(t.startIndex..<t.characters.index(after: t.startIndex)) }
            if !t.characters.isEmpty { out.append(BodySegment(id: out.count, text: t, isBlock: currentIsBlock)) }
            current = AttributedString()
        }
        for run in s.runs {
            let role = run[MessageTextAttributes.CodeRoleAttribute.self]
            let isBlock = role == .block || role == .preformatted
            if isBlock != currentIsBlock {
                flush()
                currentIsBlock = isBlock
            }
            var piece = AttributedString(s[run.range])
            // Both scopes: SwiftUI draws `swiftUI` runs; selectable text
            // (`textSelection`) draws through the AppKit attributes.
            if let m = run[MessageTextAttributes.MentionAttribute.self] {
                piece.swiftUI.foregroundColor = Palette.mention
                piece.swiftUI.font = AppFont.bodyEmphasized(scale)
                piece.appKit.foregroundColor = Palette.mentionNS
                setAppKitFont(AppFont.nsBodyEmphasized(scale), on: &piece)
                if m == .own {
                    piece.swiftUI.foregroundColor = Palette.ownMentionText
                    piece.appKit.foregroundColor = Palette.ownMentionTextNS
                    piece.swiftUI.backgroundColor = Palette.ownMentionBackground
                    piece.appKit.backgroundColor = Palette.ownMentionBackgroundNS
                }
            }
            if role == .inline {
                piece.swiftUI.font = AppFont.code(scale)
                piece.swiftUI.backgroundColor = Palette.blockFill
                setAppKitFont(AppFont.nsCode(scale), on: &piece)
                piece.appKit.backgroundColor = Palette.inlineCodeBackgroundNS
            } else if isBlock {
                piece.swiftUI.font = AppFont.code(scale)
                setAppKitFont(AppFont.nsCode(scale), on: &piece)
            }
            current.append(piece)
        }
        flush()
        return out
    }

    /// P1 name kept for callers: the whole body styled as one string.
    static func styled(_ s: AttributedString, scale: Double) -> AttributedString {
        segments(s, scale: scale).reduce(into: AttributedString()) { acc, seg in
            if !acc.characters.isEmpty { acc.append(AttributedString("\n")) }
            acc.append(seg.text)
        }
    }

    static func time(_ iso: String) -> String {
        guard let d = TeamsTime.parseISO(iso) else { return "" }
        return TeamsTime.clock(d)
    }
}

/// Stable positional identity for bounded, immutable per-message lists
/// (cards, facts): the list only changes with the message revision.
struct Indexed<T>: Identifiable {
    let id: Int
    let value: T

    static func wrap(_ list: [T]) -> [Indexed<T>] {
        var out: [Indexed<T>] = []
        out.reserveCapacity(list.count)
        for v in list { out.append(Indexed(id: out.count, value: v)) }
        return out
    }
}

/// VoiceOver: every context action is also an accessibility action.
private struct MessageAccessibilityActions: ViewModifier {
    let row: MessageRowData
    let actions: TimelineActions?

    func body(content: Content) -> some View {
        if let a = actions {
            let m = row.message
            content
                .accessibilityAction(named: "Reply") { a.reply(m) }
                .accessibilityAction(named: "React") { a.moreReactions(m) }
                .accessibilityAction(named: "Copy") { a.copy(m) }
                .accessibilityAction(named: "Forward") { a.forward(m) }
                .accessibilityAction(named: row.isSaved ? "Unsave" : "Save") { a.toggleSave(m) }
                .accessibilityAction(named: row.isPinned ? "Unpin" : "Pin") { a.togglePin(m) }
                .accessibilityActions {
                    // The hover toolbar's quick reactions.
                    if HoverToolbarRules.isAvailable(row) {
                        ForEach(Indexed.wrap(HoverToolbarRules.quickReactions)) { r in
                            Button("React \(r.value.name)") { a.toggleReaction(m, r.value.emoji) }
                        }
                    }
                }
        } else {
            content
        }
    }
}

/// Pure row-state rules (unit-tested).
@MainActor
enum TimelineRowState {
    /// "Seen by …" sits on the last own message only (§6.2.1): while
    /// that message is still sending or failed, no row shows a receipt
    /// (an older message's receipt would read as this one's).
    static func receiptTarget(_ messages: [ChatMessage], failed: Set<String>) -> String? {
        guard let last = messages.last(where: { $0.isOwn && !$0.deleted }),
              SendState.of(last, failed: failed) == .none else { return nil }
        return last.id
    }

    /// Quote for a reply: the parent from history (click jumps), else
    /// the author + text of the raw `<quote>` block, else a neutral stub.
    static func quote(for m: ChatMessage, in byID: [String: ChatMessage]) -> QuoteData? {
        guard let parentID = m.reply_to?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentID.isEmpty else { return nil }
        if let p = byID[parentID] {
            let text = p.deleted ? "This message has been deleted." : MessageRender.bubbleText(for: p)
            return QuoteData(sender: p.isOwn ? "You" : p.sender,
                             preview: ConversationStore.quotePreview(text), jumpID: p.id)
        }
        if let raw = m.raw, let q = rawQuote(raw) {
            return QuoteData(sender: q.author, preview: ConversationStore.quotePreview(q.text), jumpID: nil)
        }
        return QuoteData(sender: "Earlier message", preview: "Not loaded", jumpID: nil)
    }

    /// `<quote author="X" …>text</quote>` → (X, stripped text).
    static func rawQuote(_ raw: String) -> (author: String, text: String)? {
        guard let open = raw.range(of: "<quote", options: .caseInsensitive),
              let gt = raw[open.upperBound...].firstIndex(of: ">"),
              let close = raw[gt...].range(of: "</quote>", options: .caseInsensitive)
        else { return nil }
        let attrs = raw[open.upperBound..<gt]
        var author = "Earlier message"
        if let a = attrs.range(of: "author=\"") , let end = attrs[a.upperBound...].firstIndex(of: "\"") {
            author = MessageRender.decodeEntities(String(attrs[a.upperBound..<end]))
        }
        let inner = String(raw[raw.index(after: gt)..<close.lowerBound])
        let text = MessageRender.decodeEntities(MessageRender.stripTags(inner))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (author, text)
    }

    /// Item revision ⊕ row-state revision (FNV-1a mix, stable).
    static func combine(_ a: Int, _ b: Int) -> Int {
        var h = UInt64(bitPattern: Int64(a))
        h = (h ^ UInt64(bitPattern: Int64(b))) &* 1_099_511_628_211
        return Int(truncatingIfNeeded: h & 0x7fff_ffff_ffff_ffff)
    }
}
