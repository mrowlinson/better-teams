// InlineDocsTests.swift — om-inline-docs: ref mining, row model,
// resolve/no-prefetch, open path, icon cache, demo thread shape.
import AppKit
import XCTest

@testable import OstMacCore

@MainActor
final class InlineDocsTests: XCTestCase {
    private func file(
        id: String = "f1", name: String = "deck.pdf", size: UInt64 = 48211,
        mime: String? = "application/pdf",
        webURL: String? = "https://sp/deck",
        attachmentID: String? = "a1"
    ) -> SharedFile {
        SharedFile(
            id: id, name: name, size: size, mime: mime,
            web_url: webURL, drive_id: "D1", sender: "Megan Harper",
            attachment_id: attachmentID)
    }

    private func msg(raw: String?, content: String = "") -> ChatMessage {
        ChatMessage(id: "m", sender: "S", timestamp: "t", content: content, raw: raw)
    }

    // MARK: - Ref mining

    func testRefsBareAttachmentID() {
        XCTAssertEqual(
            InlineDocs.refs(fromRaw: #"<attachment id="abc123"></attachment>"#),
            ["abc123"])
    }

    func testRefsQuotingAndCase() {
        XCTAssertEqual(
            InlineDocs.refs(fromRaw: #"<ATTACHMENT ID='x1'></ATTACHMENT>"#),
            ["x1"])
        XCTAssertEqual(
            InlineDocs.refs(fromRaw: #"<attachment id=x2></attachment>"#),
            ["x2"])
        XCTAssertEqual(
            InlineDocs.refs(fromRaw: #"<attachment id=" x3 "></attachment>"#),
            ["x3"])
    }

    func testRefsMultipleInOrderDeduped() {
        let raw = #"<p>see these</p><attachment id="a"></attachment><attachment id="b"></attachment><attachment id="a"></attachment>"#
        XCTAssertEqual(InlineDocs.refs(fromRaw: raw), ["a", "b"])
    }

    func testRefsDropsIDLessAndMalformed() {
        // Id-less blocks stay bot-post-only (no row duplication).
        XCTAssertEqual(
            InlineDocs.refs(fromRaw: #"<attachment><a href="https://h/a">A</a></attachment>"#),
            [])
        XCTAssertEqual(InlineDocs.refs(fromRaw: #"<attachment id=""></attachment>"#), [])
        XCTAssertEqual(InlineDocs.refs(fromRaw: "<p>plain</p>"), [])
        XCTAssertEqual(InlineDocs.refs(fromRaw: nil), [])
        XCTAssertEqual(InlineDocs.refs(fromRaw: ""), [])
        // Unterminated blocks are kept as text, never refs.
        XCTAssertEqual(InlineDocs.refs(fromRaw: #"<attachment id="a">"#), [])
    }

    func testRefsSelfClosing() {
        XCTAssertEqual(InlineDocs.refs(fromRaw: #"<attachment id="s1"/>"#), ["s1"])
    }

    // MARK: - Row model

    func testRowModelDelegatesToFile() {
        let doc = InlineDoc(file: file(), refID: "a1")
        XCTAssertEqual(doc.id, "f1")
        XCTAssertEqual(doc.refID, "a1")
        XCTAssertEqual(doc.name, "deck.pdf")
        XCTAssertEqual(doc.sizeLabel, "48 KB")
        XCTAssertEqual(doc.iconName, "doc.richtext")
        XCTAssertEqual(doc.sender, "Megan Harper")
    }

    // MARK: - Resolve (pure, no prefetch)

    func testResolveMatchesAttachmentID() {
        let files = [file(id: "f1", attachmentID: "a1"), file(id: "f2", attachmentID: "a2")]
        let docs = InlineDocs.resolve(refs: ["a2", "missing", "a1"], files: files)
        XCTAssertEqual(docs.map(\.refID), ["a2", "a1"])
        XCTAssertEqual(docs.map(\.id), ["f2", "f1"])
    }

    func testResolveEmptyWithoutFilesOrIDs() {
        XCTAssertEqual(InlineDocs.resolve(refs: ["a1"], files: []), [])
        XCTAssertEqual(
            InlineDocs.resolve(refs: ["a1"], files: [file(attachmentID: nil)]), [])
        XCTAssertEqual(InlineDocs.resolve(refs: [], files: [file()]), [])
    }

    func testResolveCapsRows() {
        let refs = (0 ..< 25).map { "a\($0)" }
        let files = (0 ..< 25).map { file(id: "f\($0)", attachmentID: "a\($0)") }
        XCTAssertEqual(InlineDocs.resolve(refs: refs, files: files).count, InlineDocs.maxRows)
    }

    func testDocsForMessage() {
        let m = msg(raw: #"<p>specs</p><attachment id="a1"></attachment>"#)
        XCTAssertEqual(InlineDocs.docs(for: m, files: [file()]).count, 1)
        XCTAssertEqual(InlineDocs.docs(for: m, files: []).count, 0)
        XCTAssertEqual(
            InlineDocs.docs(for: msg(raw: nil, content: "hi"), files: [file()]).count, 0)
    }

    func testShouldPreloadOnlyWithRefs() {
        XCTAssertTrue(InlineDocs.shouldPreload(messages: [
            msg(raw: nil, content: "hi"),
            msg(raw: #"<attachment id="a1"></attachment>"#),
        ]))
        XCTAssertFalse(InlineDocs.shouldPreload(messages: [
            msg(raw: nil, content: "hi"),
            msg(raw: #"<attachment><a href="https://h/a">A</a></attachment>"#),
        ]))
        XCTAssertFalse(InlineDocs.shouldPreload(messages: []))
    }

    // MARK: - attachment_id wire compat

    func testSharedFileDecodesAttachmentID() throws {
        let with = """
        {"id":"i1","name":"f.docx","size":7,"attachment_id":"GUID-1"}
        """.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(SharedFile.self, from: with).attachment_id, "GUID-1")
        // Old core builds omit the key: nil, never a decode failure.
        let without = """
        {"id":"i1","name":"f.docx","size":7}
        """.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(SharedFile.self, from: without).attachment_id)
    }

    // MARK: - Open path (never downloads)

    func testOpenTargetAllowsOnlyHTTP() {
        XCTAssertEqual(
            InlineDocs.openTarget(for: InlineDoc(file: file(), refID: "a1"))?.absoluteString,
            "https://sp/deck")
        XCTAssertNil(InlineDocs.openTarget(for: InlineDoc(
            file: file(webURL: "file:///etc/passwd"), refID: "a1")))
        XCTAssertNil(InlineDocs.openTarget(for: InlineDoc(
            file: file(webURL: nil), refID: "a1")))
    }

    func testOpenPathNeverDownloads() {
        // Resolved docs open through the Shared store: the browser URL
        // opens, the download fetcher is never touched (no bytes move).
        let opened = LockedBox<[URL]>([])
        let downloads = LockedBox(0)
        let store = SharedFilesStore(
            download: { _, _, _ in
                downloads.mutate { $0 += 1 }
                throw CoreCallError.failed("must not download")
            },
            openURL: { url in opened.mutate { $0.append(url) }; return true })
        let doc = InlineDoc(file: file(), refID: "a1")
        let got = store.open(doc.file)
        XCTAssertEqual(got?.absoluteString, "https://sp/deck")
        XCTAssertEqual(opened.value.count, 1)
        XCTAssertEqual(downloads.value, 0)
    }

    // MARK: - Icon cache (local only)

    func testIconCacheMemoizesPerExtension() async {
        let cache = InlineDocIconCache()
        let first = await cache.icon(fileName: "deck.pdf")
        let second = await cache.icon(fileName: "other.pdf")
        XCTAssertTrue(first === second) // same cached instance
        // Unknown extensions still resolve (generic doc icon), no throw.
        let generic = await cache.icon(fileName: "noext")
        XCTAssertNotNil(generic)
    }

    // MARK: - Demo thread

    func testDocsThreadShape() {
        let files = DemoData.sharedFiles(for: DemoData.docsID)
        XCTAssertEqual(files.count, 3)
        let msgs = DemoData.docsMessages()
        XCTAssertEqual(msgs.count, 3)
        // File-only PDF: one row; the bubble's placeholder stands down.
        let first = InlineDocs.docs(for: msgs[0], files: files)
        XCTAssertEqual(first.map(\.name), ["onboarding-mocks.pdf"])
        XCTAssertTrue(MessageRender.showsPlaceholder(for: msgs[0])) // pure rule unchanged…
        XCTAssertFalse(first.isEmpty) // …but rows suppress it in the bubble
        // Captioned: text + two rows (image + sheet).
        XCTAssertFalse(MessageRender.bubbleText(for: msgs[1]).isEmpty)
        XCTAssertEqual(
            InlineDocs.docs(for: msgs[1], files: files).map(\.name),
            ["empty-states.png", "launch-checklist.xlsx"])
        XCTAssertFalse(MessageRender.showsPlaceholder(for: msgs[1]))
        // Own reply: no rows.
        XCTAssertEqual(InlineDocs.docs(for: msgs[2], files: files), [])
        // Preload fires for this thread (and any bare-id ref, even the
        // bot thread's unresolvable one — the list load is what decides),
        // never for ref-less threads.
        XCTAssertTrue(InlineDocs.shouldPreload(messages: msgs))
        XCTAssertTrue(InlineDocs.shouldPreload(messages: DemoData.botPostsMessages()))
        XCTAssertFalse(InlineDocs.shouldPreload(messages: DemoData.mediaMessages()))
        // Every demo bubble renders something (never blank).
        for m in msgs {
            let textVisible = !MessageRender.bubbleText(for: m).isEmpty
            let rowsVisible = !InlineDocs.docs(for: m, files: files).isEmpty
            XCTAssertTrue(textVisible || rowsVisible, "blank bubble: \(m.id)")
        }
        // Sidebar row tracks the thread tail.
        let row = DemoData.docsChat()
        XCTAssertEqual(row.chatId, DemoData.docsID)
        XCTAssertEqual(row.last_message_preview, msgs.last?.content)
        XCTAssertTrue(DemoData.chats.contains(where: { $0.id == DemoData.docsID }))
        XCTAssertEqual(DemoData.messages(for: DemoData.docsID).count, 3)
    }
}
