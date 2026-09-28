// GapG2Tests.swift — gap-g2: side-by-side account windows.
// Stub fetchers/flips only; zero network. Fixture ids ONLY.
import XCTest

@testable import OstMacCore

@MainActor
final class GapG2Tests: XCTestCase {
    enum FlipBoom: Error { case fail }

    // MARK: - helpers

    func profile(_ id: String) -> ProfileResponse {
        try! JSONDecoder().decode(
            ProfileResponse.self,
            from: #"{"ok":true,"profile":"\#(id)"}"#.data(using: .utf8)!)
    }

    func account(
        id: String = "acct-b", name: String = "Beth Away"
    ) -> AccountRecord {
        AccountRecord(id: id, displayName: name)
    }

    func chatsVM(rows: [ChatItem] = []) -> ChatListViewModel {
        let rows = rows.isEmpty
            ? [
                ChatItem(
                    chatId: "19:a@thread.v2", name: "Alpha",
                    last_message_time: "t",
                    last_message_sender: "Ava",
                    last_message_preview: "old"),
                ChatItem(
                    chatId: "19:b@thread.v2", name: "Beta",
                    last_message_time: "t",
                    last_message_sender: "Bo",
                    last_message_preview: "old"),
            ]
            : rows
        return ChatListViewModel(fetcher: { _ in
            ChatsResponse(ok: true, chats: rows)
        })
    }

    func liveMsg(
        chatID: String = "19:a@thread.v2", text: String = "hi again",
        accountID: String? = nil
    ) -> RealtimeMessage {
        RealtimeMessage(
            chatID: chatID, msgId: "m-\(text)", sender: "Ava",
            text: text, time: "t2", isEdit: false,
            accountID: accountID)
    }

    // MARK: - gate: direct paths (no flips)

    func testGateUnseededRunsDirect() throws {
        let gate = AccountProfileGate()
        var flips: [String] = []
        let out = try gate.run(under: "acct-b", { 7 }) {
            flips.append($0)
            return self.profile($0)
        }
        XCTAssertEqual(out, 7)
        XCTAssertTrue(flips.isEmpty)
    }

    func testGateActiveRunsDirect() throws {
        let gate = AccountProfileGate()
        gate.seed("acct-b")
        var flips: [String] = []
        let out = try gate.run(under: "acct-b", { 7 }) {
            flips.append($0)
            return self.profile($0)
        }
        XCTAssertEqual(out, 7)
        XCTAssertTrue(flips.isEmpty)
    }

    func testGateNilAndBlankRunDirect() throws {
        let gate = AccountProfileGate()
        gate.seed("acct-a")
        var flips = 0
        for id: String? in [nil, "", "   "] {
            let out = try gate.run(under: id, { 7 }) { _ in
                flips += 1
                return self.profile("x")
            }
            XCTAssertEqual(out, 7)
        }
        XCTAssertEqual(flips, 0)
    }

    // MARK: - gate: flip-flop

    func testGateFlipFlopSequence() throws {
        let gate = AccountProfileGate()
        gate.seed("acct-a")
        var flips: [String] = []
        let out = try gate.run(under: "acct-b", { "ok" }) {
            flips.append($0)
            return self.profile($0)
        }
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(flips, ["acct-b", "acct-a"])
        XCTAssertEqual(gate.activeID, "acct-a")
        XCTAssertNil(gate.lastFlipError)
    }

    func testGateOpThrowStillFlipsBack() {
        let gate = AccountProfileGate()
        gate.seed("acct-a")
        var flips: [String] = []
        XCTAssertThrowsError(
            try {
                let _: Int = try gate.run(
                    under: "acct-b",
                    { throw FlipBoom.fail },
                    flip: {
                        flips.append($0)
                        return self.profile($0)
                    })
            }()
        )
        XCTAssertEqual(flips, ["acct-b", "acct-a"])
        XCTAssertEqual(gate.activeID, "acct-a")
    }

    func testGateFlipToFailureSkipsOp() {
        let gate = AccountProfileGate()
        gate.seed("acct-a")
        var ran = false
        XCTAssertThrowsError(
            try gate.run(under: "acct-b", {
                ran = true
                return 0
            }) { _ in throw FlipBoom.fail }
        )
        XCTAssertFalse(ran)
        XCTAssertEqual(gate.activeID, "acct-a")
        XCTAssertNotNil(gate.lastFlipError)
    }

    func testGateFlipBackFailureRetriesThenRecords() throws {
        let gate = AccountProfileGate()
        gate.seed("acct-a")
        var flips: [String] = []
        // Flip TO succeeds; every flip BACK fails.
        let out = try gate.run(under: "acct-b", { "ok" }) {
            flips.append($0)
            if $0 == "acct-a" { throw FlipBoom.fail }
            return self.profile($0)
        }
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(flips, ["acct-b", "acct-a", "acct-a"])
        XCTAssertNotNil(gate.lastFlipError)
    }

    func testGateSetActiveRecords() throws {
        let gate = AccountProfileGate()
        var flips: [String] = []
        let resp = try gate.setActive("acct-b") {
            flips.append($0)
            return self.profile($0)
        }
        XCTAssertEqual(flips, ["acct-b"])
        XCTAssertEqual(resp.profile, "acct-b")
        XCTAssertEqual(gate.activeID, "acct-b")
    }

    func testGateSetActiveFailureRecordsNothing() {
        let gate = AccountProfileGate()
        gate.seed("acct-a")
        XCTAssertThrowsError(
            try gate.setActive("acct-b") { _ in throw FlipBoom.fail }
        )
        XCTAssertEqual(gate.activeID, "acct-a")
        XCTAssertNotNil(gate.lastFlipError)
    }

    // MARK: - runners

    func testDirectRunnerPassesThrough() throws {
        let r = DirectAccountCoreRunner()
        XCTAssertEqual(try r.run({ 3 }, accountID: "acct-b"), 3)
        XCTAssertEqual(try r.run({ 4 }, accountID: nil), 4)
    }

    func testRecordingRunnerNotesAccounts() throws {
        let r = RecordingAccountCoreRunner()
        _ = try r.run({ 1 }, accountID: "acct-b")
        _ = try r.run({ 2 }, accountID: nil)
        XCTAssertEqual(r.accounts, ["acct-b", nil])
    }

    // MARK: - graph stamping

    func testGraphStampsConvAccountAndRunner() async {
        let chats = chatsVM()
        await chats.load()
        let rec = RecordingAccountCoreRunner()
        let g = AccountWindowGraph(
            account: account(), chats: chats, runner: rec)
        XCTAssertEqual(g.conv.accountID, "acct-b")
        XCTAssertTrue(
            (g.conv.coreRunner as? RecordingAccountCoreRunner) === rec)
        XCTAssertEqual(g.account.id, "acct-b")
    }

    func testGraphDefaultsDirectRunner() async {
        let chats = chatsVM()
        await chats.load()
        let g = AccountWindowGraph(account: account(), chats: chats)
        XCTAssertTrue(g.conv.coreRunner is DirectAccountCoreRunner)
    }

    // MARK: - AccountGraph (P0: the UI's one binding surface)

    func testWindowGraphServesAccountGraph() async {
        let chats = chatsVM()
        await chats.load()
        let concrete = AccountWindowGraph(account: account(), chats: chats)
        let g: any AccountGraph = concrete
        XCTAssertEqual(g.graphAccountID, "acct-b")
        XCTAssertFalse(g.isPrimaryGraph)
        XCTAssertTrue(g.chats === chats)
        XCTAssertTrue(g.conv === concrete.conv)
        XCTAssertTrue(g.pinnedMessages === concrete.pins)
        XCTAssertTrue(g.savedMessages === concrete.saved)
        XCTAssertNil(g.openChatID)
        // openChat is not exercised here: it runs conv.open, whose
        // history fetch goes through the live FFI (no fetch seam).
    }

    // MARK: - graph ingest (list + unread + open conv)

    func testGraphIngestBumpsListAccruesUnread() async {
        let chats = chatsVM()
        await chats.load()
        let g = AccountWindowGraph(account: account(), chats: chats)
        g.ingest(
            liveMsg(), decision: ChatFilter.Decision.notify(reason: "t"))
        // List bumped: the touched row leads with the new preview.
        XCTAssertEqual(g.chats.chats.first?.id, "19:a@thread.v2")
        XCTAssertEqual(
            g.chats.chats.first?.last_message_preview, "hi again")
        // Nothing open: unread accrues (window-local store).
        XCTAssertEqual(g.unread.count(for: "19:a@thread.v2"), 1)
        // Closed conv: no bubble (callers filter by open chat).
        XCTAssertTrue(g.conv.messages.isEmpty)
    }

    func testGraphIngestOpenChatBubblesWithoutUnread() async {
        let chats = chatsVM()
        await chats.load()
        let g = AccountWindowGraph(account: account(), chats: chats)
        g.openChatID = "19:a@thread.v2"
        g.ingest(
            liveMsg(), decision: ChatFilter.Decision.notify(reason: "t"))
        XCTAssertEqual(g.conv.messages.count, 1)
        XCTAssertEqual(g.conv.messages.first?.content, "hi again")
        XCTAssertEqual(g.unread.count(for: "19:a@thread.v2"), 0)
    }

    func testGraphIngestSkipAccruesNothing() async {
        let chats = chatsVM()
        await chats.load()
        let g = AccountWindowGraph(account: account(), chats: chats)
        // CONTRACT CHANGE (fid-lists D19): mute skips accrue ROW
        // unread now, so this no-accrual pin uses a non-mute skip.
        g.ingest(
            liveMsg(), decision: ChatFilter.Decision.skip(reason: "own-message"))
        XCTAssertEqual(g.unread.count(for: "19:a@thread.v2"), 0)
    }

    func testGraphIngestMutedSkipAccruesRowNotBadge() async {
        // Fid-lists D19 through the account-window graph: muted skip
        // bolds the row but stays out of the dock total.
        let chats = chatsVM()
        await chats.load()
        let g = AccountWindowGraph(account: account(), chats: chats)
        g.ingest(
            liveMsg(), decision: ChatFilter.Decision.skip(reason: "muted"))
        XCTAssertEqual(g.unread.count(for: "19:a@thread.v2"), 1)
        XCTAssertEqual(g.unread.total, 0)
    }

    func testGraphIngestBackgroundStampedEvent() async {
        let chats = chatsVM()
        await chats.load()
        let g = AccountWindowGraph(account: account(), chats: chats)
        g.openChatID = "19:b@thread.v2"
        // gap-g1-shaped arrival: stamped with the window's account.
        let ev = BackgroundChatEvent(
            accountID: "acct-b", accountName: "Beth Away",
            chatID: "19:b@thread.v2", chatName: "Beta",
            sender: "Bo", text: "bg hello", time: "t9",
            fingerprint: "t9\u{1F}Bo\u{1F}bg hello")
        g.ingest(
            ev.asRealtimeMessage,
            decision: ChatFilter.Decision.notify(reason: "t"))
        XCTAssertEqual(g.conv.messages.count, 1)
        XCTAssertEqual(g.conv.messages.first?.content, "bg hello")
        XCTAssertEqual(
            g.chats.chats.first?.last_message_preview, "bg hello")
    }

    // MARK: - registry

    func testRegistryOpenCloseReopenKeepsGraph() async {
        let reg = AccountWindowRegistry()
        let chats = chatsVM()
        await chats.load()
        XCTAssertTrue(reg.open(accountID: "acct-b") {
            AccountWindowGraph(account: self.account(), chats: chats)
        })
        XCTAssertTrue(reg.isOpen(accountID: "acct-b"))
        // Re-open refuses (focus instead — no dup window).
        XCTAssertFalse(reg.open(accountID: "acct-b") {
            AccountWindowGraph(account: self.account(), chats: chats)
        })
        let before = reg.graph(for: "acct-b")
        XCTAssertNotNil(before)
        // Close: visible drops, graph stays cached.
        reg.close(accountID: "acct-b")
        XCTAssertFalse(reg.isOpen(accountID: "acct-b"))
        XCTAssertTrue(reg.graph(for: "acct-b") === before)
        // Re-open restores the SAME graph (no reload).
        XCTAssertTrue(reg.open(accountID: "acct-b") {
            AccountWindowGraph(account: self.account(), chats: chats)
        })
        XCTAssertTrue(reg.graph(for: "acct-b") === before)
    }

    func testRegistryOpenBlankRefuses() {
        let reg = AccountWindowRegistry()
        XCTAssertFalse(reg.open(accountID: "  ") {
            AccountWindowGraph(account: self.account())
        })
        XCTAssertTrue(reg.openIDs.isEmpty)
    }

    func testRegistryDropEvicts() async {
        let reg = AccountWindowRegistry()
        let chats = chatsVM()
        await chats.load()
        _ = reg.open(accountID: "acct-b") {
            AccountWindowGraph(account: self.account(), chats: chats)
        }
        reg.drop(accountID: "acct-b")
        XCTAssertFalse(reg.isOpen(accountID: "acct-b"))
        XCTAssertNil(reg.graph(for: "acct-b"))
    }

    func testRegistryIngestRoutesByStamp() async {
        let reg = AccountWindowRegistry()
        let chats = chatsVM()
        await chats.load()
        _ = reg.open(accountID: "acct-b") {
            AccountWindowGraph(account: self.account(), chats: chats)
        }
        // Foreign stamp: refused, list untouched.
        let foreign = liveMsg(accountID: "acct-z")
        XCTAssertFalse(reg.ingest(
            foreign, decision: .notify(reason: "t"), activeID: "acct-a"))
        XCTAssertEqual(
            reg.graph(for: "acct-b")?.chats.chats.first?.id,
            "19:a@thread.v2")
        XCTAssertEqual(
            reg.graph(for: "acct-b")?.chats.chats.first?
                .last_message_preview, "old")
        // Matching stamp: consumed, preview bumped.
        let own = liveMsg(accountID: "acct-b")
        XCTAssertTrue(reg.ingest(
            own, decision: .notify(reason: "t"), activeID: "acct-a"))
        XCTAssertEqual(
            reg.graph(for: "acct-b")?.chats.chats.first?
                .last_message_preview, "hi again")
    }

    func testRegistryIngestNilStampResolvesActive() async {
        let reg = AccountWindowRegistry()
        let chats = chatsVM()
        await chats.load()
        // Window open on the ACTIVE account takes live (nil) events.
        _ = reg.open(accountID: "acct-a") {
            AccountWindowGraph(
                account: self.account(id: "acct-a", name: "Amy"),
                chats: chats)
        }
        XCTAssertTrue(reg.ingest(
            liveMsg(), decision: .notify(reason: "t"),
            activeID: "acct-a"))
        XCTAssertFalse(reg.ingest(
            liveMsg(), decision: .notify(reason: "t"),
            activeID: "acct-z"))
    }

    func testRegistryIngestClosedWindowRefuses() async {
        let reg = AccountWindowRegistry()
        let chats = chatsVM()
        await chats.load()
        _ = reg.open(accountID: "acct-b") {
            AccountWindowGraph(account: self.account(), chats: chats)
        }
        reg.close(accountID: "acct-b")
        // Cached but not visible: refused, unread untouched.
        XCTAssertFalse(reg.ingest(
            liveMsg(accountID: "acct-b"),
            decision: .notify(reason: "t"), activeID: "acct-a"))
        XCTAssertEqual(
            reg.graph(for: "acct-b")?.unread.count(
                for: "19:a@thread.v2"), 0)
    }

    // MARK: - roll-up merge (close handoff)

    func testRollupIngestMergesAdditively() {
        var roll = BackgroundUnreadRollup()
        roll.note(accountID: "acct-b", chatID: "19:a@thread.v2")
        roll.ingest(["19:a@thread.v2": 2, "19:b@thread.v2": 1], for: "acct-b")
        XCTAssertEqual(roll.counts(for: "acct-b")["19:a@thread.v2"], 3)
        XCTAssertEqual(roll.counts(for: "acct-b")["19:b@thread.v2"], 1)
        XCTAssertEqual(roll.total(for: "acct-b"), 4)
    }

    func testRollupIngestDropsJunk() {
        var roll = BackgroundUnreadRollup()
        roll.ingest(["": 5, "  ": 2, "19:a@thread.v2": 0, "19:b@thread.v2": -1],
                    for: "acct-b")
        XCTAssertTrue(roll.isEmpty)
        roll.ingest(["19:a@thread.v2": 1], for: "  ")
        XCTAssertTrue(roll.isEmpty)
    }
}
