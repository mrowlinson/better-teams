// Top10FilesTests.swift — top10-files lane: ONE Files surface merges
// chat + channel + drive legs into one recents view.
import XCTest

@testable import OstMacCore

@MainActor
final class Top10FilesTests: XCTestCase {
    private nonisolated static let chatFile = SharedFile(
        id: "c1", name: "chat-deck.pdf", size: 100,
        mime: "application/pdf",
        web_url: "https://w/chat-deck",
        drive_id: "D1", modified: "2026-09-22T10:00:00Z",
        sender: "Tom Becker")
    private static let channelFile = SharedFile(
        id: "h1", name: "chan-sheet.xlsx", size: 200,
        mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        web_url: "https://w/chan-sheet",
        drive_id: "D2", modified: "2026-09-24T10:00:00Z")
    private static let driveFile = SharedFile(
        id: "r1", name: "qna-export.csv", size: 300,
        mime: "text/csv",
        web_url: "https://w/qna-export",
        drive_id: "D9", modified: "2026-09-25T10:00:00Z")
    private static let driveDupOfChat = SharedFile(
        id: "c1", name: "chat-deck.pdf", size: 100,
        mime: "application/pdf",
        web_url: "https://w/chat-deck",
        drive_id: "D1", modified: "2026-09-22T10:00:00Z")

    // MARK: - Decode

    func testDriveRecentsDecodesCoreEnvelope() throws {
        let json = """
        {"ok":true,"files":[
          {"id":"r1","name":"qna-export.csv","size":12288,
           "mime":"text/csv","web_url":"https://w/qna",
           "download_url":null,"drive_id":"D9",
           "created":"2026-09-25T09:58:00Z",
           "modified":"2026-09-25T09:58:00Z","sender":null}
        ]}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(DriveRecentsResponse.self, from: json)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.files.count, 1)
        XCTAssertEqual(resp.files[0].id, "r1")
        XCTAssertEqual(resp.files[0].drive_id, "D9")
        XCTAssertNil(resp.files[0].sender)
    }

    // MARK: - Pure merge/display

    func testMergeTagsSourcesAndDedupes() {
        let rows = UnifiedFilesStore.merge(legs: [
            (.chat, "Design Sync", [Self.chatFile]),
            (.channel, "Eng > #General", [Self.channelFile]),
            (.drive, "OneDrive", [Self.driveFile, Self.driveDupOfChat]),
        ])
        XCTAssertEqual(rows.count, 3)
        // Chat + channel legs both survive with their origin names.
        XCTAssertTrue(rows.contains {
            $0.source == .chat && $0.sourceName == "Design Sync"
                && $0.file.id == "c1"
        })
        XCTAssertTrue(rows.contains {
            $0.source == .channel && $0.sourceName == "Eng > #General"
                && $0.file.id == "h1"
        })
        // The drive-leg duplicate of the chat file drops (first-wins).
        XCTAssertEqual(rows.filter { $0.file.id == "c1" }.count, 1)
        XCTAssertEqual(rows.first { $0.file.id == "c1" }?.source, .chat)
    }

    func testDisplayedSortsNewestFirst() {
        let rows = UnifiedFilesStore.merge(legs: [
            (.chat, "C", [Self.chatFile]),
            (.channel, "H", [Self.channelFile]),
            (.drive, "OneDrive", [Self.driveFile]),
        ])
        let out = UnifiedFilesStore.displayed(
            rows, sort: .date, filter: .all, sourceFilter: .all)
        XCTAssertEqual(out.map(\.file.name), [
            "qna-export.csv", "chan-sheet.xlsx", "chat-deck.pdf",
        ])
    }

    func testDisplayedSourceFilter() {
        let rows = UnifiedFilesStore.merge(legs: [
            (.chat, "C", [Self.chatFile]),
            (.channel, "H", [Self.channelFile]),
            (.drive, "OneDrive", [Self.driveFile]),
        ])
        let chats = UnifiedFilesStore.displayed(
            rows, sort: .date, filter: .all, sourceFilter: .chats)
        XCTAssertEqual(chats.map(\.file.name), ["chat-deck.pdf"])
        let drive = UnifiedFilesStore.displayed(
            rows, sort: .date, filter: .all, sourceFilter: .drive)
        XCTAssertEqual(drive.map(\.file.name), ["qna-export.csv"])
    }

    func testDisplayedTypeFilterReuse() {
        let png = SharedFile(
            id: "p1", name: "shot.png", size: 10, mime: "image/png",
            drive_id: "D1", modified: "2026-09-26T10:00:00Z")
        let rows = UnifiedFilesStore.merge(legs: [
            (.chat, "C", [Self.chatFile, png]),
            (.drive, "OneDrive", [Self.driveFile]),
        ])
        let out = UnifiedFilesStore.displayed(
            rows, sort: .date, filter: .images, sourceFilter: .all)
        XCTAssertEqual(out.map(\.file.name), ["shot.png"])
    }

    func testRowKeyIsDriveScoped() {
        let a = SharedFile(id: "x", name: "a", drive_id: "D1")
        let b = SharedFile(id: "x", name: "b", drive_id: "D2")
        XCTAssertNotEqual(UnifiedFileRow.key(for: a), UnifiedFileRow.key(for: b))
        let bare = SharedFile(id: "x", name: "c")
        XCTAssertEqual(UnifiedFileRow.key(for: bare), "x")
    }

    func testUpsertRow() {
        let row = UnifiedFileRow(file: Self.chatFile, source: .chat, sourceName: "C")
        let out = UnifiedFilesStore.upsert(row, into: [])
        XCTAssertEqual(out.count, 1)
        let edit = UnifiedFileRow(
            file: SharedFile(
                id: "c1", name: "renamed.pdf", size: 100, drive_id: "D1"),
            source: .chat, sourceName: "C")
        let again = UnifiedFilesStore.upsert(edit, into: out)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again[0].file.name, "renamed.pdf")
    }

    func testDateLabel() {
        XCTAssertNotNil(UnifiedFilesStore.dateLabel(Self.driveFile))
        XCTAssertTrue(UnifiedFilesStore.dateLabel(Self.driveFile)?.contains("2026") ?? false)
        XCTAssertNil(UnifiedFilesStore.dateLabel(SharedFile(id: "x", name: "dateless")))
    }

    func testSourceLabels() {
        XCTAssertEqual(UnifiedFileSource.chat.label, "Chat")
        XCTAssertEqual(UnifiedFileSource.channel.label, "Channel")
        XCTAssertEqual(UnifiedFileSource.drive.label, "OneDrive")
        XCTAssertEqual(
            UnifiedFileSourceFilter.allCases.map(\.label),
            ["All", "Chats", "Channels", "OneDrive"])
    }

    // MARK: - Specs

    func testSpecsCapsAndNames() {
        let chats = (0 ..< 12).map {
            ChatItem(chatId: "chat\($0)", name: "Chat \($0)", is_group: true)
        }
        let teams = [
            TeamItem(teamId: "t1", name: "Eng", channels: [
                TeamChannel(channelId: "h1", name: "General"),
                TeamChannel(channelId: "h2", name: "Shipping"),
            ]),
        ]
        let specs = UnifiedFilesStore.specsFor(chats: chats, teams: teams)
        XCTAssertEqual(
            specs.filter { $0.kind == .chat }.count, UnifiedFilesStore.maxChats)
        XCTAssertEqual(
            specs.filter { $0.kind == .channel }.map(\.name),
            ["Eng > #General", "Eng > #Shipping"])
        let capped = UnifiedFilesStore.specsFor(
            chats: chats, teams: teams, chatCap: 2, channelCap: 1)
        XCTAssertEqual(capped.count, 3)
    }

    func testSpecsEmpty() {
        XCTAssertTrue(UnifiedFilesStore.specsFor(chats: [], teams: []).isEmpty)
        let store = UnifiedFilesStore()
        XCTAssertNil(store.uploadTarget)
    }

    // MARK: - Share payload

    func testShareItemsPrefersSavedBytes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Top10FilesTests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("saved.pdf")
        try "bytes".write(to: file, atomically: true, encoding: .utf8)
        let row = UnifiedFileRow(file: Self.chatFile, source: .chat, sourceName: "C")
        let items = UnifiedFilesStore.shareItems(for: row, savedPath: file.path)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual((items[0] as? URL)?.path, file.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testShareItemsFallsBackToWebURL() {
        let row = UnifiedFileRow(file: Self.chatFile, source: .chat, sourceName: "C")
        let items = UnifiedFilesStore.shareItems(for: row, savedPath: "/nonexistent/x.pdf")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(
            (items[0] as? URL)?.absoluteString, "https://w/chat-deck")
    }

    func testShareItemsEmptyWhenNothing() {
        let row = UnifiedFileRow(
            file: SharedFile(id: "x", name: "bare"), source: .drive,
            sourceName: "OneDrive")
        XCTAssertTrue(UnifiedFilesStore.shareItems(for: row, savedPath: nil).isEmpty)
    }

    func testDemoSaveDestinationIsTmp() {
        let dest = UnifiedFilesStore.demoSaveDestination(filename: "a b.pdf")
        XCTAssertTrue(dest.hasPrefix(NSTemporaryDirectory()))
        XCTAssertTrue(dest.hasSuffix("UnifiedFilesDemo/a b.pdf"))
        XCTAssertFalse(dest.contains("Downloads"))
    }

    func testDemoFileContent() {
        let content = UnifiedFilesStore.demoFileContent(for: Self.chatFile)
        XCTAssertTrue(content.contains("chat-deck.pdf"))
    }

    // MARK: - Load (mock legs)

    private func mockStore(
        chatFiles: [SharedFile] = [], channelFiles: [SharedFile] = [],
        driveFiles: [SharedFile] = [],
        failChat: Bool = false, failAll: Bool = false
    ) -> UnifiedFilesStore {
        UnifiedFilesStore(
            list: { id, _ in
                if failAll || (failChat && id == "chat-1") {
                    throw CoreCallError.failed("files: boom")
                }
                if id == "chat-1" {
                    return SharedFilesResponse(ok: true, chat_id: id, files: chatFiles)
                }
                return SharedFilesResponse(ok: true, chat_id: id, files: channelFiles)
            },
            recents: { _ in
                if failAll { throw CoreCallError.failed("recents: boom") }
                return DriveRecentsResponse(ok: true, files: driveFiles)
            })
    }

    private func poll(
        _ store: UnifiedFilesStore, until: (SharedFilesState) -> Bool = { $0 != .loading }
    ) async {
        for _ in 0 ..< 50 {
            if until(store.state) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Acceptance: a chat file + a channel file land in ONE recents view.
    func testLoadMergesChatChannelAndDrive() async {
        let store = mockStore(
            chatFiles: [Self.chatFile], channelFiles: [Self.channelFile],
            driveFiles: [Self.driveFile])
        store.load(chats: [("chat-1", "Design Sync")], channels: [("chan-1", "Eng > #General")])
        await poll(store)
        XCTAssertEqual(store.state, .loaded)
        let names = store.displayedRows.map(\.file.name)
        XCTAssertTrue(names.contains("chat-deck.pdf"))
        XCTAssertTrue(names.contains("chan-sheet.xlsx"))
        XCTAssertTrue(names.contains("qna-export.csv"))
        // Recents order: drive newest first.
        XCTAssertEqual(names, ["qna-export.csv", "chan-sheet.xlsx", "chat-deck.pdf"])
    }

    func testLoadToleratesLegFailure() async {
        let store = mockStore(
            chatFiles: [Self.chatFile], channelFiles: [Self.channelFile],
            driveFiles: [Self.driveFile], failChat: true)
        store.load(chats: [("chat-1", "C")], channels: [("chan-1", "H")])
        await poll(store)
        XCTAssertEqual(store.state, .loaded)
        let names = store.displayedRows.map(\.file.name)
        XCTAssertFalse(names.contains("chat-deck.pdf"))
        XCTAssertTrue(names.contains("chan-sheet.xlsx"))
        XCTAssertTrue(names.contains("qna-export.csv"))
    }

    func testLoadAllFailedSurfacesError() async {
        let store = mockStore(failAll: true)
        store.load(chats: [("chat-1", "C")], channels: [])
        await poll(store)
        if case let .error(m) = store.state {
            XCTAssertTrue(m.contains("boom"))
        } else {
            XCTFail("expected error state, got \(store.state)")
        }
    }

    func testLoadEmptyLegsIsEmpty() async {
        let store = mockStore()
        store.load(chats: [("chat-1", "C")], channels: [])
        await poll(store)
        XCTAssertEqual(store.state, .empty)
    }

    // MARK: - Demo + actions

    func testShowDemoAdoptsRows() {
        let store = UnifiedFilesStore()
        store.showDemo(
            specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.rows.count, DemoData.unifiedDemoRows().count)
        XCTAssertGreaterThanOrEqual(store.rows.count, 12, "demo Recent reads as a real library")
        // Chat + channel legs both present in the demo seed.
        XCTAssertTrue(store.rows.contains { $0.source == .chat })
        XCTAssertTrue(store.rows.contains { $0.source == .channel })
        XCTAssertTrue(store.rows.contains { $0.source == .drive })
        // Upload targets the first chat leg.
        XCTAssertEqual(store.uploadTarget?.id, DemoData.demoID)
        XCTAssertEqual(
            store.displayedRows.first?.file.name, "qna-export-sept.csv")
    }

    func testDemoUploadFabricatesTaggedRow() {
        let store = UnifiedFilesStore()
        store.showDemo(
            specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        store.upload(paths: ["/tmp/demo-notes.txt"])
        XCTAssertEqual(store.rows.count, DemoData.unifiedDemoRows().count + 1)
        XCTAssertEqual(store.rows[0].file.name, "demo-notes.txt")
        XCTAssertEqual(store.rows[0].source, .chat)
        XCTAssertEqual(store.rows[0].sourceName, "Design Sync")
    }

    func testUploadPregatesOversize() async {
        let calls = LockedBox(0)
        let store = UnifiedFilesStore(
            list: { id, _ in SharedFilesResponse(ok: true, chat_id: id, files: []) },
            recents: { _ in DriveRecentsResponse(ok: true, files: []) },
            upload: { _, _ in
                calls.mutate { $0 += 1 }
                return SharedFileUploadResponse(ok: true, file: Self.chatFile)
            },
            sizeProbe: { _ in 99 * 1024 * 1024 })
        store.load(chats: [("chat-1", "C")], channels: [])
        await poll(store)
        store.upload(paths: ["/tmp/huge.bin"])
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(store.gatedUploads, ["/tmp/huge.bin"])
        XCTAssertNotNil(store.uploadError)
        store.clearUploadError()
        XCTAssertNil(store.uploadError)
        XCTAssertTrue(store.gatedUploads.isEmpty)
    }

    func testLiveUploadUpsertsTaggedRow() async {
        let uploaded = SharedFile(
            id: "up1", name: "sent.pdf", size: 512,
            mime: "application/pdf", drive_id: "D1",
            modified: "2026-09-26T10:00:00Z")
        // d15-leak: the default recents fetcher is LIVE
        // (RustCore.driveRecents) — without this empty injector the
        // signed-in user's real rows land in `rows` and the count
        // assertions below fail nondeterministically.
        let store = UnifiedFilesStore(
            list: { id, _ in SharedFilesResponse(ok: true, chat_id: id, files: []) },
            recents: { _ in DriveRecentsResponse(ok: true, files: []) },
            upload: { _, _ in SharedFileUploadResponse(ok: true, file: uploaded) },
            sizeProbe: { _ in 512 })
        store.load(chats: [("chat-1", "Design Sync")], channels: [])
        await poll(store)
        XCTAssertEqual(store.state, .empty)
        store.upload(paths: ["/tmp/sent.pdf"])
        for _ in 0 ..< 50 {
            if !store.rows.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows[0].file.name, "sent.pdf")
        XCTAssertEqual(store.rows[0].source, .chat)
        XCTAssertEqual(store.rows[0].sourceName, "Design Sync")
    }

    func testDemoPreviewSavesThenPreviews() {
        let previewed = LockedBox<[String]>([])
        let store = UnifiedFilesStore(preview: { p in previewed.mutate { $0.append(p) } })
        store.showDemo(
            specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        let row = store.displayedRows.first!
        XCTAssertNil(store.localPath(for: row))
        store.preview(row)
        // Demo save fabricated real bytes in tmp; the panel opened over them.
        let local = store.localPath(for: row)
        XCTAssertNotNil(local)
        XCTAssertEqual(previewed.value, [local!])
        XCTAssertTrue(local!.hasPrefix(NSTemporaryDirectory()))
        // Second preview reuses the copy (no re-save).
        store.preview(row)
        XCTAssertEqual(previewed.value, [local!, local!])
        try? FileManager.default.removeItem(atPath: local!)
    }

    func testDemoShareUsesSavedBytes() {
        let sharedBox = LockedBox<[[Any]]>([])
        let store = UnifiedFilesStore(share: { items in sharedBox.mutate { $0.append(items) } })
        store.showDemo(
            specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        let row = store.displayedRows.first!
        store.share(row) // no copy yet: saves first, then shares bytes
        let shared = sharedBox.value
        XCTAssertEqual(shared.count, 1)
        let url = shared[0][0] as? URL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.isFileURL)
        if let local = store.localPath(for: row) {
            try? FileManager.default.removeItem(atPath: local)
        }
    }

    func testShareLinkDemoFabricates() {
        let copied = LockedBox<[String]>([])
        let store = UnifiedFilesStore(copyLink: { s in copied.mutate { $0.append(s) } })
        store.showDemo(
            specs: DemoData.unifiedDemoSpecs, rows: DemoData.unifiedDemoRows())
        let row = store.displayedRows.first!
        XCTAssertNil(store.link(for: row))
        store.shareLink(row)
        XCTAssertEqual(copied.value.count, 1)
        XCTAssertEqual(store.link(for: row), copied.value[0])
        store.shareLink(row) // cached: re-copies without refetch
        XCTAssertEqual(copied.value.count, 2)
    }

    func testOpen() {
        let opened = LockedBox<[URL]>([])
        let store = UnifiedFilesStore(openURL: { url in
            opened.mutate { $0.append(url) }
            return true
        })
        let row = UnifiedFileRow(file: Self.chatFile, source: .chat, sourceName: "C")
        XCTAssertEqual(store.open(row)?.absoluteString, "https://w/chat-deck")
        XCTAssertEqual(opened.value.count, 1)
        let bare = UnifiedFileRow(
            file: SharedFile(id: "x", name: "bare"), source: .drive,
            sourceName: "OneDrive")
        XCTAssertNil(store.open(bare))
        XCTAssertEqual(opened.value.count, 1)
    }

    func testDefaultsNoopUnderXCTest() {
        XCTAssertNotNil(NSClassFromString("XCTestCase"))
        // No panel, no picker, no crash under XCTest.
        UnifiedFilesStore.defaultPreview("/tmp/never.pdf")
        UnifiedFilesStore.defaultShare([URL(fileURLWithPath: "/tmp/never.pdf")])
    }

    // MARK: - Nav

    // MARK: - Native controls pin

}
