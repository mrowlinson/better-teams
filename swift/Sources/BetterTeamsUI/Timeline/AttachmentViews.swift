// AttachmentViews.swift — rich content inside a timeline row (UI-SPEC
// §6.2.1): reply quote, code block, images (reserved 240×160 aspect-fit
// slots, R13; click → full-resolution ImageViewer), adaptive/bot cards with native
// buttons, file chips, link preview (fixed height whatever its phase), reaction
// chips. Every view here keeps its final size before data arrives, so a
// load never changes a row's height.
import AppKit
import OstMacCore
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Image slot size when dimensions are unknown (R13).
enum MediaSlot {
    static let size = CGSize(width: 240, height: 160)
}

struct QuoteBlock: View {
    let quote: QuoteData
    let jump: (String) -> Void
    @Environment(\.contentTextScale) private var scale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            Text(quote.sender).font(AppFont.caption(scale).weight(.semibold)).lineLimit(1)
            Text(quote.preview).font(AppFont.subheadline(scale))
                .foregroundStyle(contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Palette.quoteText))
                .lineLimit(2)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Palette.blockFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(Palette.mention).frame(width: 2) }
        if let id = quote.jumpID {
            Button { jump(id) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Show Original Message")
                .accessibilityLabel("Reply to \(quote.sender): \(quote.preview)")
        } else {
            content.accessibilityLabel("Reply to \(quote.sender): \(quote.preview)")
        }
    }
}

struct CodeBlockView: View {
    let text: AttributedString
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        Text(text)
            .font(AppFont.code(scale))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.blockFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.panelEdge, lineWidth: 1)
            }
            .accessibilityLabel("Code: \(String(text.characters))")
    }
}

struct MessageImages: View {
    let images: [MessageRender.RichImage]
    let messageID: String
    let media: MediaLoader
    let open: (RemoteImageModel) -> Void
    /// Save to Downloads (false) or Save As… (true).
    var save: ((RemoteImageModel, String, Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(images) { img in
                let model = media.image(url: img.url, messageID: messageID)
                ImageSlot(model: model, alt: img.alt, open: open,
                          save: save.map { s in { choose in s(model, img.alt, choose) } })
            }
        }
    }
}

/// One image in its reserved slot: placeholder while loading, the
/// picture aspect-fit once decoded, an inline notice on failure.
struct ImageSlot: View {
    @ObservedObject var model: RemoteImageModel
    let alt: String
    let open: (RemoteImageModel) -> Void
    /// Timeline images: Save to Downloads (false) / Save As… (true).
    var save: ((Bool) -> Void)?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.fill.quaternary)
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed:
                Label("Image Unavailable", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded:
                if let clip = model.gif, clip.frames.count > 1 {
                    GifBubblePlayer(clip: clip)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let img = model.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .frame(width: MediaSlot.size.width, height: MediaSlot.size.height)
        .contentShape(Rectangle())
        .onTapGesture { if model.image != nil { open(model) } }
        .contextMenu {
            if let save, model.image != nil {
                Button("Save Image to \u{201C}Downloads\u{201D}") { save(false) }
                Button("Save Image As\u{2026}") { save(true) }
            }
        }
        .help(alt.isEmpty ? "Image" : alt)
        .accessibilityElement()
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .accessibilityAddTraits(.isImage)
        .accessibilityAction { if model.image != nil { open(model) } }
    }
}

/// Play/pause clock of one bubble GIF: seconds banked when last paused
/// and when it last resumed (nil = paused). The frame is a pure function
/// of the clock and the tick date, so drawing never mutates state.
struct GifPlaybackClock: Equatable {
    var banked = 0.0
    var resumedAt: Date?

    var playing: Bool { resumedAt != nil }

    /// Loop time at `now`.
    func playhead(now: Date, total: Double) -> Double {
        guard total > 0 else { return 0 }
        let t = banked + (resumedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        return t.truncatingRemainder(dividingBy: total)
    }

    mutating func play(now: Date) { if resumedAt == nil { resumedAt = now } }

    mutating func pause(now: Date, total: Double) {
        guard playing else { return }
        banked = playhead(now: now, total: total)
        resumedAt = nil
    }

    mutating func toggle(now: Date, total: Double) {
        if playing { pause(now: now, total: total) } else { play(now: now) }
    }
}

/// An animated GIF in a bubble (om-gif-playback, e4fe679): loops the
/// decoded clip on display ticks with a native Play/Pause button over it.
/// Reduce Motion opens paused on the first frame; pressing Play always
/// animates. Clicks elsewhere still open the viewer.
struct GifBubblePlayer: View {
    let clip: GifClip
    @State private var clock = GifPlaybackClock()
    @State private var started = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !clock.playing)) { ctx in
            let t = clock.playhead(now: ctx.date, total: clip.totalDuration)
            Image(nsImage: clip.frames[GifClip.frameIndex(at: t, durations: clip.durations)])
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
        .overlay(alignment: .bottomLeading) {
            Button { clock.toggle(now: Date(), total: clip.totalDuration) } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .background(.regularMaterial, in: Circle())
            .padding(6)
            .help(clock.playing ? "Pause GIF" : "Play GIF")
            .accessibilityLabel(clock.playing ? "Pause GIF" : "Play GIF")
        }
        .onAppear {
            guard !started else { return }
            started = true
            if GifPlayback.initiallyPlaying(animated: true, reduceMotion: reduceMotion) { clock.play(now: Date()) }
        }
        // Reduce Motion turning on pauses; turning off resumes autoplay.
        .onChange(of: reduceMotion) { _, now in
            if now { clock.pause(now: Date(), total: clip.totalDuration) } else { clock.play(now: Date()) }
        }
    }
}

struct AdaptiveCardView: View {
    let card: AdaptiveCard
    let media: MediaLoader?
    let messageID: String
    /// Click on a card image: the full-resolution viewer (shown alone,
    /// card images are not in the chat's inline-image run).
    var open: ((RemoteImageModel) -> Void)?
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Indexed.wrap(card.body)) { e in element(e.value) }
            if !card.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Indexed.wrap(card.actions)) { a in
                        Button(a.value.title) { CardLinks.open(a.value.url) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 1)
        }
    }

    private func element(_ e: AdaptiveCard.Element) -> AnyView {
        switch e {
        case .text(let t):
            return AnyView(Text(t.text)
                .font(font(t))
                .foregroundStyle(t.isSubtle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(t.wrap ? nil : 1)
                .fixedSize(horizontal: false, vertical: true))
        case .facts(let facts):
            return AnyView(Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                ForEach(Indexed.wrap(facts)) { f in
                    GridRow {
                        Text(f.value.title).foregroundStyle(.secondary)
                        Text(f.value.value)
                    }
                    .font(AppFont.subheadline(scale))
                }
            })
        case .image(let img):
            if let media {
                return AnyView(ImageSlot(model: media.image(url: img.url, messageID: messageID),
                                         alt: img.altText, open: open ?? { _ in }))
            }
            return AnyView(EmptyView())
        case .container(let items):
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                ForEach(Indexed.wrap(items)) { i in element(i.value) }
            })
        case .columns(let cols):
            return AnyView(HStack(alignment: .top, spacing: 12) {
                ForEach(Indexed.wrap(cols)) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Indexed.wrap(c.value)) { i in element(i.value) }
                    }
                }
            })
        }
    }

    private func font(_ t: AdaptiveCard.TextBlock) -> Font {
        let base: Font = switch t.size {
        case .small: AppFont.subheadline(scale)
        case .default: AppFont.body(scale)
        case .medium, .large, .extraLarge: AppFont.title3(scale)
        }
        return t.weight == .bolder ? base.weight(.semibold) : base
    }
}

/// RSS/bot posts without a card: one native link row per post.
struct BotPostRows: View {
    let posts: [MessageRender.BotPost]
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Indexed.wrap(posts)) { p in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(p.value.title, systemImage: p.value.url == nil ? "doc.text" : "link")
                        .font(AppFont.bodyEmphasized(scale))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = p.value.url {
                        Button("Open") { CardLinks.open(url) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(url)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 1)
        }
    }
}

/// File chips (§6.2.1): one native chip per shared file a message
/// references: Finder icon, name, size. Clicking the chip opens the
/// file; its ⋯ menu and context menu hold Open, Save to Downloads, Save
/// As…, Copy Link. Fixed height (32 pt icon), so rows measure once.
struct FileChips: View {
    let docs: [InlineDoc]
    let actions: TimelineActions?
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(docs) { d in chip(d) }
        }
    }

    private func chip(_ d: InlineDoc) -> some View {
        HStack(spacing: 8) {
            Button {
                actions?.openFile(d)
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(d.name))
                        .resizable()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(AppFont.bodyEmphasized(scale)).lineLimit(1).truncationMode(.middle)
                        Text(d.sizeLabel).font(AppFont.caption(scale)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(d.name)")
            Menu {
                menuItems(d)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More Actions for \(d.name)")
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 1)
        }
        .contextMenu { menuItems(d) }
    }

    @ViewBuilder
    private func menuItems(_ d: InlineDoc) -> some View {
        Button("Open") { actions?.openFile(d) }
        Divider()
        Button("Save to Downloads") { actions?.saveFile(d, choose: false) }
        Button("Save As\u{2026}") { actions?.saveFile(d, choose: true) }
        Button("Copy Link") { actions?.copyLink(file: d) }
    }

    /// Finder icon for the file name's type.
    static func icon(_ name: String) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
    }
}

/// Link preview: two fixed lines (title, host) in every phase, so the
/// row height never changes when the preview resolves or collapses.
struct LinkPreviewCard: View {
    @ObservedObject var model: LinkPreviewModel
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        let url = URL(string: model.urlString)
        let title: String = switch model.phase {
        case .loaded(let p): p.title
        case .loading, .collapsed: url?.host ?? model.urlString
        }
        let host: String = switch model.phase {
        case .loaded(let p): p.host
        case .loading: "Loading preview…"
        case .collapsed: model.urlString
        }
        Button { CardLinks.open(model.urlString) } label: {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(AppFont.bodyEmphasized(scale)).lineLimit(1)
                    Text(host).font(AppFont.caption(scale)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: 360, alignment: .leading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.panelEdge, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.urlString)
        .accessibilityLabel("Link: \(title)")
    }
}

struct ReactionChips: View {
    let reactions: [ReactionCount]
    let toggle: (String) -> Void
    @Environment(\.contentTextScale) private var scale
    @Environment(\.windowModel) private var model

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.emoji) { r in
                let who = names(r)
                Button { toggle(r.emoji) } label: {
                    Text("\(r.emoji) \(r.count)").font(AppFont.caption(scale).monospacedDigit())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(who.isEmpty ? "React with \(r.emoji)" : "\(ListFormatter.localizedString(byJoining: who)) reacted with \(r.emoji)")
                .accessibilityLabel(who.isEmpty ? "\(r.emoji), \(r.count)"
                                    : "\(r.emoji), \(r.count): \(ListFormatter.localizedString(byJoining: who))")
            }
        }
    }

    /// Who reacted (core-a `ReactionCount.reactors`): wire names, else
    /// the chat roster's; you as "You" (by id), listed first.
    private func names(_ r: ReactionCount) -> [String] {
        let roster = model?.app?.chatRoster
        var you = false
        var others: [String] = []
        for reactor in r.reactors {
            if model?.isOwnID(reactor.id) == true { you = true; continue }
            let one = ReactionCount(emoji: r.emoji, count: 1, reactors: [reactor])
            if let n = one.reactorNames(resolve: { roster?.displayName(forID: $0) }).first { others.append(n) }
        }
        return (you ? ["You"] : []) + others
    }
}

/// Opens card/link targets: https only, in the default browser.
enum CardLinks {
    static func open(_ raw: String) {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return }
        TeamsLinkRouter.open(url)
    }
}

/// Timeline image saves (chat attachments): ~/Downloads by default,
/// never overwriting (Finder-style " 2" suffix), listed in Transfers
/// and Files ▸ Downloads like every other download.
enum ImageSave {
    /// Saved file name: the alt text when it names the image, else
    /// "Image"; `.png` for re-encoded decodes, the original's extension
    /// for viewer saves of original bytes.
    static func filename(alt: String, ext: String = "png") -> String {
        let a = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (TeamsFrameDownloads.sanitizedFilename(a) as NSString).deletingPathExtension
        return (a.isEmpty || stem.isEmpty || stem.lowercased() == "image" ? "Image" : stem) + "." + ext
    }

    /// First free path for `name` in `dir`: "name.png", "name 2.png", …
    static func uniqueDestination(dir: URL, name: String, exists: (String) -> Bool) -> URL {
        var dest = dir.appendingPathComponent(name)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 1
        while exists(dest.path) {
            n += 1
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        return dest
    }

    /// Bytes + type to save for a timeline image: the original the
    /// viewer would load (full-res URL, original encoding); the on-screen
    /// decode as PNG only when that fetch fails.
    @MainActor
    static func bytes(original: FullResImageModel, fallback: NSImage?) async -> (Data, UTType)? {
        if original.originalData == nil { await original.reload() }
        if let d = original.originalData { return (d, original.originalType ?? .png) }
        return fallback.flatMap(png).map { ($0, .png) }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension CardLinks {
    static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let t = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return t.isEmpty ? "image" : String(t.prefix(60))
    }
}
