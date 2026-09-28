// NotesViews.swift — OneNote page list, page, and Append field (UI-SPEC
// §6.2 Notes tab, §6.7 OneNote). Shared by the conversation Notes tab
// and the OneNote app; each passes its own `NotesStore`.
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
        case .loading: LoadingPane()
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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(page.title)
                        .font(AppFont.title3(scale))
                    Text(NotesRender.text(page.html))
                        .font(AppFont.body(scale))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
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

/// Last rendered page (the HTML importer is too slow to run per body).
@MainActor
enum NotesRender {
    private static var last: (html: String, text: AttributedString)?

    static func text(_ html: String) -> AttributedString {
        if let last, last.html == html { return last.text }
        let text = NotesStore.rendered(html: html)
        last = (html, text)
        return text
    }
}
