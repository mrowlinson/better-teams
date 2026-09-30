// NotesViews.swift — OneNote page list, page, and Append field (UI-SPEC
// §6.2 Notes tab, §6.7 OneNote). Shared by the conversation Notes tab
// and the OneNote app; each passes its own `NotesStore`.
import AppKit
import OstMacCore
import SwiftUI

/// What the page side shows. Titles state the condition (R18).
enum NotesPaneState: Equatable {
    case loading
    case error(title: String, message: String)
    case noNotebooks
    case noSections
    case noPages
    case noSelection
    case page

    static let noNotebooksTitle = "No Notebooks"
    static let errorTitle = "Couldn\u{2019}t Load Notes"
    static let offlineTitle = "You\u{2019}re Offline"
    static let offlineMessage = "Your notes appear when you\u{2019}re back online."

    static func resolve(_ state: NotesState, notebooks: Int, sections: Int, pages: Int, hasPage: Bool,
                        sectionSelected: Bool, forced: ForcedPaneState?, offline: Bool) -> NotesPaneState {
        func failed(_ m: String) -> NotesPaneState {
            offline ? .error(title: offlineTitle, message: offlineMessage) : .error(title: errorTitle, message: m)
        }
        switch forced {
        case .loading: return .loading
        case .empty: return .noNotebooks
        case .error: return failed("Something went wrong.")
        case nil: break
        }
        if hasPage { return .page }
        switch state {
        case .idle, .loading: return .loading
        case .error(let m): return failed(m)
        case .loaded: break
        }
        switch NotesStore.contentState(notebooksEmpty: notebooks == 0, sectionsEmpty: sections == 0, loading: false) {
        case .noNotebooks: return .noNotebooks
        case .noSections, .loadingSections: return .noSections
        case .browse: return sectionSelected && pages == 0 ? .noPages : .noSelection
        }
    }
}

extension NotesStore {
    /// Select a page in any section of the open notebook.
    func show(pageID: String, sectionID: String) {
        if selectedSectionID != sectionID { selectSection(sectionID) }
        selectPage(pageID)
    }

    /// Try Again: reopen the same scope (demo stays offline).
    func retry() {
        if isDemo { showDemo() } else { open(groupID: groupID) }
    }
}

/// Notes tab page list: notebook picker (when there are several), then
/// the notebook's sections with their pages.
struct NotesPageList: View {
    @ObservedObject var store: NotesStore
    static let width: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            if store.notebooks.count > 1 {
                Picker("Notebook", selection: Binding(
                    get: { store.selectedNotebookID ?? "" },
                    set: { if !$0.isEmpty { store.selectNotebook($0) } })) {
                    ForEach(store.notebooks) { nb in Text(nb.name).tag(nb.notebookId) }
                }
                .labelsHidden()
                .padding(8)
                Divider()
            }
            List(selection: Binding<String?>(
                get: { store.selectedPageID },
                set: { id in
                    guard let id, let sec = store.sections.first(where: { $0.pages.contains { $0.pageId == id } })
                    else { return }
                    store.show(pageID: id, sectionID: sec.sectionId)
                })) {
                ForEach(store.sections) { sec in
                    Section(sec.name) {
                        ForEach(sec.pages) { page in
                            Text(page.title).lineLimit(1).tag(page.pageId)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// The page (read-only) with the Append field under it (§6.7).
struct NotesPageView: View {
    @ObservedObject var store: NotesStore
    let forced: ForcedPaneState?
    @Environment(\.windowModel) private var model

    var body: some View {
        let state = NotesPaneState.resolve(
            store.state, notebooks: store.notebooks.count, sections: store.sections.count,
            pages: store.pages.count, hasPage: store.page != nil, sectionSelected: store.selectedSectionID != nil,
            forced: forced, offline: model?.connection == .offline)
        switch state {
        case .loading: LoadingPane("Loading Notes\u{2026}")
        case .error(let title, let message):
            ErrorPane(title: title, message: message) { store.retry() }
        case .noNotebooks:
            EmptyPane(NotesPaneState.noNotebooksTitle, systemImage: NativeAppID.onenote.symbol,
                      message: NotesStore.noNotebooksBody(groupID: store.groupID))
        case .noSections:
            EmptyPane("No Sections", systemImage: NativeAppID.onenote.symbol,
                      message: "This notebook has no sections yet.")
        case .noPages:
            EmptyPane("No Pages", systemImage: NativeAppID.onenote.symbol,
                      message: "This section has no pages yet.")
        case .noSelection: NoSelectionPane("No Page Selected")
        case .page:
            if let page = store.page { NotesPageBody(store: store, page: page) }
        }
    }
}

/// Page title + rendered body (scrolls), then the Append bar.
private struct NotesPageBody: View {
    @ObservedObject var store: NotesStore
    let page: NotePageResponse
    @State private var draft = ""
    @Environment(\.contentTextScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            // AppKit text view: OneNote pages are HTML with headings,
            // lists, tables and to-do tags, which a SwiftUI Text flattens.
            NotesPageTextView(title: page.title, html: page.html, scale: scale)
                .accessibilityLabel(page.title)
            Divider()
            NotesAppendBar(draft: $draft, appending: store.appending, error: store.appendError) {
                store.append(text: draft)
                draft = ""
            }
        }
    }
}

/// Append field (§6.7): multi-line field + Append; Return appends.
struct NotesAppendBar: View {
    @Binding var draft: String
    let appending: Bool
    let error: String?
    let submit: () -> Void
    @Environment(\.contentTextScale) private var scale

    static func canAppend(_ draft: String, appending: Bool) -> Bool {
        !appending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(AppFont.subheadline(scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Append to Page", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(AppFont.body(scale))
                    .lineLimit(1 ... 4)
                    .onSubmit { if Self.canAppend(draft, appending: appending) { submit() } }
                if appending {
                    ProgressView().controlSize(.small)
                }
                Button("Append", action: submit)
                    .disabled(!Self.canAppend(draft, appending: appending))
            }
        }
        .padding(10)
    }
}

/// Read-only, selectable page: the title, then the page HTML in the
/// system font and label colors (both appearances), tables and lists
/// kept. Rebuilt only when the page or text size changes.
struct NotesPageTextView: NSViewRepresentable {
    let title: String
    let html: String
    let scale: Double

    /// Link clicks go through the one router (LINKGUARD): Teams / Microsoft
    /// 365 links open natively (or are refused), never AppKit's default
    /// browser open.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var key: String?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            TeamsLinkRouter.open(url)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let tv = scroll.documentView as? NSTextView {
            tv.delegate = context.coordinator
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 12, height: 14)
            tv.isAutomaticLinkDetectionEnabled = false
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let key = "\(scale)|\(title)|\(html)"
        guard context.coordinator.key != key, let tv = scroll.documentView as? NSTextView else { return }
        context.coordinator.key = key
        tv.textStorage?.setAttributedString(NotesRender.page(title: title, html: html, scale: scale))
    }
}

/// OneNote page rendering for `NotesPageTextView`.
@MainActor
enum NotesRender {
    /// OneNote page HTML → attributed text for `NotesPageTextView`:
    /// system font at the app's text size, label colors (so dark mode
    /// reads), OneNote to-do tags as check boxes, hairline table grid.
    static func page(title: String, html: String, scale: Double) -> NSAttributedString {
        let size = 13 * scale
        let out = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 20 * scale, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.paragraphSpacing = 10 * scale; return p }(),
        ])
        let css = "<style>body{font-family:-apple-system,'Helvetica Neue';font-size:\(size)px;line-height:1.35}"
            + "h1,h2,h3{font-weight:600;margin:14px 0 4px}h1{font-size:\(size * 1.3)px}"
            + "h2{font-size:\(size * 1.15)px}h3{font-size:\(size)px}"
            + "table{border-collapse:collapse}td,th{border:1px solid #9a9a9a;padding:4px 10px;text-align:left}"
            + "th{font-weight:600}</style>"
        let tagged = html
            .replacingOccurrences(of: #"<p data-tag="to-do:completed">"#, with: "<p>\u{2611}\u{2002}")
            .replacingOccurrences(of: #"<p data-tag="to-do">"#, with: "<p>\u{2610}\u{2002}")
        guard let data = (css + tagged).data(using: .utf8),
              let body = try? NSMutableAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil)
        else {
            out.append(NSAttributedString(string: MessageRender.stripTags(html), attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor,
            ]))
            return out
        }
        // The importer paints text black: labels follow the appearance.
        let all = NSRange(location: 0, length: body.length)
        body.enumerateAttribute(.link, in: all) { link, range, _ in
            if link == nil { body.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        while body.string.hasSuffix("\n") { body.deleteCharacters(in: NSRange(location: body.length - 1, length: 1)) }
        space(body, size: size, scale: scale)
        out.append(body)
        return out
    }

    /// The HTML importer drops heading margins and gives `<p>` a full
    /// line after: set the rhythm here. Headings get room above and a
    /// little below; paragraphs, list items and to-dos share one gap;
    /// list bullets sit close to the margin; table cells get padding, a
    /// quiet grid and a filled header row.
    private static func space(_ body: NSMutableAttributedString, size: CGFloat, scale: Double) {
        let text = body.string as NSString
        let gap = 4 * scale
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byParagraphs, .substringNotRequired]) { _, _, range, _ in
            guard range.length > 0,
                  let style = body.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                      as? NSParagraphStyle,
                  let p = style.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            let font = body.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            let cells = p.textBlocks.compactMap { $0 as? NSTextTableBlock }
            let first = text.substring(with: NSRange(location: range.location, length: 1))
            let todo = first == "\u{2610}" || first == "\u{2611}"
            if !cells.isEmpty {
                for cell in cells {
                    cell.table.collapsesBorders = true
                    cell.setBorderColor(.tertiaryLabelColor)
                    cell.setWidth(1, type: .absoluteValueType, for: .border)
                    for edge: NSRectEdge in [.minY, .maxY] {
                        cell.setWidth(5 * scale, type: .absoluteValueType, for: .padding, edge: edge)
                    }
                    for edge: NSRectEdge in [.minX, .maxX] {
                        cell.setWidth(10 * scale, type: .absoluteValueType, for: .padding, edge: edge)
                    }
                    cell.backgroundColor = cell.startingRow == 0 ? .quaternaryLabelColor : nil
                }
                p.paragraphSpacingBefore = 0
                p.paragraphSpacing = 0
            } else if !p.textLists.isEmpty {
                // Bullet near the margin, text one short tab after it.
                let lead = CGFloat(p.textLists.count - 1) * 18 * scale
                p.tabStops = [NSTextTab(textAlignment: .natural, location: lead + 6 * scale),
                              NSTextTab(textAlignment: .natural, location: lead + 20 * scale)]
                p.firstLineHeadIndent = 0
                p.headIndent = lead + 20 * scale
                p.paragraphSpacingBefore = 0
                p.paragraphSpacing = gap
            } else if !todo, (font?.pointSize ?? 0) > size * 1.05 || bold {
                p.paragraphSpacingBefore = range.location == 0 ? 4 * scale : 14 * scale
                p.paragraphSpacing = 6 * scale
            } else {
                p.paragraphSpacingBefore = 0
                p.paragraphSpacing = gap
            }
            body.addAttribute(.paragraphStyle, value: p, range: range)
        }
    }

}
