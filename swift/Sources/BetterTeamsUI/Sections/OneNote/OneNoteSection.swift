// OneNoteSection.swift — OneNote native app provider (UI-SPEC §6.7).
//
// List: notebook › section › page outline. Detail: the page (read-only)
// + Append field. The app keeps its own `NotesStore` on the user's own
// OneNote, so browsing here never moves a conversation's Notes tab.
import OstMacCore
import SwiftUI

@MainActor
final class OneNoteSection: SectionProvider {
    let section: SectionID = .native(.onenote)
    let title = NativeAppID.onenote.title
    /// The app's own Notes scope (the user's notebooks).
    let store = NotesStore()
    private var opened = false

    func subtitle(_ m: WindowModel) -> String {
        guard m.forced(section) == nil else { return "" }
        return store.notebooks.first { $0.notebookId == store.selectedNotebookID }?.name ?? ""
    }

    func listPane(_ m: WindowModel) -> AnyView {
        AnyView(OneNoteOutline(store: store))
    }

    func detailPane(_ m: WindowModel) -> AnyView {
        AnyView(NotesPageView(store: store, forced: m.forced(section)))
    }

    /// `app/onenote` (the tail's head is the app id; pages select in place).
    func selection(for route: Route) -> SectionSelection? { nil }

    /// First visit opens the user's notebooks (demo: canned, offline).
    func selectionDidChange(_ sel: SectionSelection?, _ m: WindowModel) {
        guard !opened, m.forced(section) == nil else { return }
        opened = true
        if m.options.demo { store.showDemo() } else { store.open(groupID: nil) }
    }
}

/// Notebook › section › page outline. One notebook is open at a time
/// (its sections load on expand); sections start expanded.
struct OneNoteOutline: View {
    @ObservedObject var store: NotesStore
    @Environment(\.windowModel) private var model
    @State private var collapsed: Set<String> = []

    var body: some View {
        let forced = model?.forced(.native(.onenote))
        switch forced {
        case .loading: LoadingPane("Loading Notebooks\u{2026}")
        case .empty:
            EmptyPane(NotesPaneState.noNotebooksTitle, systemImage: NativeAppID.onenote.symbol,
                      message: NotesStore.noNotebooksBody(groupID: nil))
        case .error:
            ErrorPane(title: model?.connection == .offline ? NotesPaneState.offlineTitle : NotesPaneState.errorTitle,
                      message: model?.connection == .offline ? NotesPaneState.offlineMessage
                                                               : "Something went wrong.") {}
        case nil:
            if store.notebooks.isEmpty {
                listState
            } else {
                // R12: sections load behind the outline on screen.
                outline
                    .refreshStatus(store.state == .loading, label: "Updating Notebooks")
            }
        }
    }

    @ViewBuilder private var listState: some View {
        switch store.state {
        case .idle, .loading: LoadingPane("Loading Notebooks\u{2026}")
        case .error(let m):
            ErrorPane(title: model?.connection == .offline ? NotesPaneState.offlineTitle : NotesPaneState.errorTitle,
                      message: model?.connection == .offline ? NotesPaneState.offlineMessage : m) { store.retry() }
        case .loaded:
            EmptyPane(NotesPaneState.noNotebooksTitle, systemImage: NativeAppID.onenote.symbol,
                      message: NotesStore.noNotebooksBody(groupID: nil))
        }
    }

    private var outline: some View {
        List(selection: Binding<String?>(
            get: { store.selectedPageID },
            set: { id in
                guard let id, let sec = store.sections.first(where: { $0.pages.contains { $0.pageId == id } })
                else { return }
                store.show(pageID: id, sectionID: sec.sectionId)
            })) {
            ForEach(store.notebooks) { nb in
                DisclosureGroup(isExpanded: Binding(
                    get: { store.selectedNotebookID == nb.notebookId },
                    set: { if $0 { store.selectNotebook(nb.notebookId) } })) {
                    if store.selectedNotebookID == nb.notebookId {
                        ForEach(store.sections) { sec in
                            DisclosureGroup(isExpanded: Binding(
                                get: { !collapsed.contains(sec.sectionId) },
                                set: { if $0 { collapsed.remove(sec.sectionId) } else { collapsed.insert(sec.sectionId) } })) {
                                ForEach(sec.pages) { page in
                                    Label(page.title, systemImage: "doc.text")
                                        .lineLimit(1)
                                        .tag(page.pageId)
                                }
                            } label: {
                                Label(sec.name, systemImage: "folder")
                                    .lineLimit(1)
                            }
                        }
                    }
                } label: {
                    Label(nb.name, systemImage: "book.closed")
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.inset)
    }
}
