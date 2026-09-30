import OstMacCore
import XCTest
@testable import BetterTeamsUI

/// Chat list filters as user loops: enter → results or empty state →
/// exit (click the active filter again, the pill X / Esc, or "All") →
/// the full list. The look-back behind a filter always reaches a
/// terminal state within its clock budget, never paging the whole
/// history.
@MainActor
final class ChatFilterLoopTests: XCTestCase {
    private struct NoDock: DockBadging { func setBadge(_ label: String?) {} }

    /// Test clock: time moves only on `advance`.
    private final class StepClock: Clock, @unchecked Sendable {
        struct Instant: InstantProtocol {
            var offset: Duration
            func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
        }
        private let lock = NSLock()
        private var current = Instant(offset: .zero)
        private var sleepers: [(Instant, CheckedContinuation<Void, Never>)] = []
        var now: Instant { lock.withLock { current } }
        var minimumResolution: Duration { .zero }
        var sleeperCount: Int { lock.withLock { sleepers.count } }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if deadline <= current { lock.unlock(); c.resume(); return }
                sleepers.append((deadline, c))
                lock.unlock()
            }
        }
        func advance(by d: Duration) {
            lock.lock()
            current = current.advanced(by: d)
            let now = current
            let due = sleepers.filter { $0.0 <= now }
            sleepers.removeAll { $0.0 <= now }
            lock.unlock()
            due.forEach { $0.1.resume() }
        }
    }

    private final class Gate: @unchecked Sendable {
        let sem = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.withLock { n += 1 } }
        var hits: Int { lock.withLock { n } }
    }

    nonisolated private static func chat(_ id: String, _ name: String, _ minute: Int) -> ChatItem {
        ChatItem(chatId: id, name: name, is_group: false,
                 last_message_time: String(format: "2026-09-28T09:%02d:00.000Z", minute),
                 last_message_sender: name, last_message_preview: "Hello")
    }

    private struct Fixture {
        let list: ChatListViewModel
        let rules: ChatFilterRules
        let folderID: String
        let gate: Gate
    }

    /// Six chats on page 1; older pages never return until teardown
    /// (the worst live case: a page that hangs).
    private func fixture() async throws -> Fixture {
        let gate = Gate()
        let list = ChatListViewModel(
            fetcher: { _ in
                ChatsResponse(ok: true, chats: [
                    Self.chat("c1", "Emma Clarke", 50), Self.chat("c2", "Oliver Grant", 45),
                    Self.chat("c3", "Sophie Turner", 40), Self.chat("c4", "Jack Miller", 35),
                    Self.chat("c5", "Grace Walker", 30), Self.chat("c6", "Henry Brooks", 25),
                ], next_link: "https://amer.ng.msg.teams.microsoft.com/v1/users/ME/conversations")
            },
            pageFetcher: { _ in
                gate.hit()
                gate.sem.wait()
                return ChatsResponse(ok: true, chats: [], next_link: nil)
            })
        addTeardownBlock { for _ in 0..<8 { gate.sem.signal() } }
        await list.load()

        let unread = UnreadStore(dock: NoDock())
        unread.markUnread(chatID: "c1")
        unread.markUnread(chatID: "c3")
        let mentions = MentionStore(dock: nil)
        mentions.seed(["c2": Date()])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filterloop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var config = RulesConfig.default
        config.mutedChatIDs = ["c4"]
        config.hiddenChatIDs = ["c6"]
        let path = dir.appendingPathComponent("rules.json").path
        try config.save(to: path)
        let rules = RulesStore(path: path)

        let suite = "filterloop-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let snooze = SnoozeStore(defaults: defaults)
        snooze.snooze(chatID: "c5", until: Date().addingTimeInterval(3600))
        let folders = FolderStore(defaults: defaults)
        let folder = try XCTUnwrap(folders.createFolder(name: "Project Team"))
        folders.assign(chatID: "c2", folderID: folder.id)

        return Fixture(list: list,
                       rules: ChatFilterRules(unread: unread, mentions: mentions, rules: rules,
                                              snooze: snooze, folders: folders),
                       folderID: folder.id, gate: gate)
    }

    /// Every filter: enter shows its rows at once from the loaded page,
    /// the look-back ends within its 10 s budget even with a hung page,
    /// and each way out restores the full list.
    func testEveryFilterLoopReachesATerminalStateAndReturnsToTheFullList() async throws {
        let f = try await fixture()
        let full = f.rules.apply(.all, to: f.list.displayChats).map(\.id)
        XCTAssertEqual(full, ["c1", "c2", "c3", "c4", "c5"], "hidden chat left out of All")

        let cases: [(BetterTeamsUI.ChatFilter, [String])] = [
            (.unread, ["c1", "c3"]), (.mentions, ["c2"]), (.muted, ["c4"]),
            (.snoozed, ["c5"]), (.hidden, ["c6"]), (.folder(f.folderID), ["c2"]),
        ]
        for (i, (filter, expected)) in cases.enumerated() {
            let clock = StepClock()
            let state = ChatSectionState(pager: ChatFilterPager(maxPages: 2, timeout: .seconds(10), clock: clock))
            state.select(filter, list: f.list, rules: f.rules)
            XCTAssertEqual(state.filter, filter)
            XCTAssertEqual(f.rules.apply(state.filter, to: f.list.displayChats).map(\.id), expected,
                           "\(filter.arg) applies at once to the loaded rows")
            XCTAssertEqual(state.pager.phase, .searching, "few matches: bounded look-back")
            await waitUntil("\(filter.arg) timeout armed") { clock.sleeperCount == 1 }
            clock.advance(by: .seconds(10))
            await waitUntil("\(filter.arg) terminal within 10 s") { state.pager.phase == .finished }

            // Exit, a different way per loop: active filter again, the
            // pill X / Esc (clear), or picking All.
            switch i % 3 {
            case 0: state.toggle(filter, list: f.list, rules: f.rules)
            case 1: state.clear()
            default: state.toggle(.all, list: f.list, rules: f.rules)
            }
            XCTAssertEqual(state.filter, .all, "\(filter.arg) exits")
            XCTAssertEqual(state.pager.phase, .idle, "no indicator on the full list")
            XCTAssertEqual(f.rules.apply(state.filter, to: f.list.displayChats).map(\.id), full,
                           "\(filter.arg) exit restores the full list")
        }
        XCTAssertEqual(f.gate.hits, 1, "one hung page for all loops, never a walk of the history")
    }

    /// An empty result is a worded empty state per filter (no spinner
    /// once the look-back ends); the menu's checked item toggles off.
    func testEmptyFilterWordingAndMenuToggle() async throws {
        let f = try await fixture()
        XCTAssertEqual(BetterTeamsUI.ChatFilter.unread.emptyTitle(folderName: nil), "No Unread Chats")
        XCTAssertEqual(BetterTeamsUI.ChatFilter.unread.emptyMessage, "You're all caught up.")
        XCTAssertEqual(BetterTeamsUI.ChatFilter.folder("x").emptyTitle(folderName: "Project Team"), "No Chats in Project Team")

        let state = ChatSectionState(pager: ChatFilterPager(maxPages: 0, clock: StepClock()))
        state.toggle(.unread, list: f.list, rules: f.rules)
        XCTAssertEqual(state.filter, .unread)
        XCTAssertEqual(state.pager.phase, .finished, "no look-back budget: terminal at once")
        state.toggle(.mentions, list: f.list, rules: f.rules)
        XCTAssertEqual(state.filter, .mentions, "another filter switches, not clears")
        state.toggle(.mentions, list: f.list, rules: f.rules)
        XCTAssertEqual(state.filter, .all)
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async {
        await TestWait.until(interval: 0.005) { cond() }
        XCTAssertTrue(cond(), what)
    }
}
