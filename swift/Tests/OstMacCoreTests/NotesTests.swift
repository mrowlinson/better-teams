// NotesTests.swift — om-notes lane: wire decode, store drill, demo, render.
import XCTest

@testable import OstMacCore

@MainActor
final class NotesTests: XCTestCase {
    override func tearDown() async throws {
        DemoData.resetDemoAppends()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    nonisolated static func notebooksJSON() -> NotebooksResponse {
        let json = """
            {"ok":true,"notebooks":[\
            {"id":"nb-1","name":"Work"},\
            {"id":"nb-2","name":"Team Wiki"}]}
            """
        return try! decodeOrThrow(NotebooksResponse.self, from: Data(json.utf8))
    }

    nonisolated static func sectionsJSON() -> NoteSectionsResponse {
        let json = """
            {"ok":true,"sections":[\
            {"id":"s-1","name":"Syncs","pages":[\
            {"id":"p-1","title":"Kickoff","updated":"2026-09-22T10:00:00Z"},\
            {"id":"p-2","title":"Untitled","updated":null}]},\
            {"id":"s-2","name":"Empty","pages":[]}]}
            """
        return try! decodeOrThrow(NoteSectionsResponse.self, from: Data(json.utf8))
    }

    nonisolated static func pageJSON() -> NotePageResponse {
        let json = """
            {"ok":true,"id":"p-1","title":"Kickoff",\
            "html":"<html><head><title>Kickoff</title></head><body><p>hi</p></body></html>"}
            """
        return try! decodeOrThrow(NotePageResponse.self, from: Data(json.utf8))
    }

    nonisolated static func mockFetchers(
        notebooks: NotebooksResponse? = nil,
        sections: NoteSectionsResponse? = nil,
        page: NotePageResponse? = nil
    ) -> NotesStore.Fetchers {
        let nbs = notebooks ?? notebooksJSON()
        let secs = sections ?? sectionsJSON()
        let pg = page ?? pageJSON()
        return NotesStore.Fetchers(
            notebooks: { _ in nbs },
            sections: { _, _ in secs },
            page: { _, _ in pg },
            append: { id, _, _ in NoteAppendResponse(ok: true, id: id) }
        )
    }

    /// Spin until `cond` holds (mock fetchers resolve in ms).
    func waitFor(_ what: String, _ cond: @autoclosure @escaping () -> Bool) async throws {
        if await TestWait.until(interval: 0.01, cond) { return }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: - Wire decode

    func testDecodeNotebooks() {
        let response = Self.notebooksJSON()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.notebooks.count, 2)
        XCTAssertEqual(response.notebooks[0].id, "nb-1")
        XCTAssertEqual(response.notebooks[0].name, "Work")
    }

    func testDecodeSectionsNested() {
        let response = Self.sectionsJSON()
        XCTAssertEqual(response.sections.count, 2)
        XCTAssertEqual(response.sections[0].pages.count, 2)
        XCTAssertEqual(response.sections[0].pages[0].title, "Kickoff")
        XCTAssertEqual(response.sections[0].pages[0].updated, "2026-09-22T10:00:00Z")
        XCTAssertNil(response.sections[0].pages[1].updated)
        XCTAssertTrue(response.sections[1].pages.isEmpty)
    }

    func testDecodePage() {
        let response = Self.pageJSON()
        XCTAssertEqual(response.id, "p-1")
        XCTAssertEqual(response.title, "Kickoff")
        XCTAssertTrue(response.html.contains("<p>hi</p>"))
    }

    func testDecodeAppend() throws {
        let json = #"{"ok":true,"id":"p-1"}"#
        let response = try decodeOrThrow(NoteAppendResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "p-1")
    }

    func testErrorEnvelopeThrows() {
        let json = #"{"ok":false,"error":"notes","detail":"nope"}"#
        XCTAssertThrowsError(
            try decodeOrThrow(NotebooksResponse.self, from: Data(json.utf8)))
        XCTAssertThrowsError(
            try decodeOrThrow(NotePageResponse.self, from: Data(json.utf8)))
    }

    // MARK: - Store drill

    func testOpenLoadsNotebooksAndScope() async throws {
        let store = NotesStore(fetchers: Self.mockFetchers())
        XCTAssertEqual(store.state, .idle)
        store.open(groupID: "team-9")
        XCTAssertEqual(store.groupID, "team-9")
        try await waitFor("notebooks", store.state == .loaded)
        XCTAssertEqual(store.notebooks.count, 2)
        XCTAssertNil(store.selectedNotebookID) // no auto-drill on open
    }

    func testOpenError() async throws {
        let store = NotesStore(fetchers: NotesStore.Fetchers(
            notebooks: { _ in throw CoreCallError.failed("boom") },
            sections: { _, _ in Self.sectionsJSON() },
            page: { _, _ in Self.pageJSON() },
            append: { id, _, _ in NoteAppendResponse(ok: true, id: id) }
        ))
        store.open(groupID: nil)
        XCTAssertNil(store.groupID)
        try await waitFor("error", store.state == .error("boom"))
        XCTAssertTrue(store.notebooks.isEmpty)
    }

    func testOpenResetsPriorSelection() async throws {
        let store = NotesStore(fetchers: Self.mockFetchers())
        store.open(groupID: nil)
        try await waitFor("notebooks", store.state == .loaded)
        store.selectNotebook("nb-1")
        try await waitFor("page", store.page != nil)
        XCTAssertNotNil(store.selectedPageID)
        store.open(groupID: "team-2")
        XCTAssertNil(store.selectedNotebookID)
        XCTAssertNil(store.selectedPageID)
        XCTAssertNil(store.page)
        XCTAssertTrue(store.sections.isEmpty)
        try await waitFor("reload", store.state == .loaded)
    }

    /// STABLEUI: another chat of the same scope keeps the notebooks and
    /// open page on screen (no reset, no refetch blank).
    func testReopenSameScopeKeepsNotebooksAndPage() async throws {
        let store = NotesStore(fetchers: Self.mockFetchers())
        store.open(groupID: nil)
        try await waitFor("notebooks", store.state == .loaded)
        store.selectNotebook("nb-1")
        try await waitFor("page", store.page != nil)
        store.open(groupID: nil)
        XCTAssertEqual(store.selectedNotebookID, "nb-1")
        XCTAssertNotNil(store.page)
        XCTAssertEqual(store.notebooks.count, 2)
    }

    func testSelectNotebookDrillsToFirstPage() async throws {
        let store = NotesStore(fetchers: Self.mockFetchers())
        store.open(groupID: nil)
        try await waitFor("notebooks", store.state == .loaded)
        store.selectNotebook("nb-1")
        try await waitFor("sections", !store.sections.isEmpty)
        XCTAssertEqual(store.selectedSectionID, "s-1") // first with pages
        try await waitFor("page", store.page != nil)
        XCTAssertEqual(store.selectedPageID, "p-1")
        XCTAssertEqual(store.page?.title, "Kickoff")
    }

    func testSelectSectionSwitchesPage() async throws {
        let store = NotesStore(fetchers: Self.mockFetchers())
        store.open(groupID: nil)
        try await waitFor("notebooks", store.state == .loaded)
        store.selectNotebook("nb-1")
        try await waitFor("page", store.page != nil)
        // Empty section: selection moves, page clears, nothing auto-opens.
        store.selectSection("s-2")
        XCTAssertEqual(store.selectedSectionID, "s-2")
        XCTAssertNil(store.selectedPageID)
        XCTAssertNil(store.page)
        XCTAssertTrue(store.pages.isEmpty)
    }

    func testAppendReloadsPage() async throws {
        let v1 = Self.pageJSON() // "<p>hi</p>", no "<p>new</p>"
        let v2 = NotePageResponse(
            ok: true, id: "p-1", title: "Kickoff", html: "<p>hi</p><p>new</p>")
        final class Cell: @unchecked Sendable {
            var page: NotePageResponse
            var appended: [String] = []
            init(_ page: NotePageResponse) { self.page = page }
        }
        let cell = Cell(v1)
        let fetchers = NotesStore.Fetchers(
            notebooks: { _ in Self.notebooksJSON() },
            sections: { _, _ in Self.sectionsJSON() },
            page: { _, _ in cell.page },
            append: { _, text, _ in
                cell.appended.append(text)
                cell.page = v2 // reload after append serves the new text
                return NoteAppendResponse(ok: true, id: "p-1")
            }
        )
        let store = NotesStore(fetchers: fetchers)
        store.open(groupID: nil)
        try await waitFor("notebooks", store.state == .loaded)
        store.selectNotebook("nb-1")
        try await waitFor("page", store.page != nil)
        store.append(text: "  hello  ")
        try await waitFor("appended", store.page?.html.contains("<p>new</p>") == true)
        XCTAssertEqual(cell.appended, ["hello"]) // trimmed
        XCTAssertFalse(store.appending)
        XCTAssertNil(store.appendError)
    }

    func testAppendErrorSurfaces() async throws {
        let fetchers = NotesStore.Fetchers(
            notebooks: { _ in Self.notebooksJSON() },
            sections: { _, _ in Self.sectionsJSON() },
            page: { _, _ in Self.pageJSON() },
            append: { _, _, _ in throw CoreCallError.failed("denied") }
        )
        let store = NotesStore(fetchers: fetchers)
        store.open(groupID: nil)
        try await waitFor("notebooks", store.state == .loaded)
        store.selectNotebook("nb-1")
        try await waitFor("page", store.page != nil)
        store.append(text: "hi")
        try await waitFor("appendError", store.appendError != nil)
        XCTAssertEqual(store.appendError, "denied")
        XCTAssertFalse(store.appending)
    }

    // MARK: - Demo

    func testDemoDrillIsOffline() {
        let store = NotesStore()
        XCTAssertFalse(store.isDemo)
        store.showDemo()
        XCTAssertTrue(store.isDemo)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.notebooks.count, 2)
        XCTAssertEqual(store.selectedNotebookID, "demo-nb-work")
        XCTAssertEqual(store.selectedSectionID, "demo-sec-sync")
        XCTAssertEqual(store.selectedPageID, "demo-page-kickoff")
        XCTAssertEqual(store.page?.title, "Kickoff Notes")
    }

    func testDemoAppendLandsLocally() {
        let store = NotesStore()
        store.showDemo()
        store.append(text: "demo para")
        XCTAssertTrue(store.page?.html.contains("<p>demo para</p>") == true)
        // Unknown page: adopt is nil-safe, no crash.
        XCTAssertNil(DemoData.notePage(for: "nope"))
        XCTAssertTrue(DemoData.noteSections(for: "nope").isEmpty)
    }

    func testDemoDataShapes() {
        let response = DemoData.notebooksResponse()
        XCTAssertTrue(response.ok)
        XCTAssertFalse(response.notebooks.isEmpty)
        let sections = DemoData.noteSections(for: "demo-nb-work")
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].pages.count, 2)
        XCTAssertEqual(sections[1].pages.count, 1)
    }

    // MARK: - HTML render

    func testRenderedKeepsTextDropsTags() {
        let attr = NotesStore.rendered(html: "<h1>Hi</h1><p>a &amp; b</p>")
        let plain = String(attr.characters)
        XCTAssertTrue(plain.contains("Hi"))
        XCTAssertFalse(plain.contains("<h1>"))
        XCTAssertFalse(plain.contains("<p>"))
    }

    func testRenderedFallsBackOnGarbage() {
        // Unbalanced junk: never raw tags, never crashes.
        let attr = NotesStore.rendered(html: "<p>oops")
        let plain = String(attr.characters)
        XCTAssertFalse(plain.contains("<p>"))
        XCTAssertTrue(plain.contains("oops"))
    }

    // MARK: - Honest empty states (om-sharednotes)

    func testContentStateBuckets() {
        XCTAssertEqual(
            NotesStore.contentState(
                notebooksEmpty: true, sectionsEmpty: true, loading: false),
            .noNotebooks)
        XCTAssertEqual(
            NotesStore.contentState(
                notebooksEmpty: false, sectionsEmpty: true, loading: true),
            .loadingSections)
        XCTAssertEqual(
            NotesStore.contentState(
                notebooksEmpty: false, sectionsEmpty: true, loading: false),
            .noSections)
        XCTAssertEqual(
            NotesStore.contentState(
                notebooksEmpty: false, sectionsEmpty: false, loading: false),
            .browse)
    }

    func testNoNotebooksBodyNamesScope() {
        XCTAssertTrue(
            NotesStore.noNotebooksBody(groupID: nil).contains("You have no"))
        XCTAssertTrue(
            NotesStore.noNotebooksBody(groupID: "team-9").contains("This team"))
    }

    func testDetailHintOnlyPromptsWhenSelectable() {
        XCTAssertTrue(
            NotesStore.detailHint(sectionSelected: false, pagesEmpty: true)
                .contains("Select a section"))
        XCTAssertTrue(
            NotesStore.detailHint(sectionSelected: true, pagesEmpty: true)
                .contains("no pages"))
        XCTAssertEqual(
            NotesStore.detailHint(sectionSelected: true, pagesEmpty: false),
            "Select a page.")
    }

    func testOpenEmptyNotebooksStaysHonest() async throws {
        let store = NotesStore(fetchers: NotesStore.Fetchers(
            notebooks: { _ in NotebooksResponse(ok: true, notebooks: []) },
            sections: { _, _ in Self.sectionsJSON() },
            page: { _, _ in Self.pageJSON() },
            append: { id, _, _ in NoteAppendResponse(ok: true, id: id) }
        ))
        store.open(groupID: "team-9")
        try await waitFor("loaded", store.state == .loaded)
        XCTAssertTrue(store.notebooks.isEmpty) // view shows No notebooks
        XCTAssertNil(store.selectedNotebookID)
    }
}
