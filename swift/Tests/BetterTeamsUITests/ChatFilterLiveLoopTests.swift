// ChatFilterLiveLoopTests.swift — opt-in live loop per chat list filter
// (FILTERS2_LIVE=1) on the signed-in account. Read-only: the chat list,
// Teams folders and the activity feed are GETs; no chat is opened,
// marked or moved. Local stores are throwaway (temp path/suite), so
// nothing the app keeps is read or written. Prints counts and timings
// only — never names, ids, tokens or URLs.
import Foundation
import OstMacCore
import XCTest
@testable import BetterTeamsUI

@MainActor
final class ChatFilterLiveLoopTests: XCTestCase {
    private struct NoDock: DockBadging { func setBadge(_ label: String?) {} }

    func testLiveFilterLoops() async throws {
        guard ProcessInfo.processInfo.environment["FILTERS2_LIVE"] == "1" else {
            throw XCTSkip("set FILTERS2_LIVE=1 to run the live filter loops")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filters2-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let suite = "filters2-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }

        let rules = RulesStore(path: dir.appendingPathComponent("rules.json").path)
        let unread = UnreadStore(dock: NoDock())
        let mentions = MentionStore(dock: nil)
        let snooze = SnoozeStore(defaults: defaults)
        let list = ChatListViewModel(pins: UserPinStore(defaults: defaults), blocked: BlockedStore(defaults: nil),
                                     folders: FolderStore(defaults: defaults))
        var horizons: [String: String] = [:]
        var activity: [MentionActivity] = []
        // The app's wiring (AppState, live branch), minus every write.
        list.onFetched = { rows in
            rules.adoptServerMutes(rows)
            for c in rows { horizons[c.id] = c.read_horizon }
            let muted = Set(rows.filter { rules.level(chatID: $0.id) == .muted }.map(\.id))
            unread.seed(ChatListSeed.unreadSeeds(rows, mutedIDs: muted))
            mentions.seed(ChatListSeed.mentionedChats(activity, horizons: horizons))
        }
        list.mentionReader = { try CoreReads.mentionActivity() }
        list.onMentionActivity = { a in
            activity = a
            mentions.seed(ChatListSeed.mentionedChats(a, horizons: horizons))
        }
        list.folderReader = { try RustCore.chatFolders() }

        let t0 = ContinuousClock.now
        await list.load()
        let fr = ChatFilterRules(unread: unread, mentions: mentions, rules: rules, snooze: snooze,
                                 folders: list.folders)
        let full0 = fr.apply(.all, to: list.displayChats).count
        print("LIVE list pages=\(list.loadedPages) rows=\(full0) more=\(list.hasMore) load=\(fmt(ContinuousClock.now - t0))")
        XCTAssertGreaterThan(full0, 0, "control: the live list loaded")

        var filters: [(String, BetterTeamsUI.ChatFilter)] = [
            ("unread", .unread), ("mentions", .mentions), ("muted", .muted),
            ("snoozed", .snoozed), ("hidden", .hidden),
        ]
        for (i, f) in list.folders.allFolders.enumerated() {
            filters.append(("folder\(i + 1)", .folder(f.id)))
        }
        for (label, filter) in filters {
            let state = ChatSectionState()
            let start = ContinuousClock.now
            state.select(filter, list: list, rules: fr)
            let instant = fr.apply(filter, to: list.displayChats).count
            let bar = state.pager.phase
            while state.pager.phase == .searching, ContinuousClock.now - start < .seconds(30) {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let terminal = ContinuousClock.now - start
            let final = fr.apply(filter, to: list.displayChats).count
            XCTAssertEqual(state.pager.phase, .finished, "\(label) terminal")
            XCTAssertLessThan(terminal, .seconds(11), "\(label) within the 10 s budget")
            let pages = state.pager.pagesFetched
            state.clear()
            let back = fr.apply(state.filter, to: list.displayChats).count
            XCTAssertEqual(state.filter, .all)
            XCTAssertEqual(state.pager.phase, .idle)
            XCTAssertEqual(back, fr.apply(.all, to: list.displayChats).count, "\(label) exit restores the full list")
            print("LIVE filter=\(label) instant=\(instant) final=\(final) start=\(bar) terminal=\(fmt(terminal)) pages=\(pages) empty=\(final == 0) full_after_exit=\(back) more=\(list.hasMore)")
        }
    }

    private func fmt(_ d: Duration) -> String {
        let ms = d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
        return String(format: "%.2fs", Double(ms) / 1000)
    }
}
