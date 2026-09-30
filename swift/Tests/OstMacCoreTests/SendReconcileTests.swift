// SendReconcileTests — §106 (SENDFIX): the optimistic bubble always
// settles (POST answer / echo / verify), retries reuse the client
// message id (never a second server copy), and the open chat takes new
// messages from the live feed and the fallback poll cadence.
// Fake transport + fake clock only: no network, no user dirs.
import Foundation
import XCTest
@testable import OstMacCore

/// In-memory chat service: records every post, answers finds from what
/// "landed", and can lose answers / block posts.
private final class FakeService: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var posts: [OutgoingSend] = []
    private var landed: [String: ChatMessage] = [:] // cmid → server row
    /// Posts that throw a timeout; `landsAnyway` = the server kept it.
    var failPosts = 0
    var landsAnyway = false
    var nameIDs = true
    var gate: DispatchSemaphore?
    private var next = 100

    func land(_ r: OutgoingSend) -> ChatMessage {
        if let row = landed[r.clientMessageID] { return row }
        next += 1
        let row = ChatMessage(id: "S\(next)", sender: "Owner", timestamp: "2026-09-28T18:20:06Z",
                              content: r.text, clientMessageID: r.clientMessageID)
        landed[r.clientMessageID] = row
        return row
    }

    var landedCount: Int { lock.lock(); defer { lock.unlock() }; return landed.count }
    var postCount: Int { lock.lock(); defer { lock.unlock() }; return posts.count }

    var transport: SendTransport {
        SendTransport(
            post: { [self] r in
                gate?.wait()
                lock.lock(); defer { lock.unlock() }
                posts.append(r)
                if failPosts > 0 {
                    failPosts -= 1
                    if landsAnyway { _ = land(r) }
                    throw URLError(.timedOut)
                }
                let row = land(r)
                return nameIDs ? row.id : nil
            },
            find: { [self] _, cmid in
                lock.lock(); defer { lock.unlock() }
                return landed[cmid]
            })
    }
}

@MainActor
final class SendReconcileTests: XCTestCase {
    private func store(_ svc: FakeService) -> ConversationStore {
        let s = ConversationStore()
        s.attachLiveForTesting(chatID: "19:chat@thread.v2", ownName: "Owner")
        s.sendTransport = svc.transport
        return s
    }

    private func settle(_ s: ConversationStore, file: StaticString = #filePath, line: UInt = #line,
                        until done: @escaping () -> Bool) async {
        await TestWait.until { done() }
        XCTAssertTrue(done(), "did not settle", file: file, line: line)
    }

    func testPostAnswerSettlesBubbleWithServerID() async {
        let svc = FakeService()
        let s = store(svc)
        s.send(text: "test")
        XCTAssertEqual(s.messages.count, 1)
        XCTAssertTrue(s.messages[0].id.hasPrefix("pending-"))
        let cmid = s.messages[0].clientMessageID
        XCTAssertEqual(cmid?.count, 19)
        await settle(s) { !s.messages[0].id.hasPrefix("pending-") }
        XCTAssertEqual(s.messages.map(\.id), ["S101"])
        XCTAssertEqual(s.messages[0].clientMessageID, cmid)
        XCTAssertTrue(s.messages[0].isOwn)
        XCTAssertTrue(s.failedIDs.isEmpty)
        XCTAssertEqual(svc.postCount, 1)
    }

    func testEchoSettlesBubbleBeforeAnswerAndAnswerAddsNoDuplicate() async {
        let svc = FakeService()
        svc.gate = DispatchSemaphore(value: 0)
        let s = store(svc)
        s.send(text: "test")
        let local = s.messages[0]
        // Push echo (server id + same client id) lands while the POST hangs.
        s.ingest(realtime: RealtimeMessage(
            chatID: "19:chat@thread.v2", msgId: "S900", sender: "Owner", text: "test",
            time: "2026-09-28T18:20:06Z", isEdit: false, clientMessageID: local.clientMessageID))
        XCTAssertEqual(s.messages.map(\.id), ["S900"])
        XCTAssertFalse(s.messages[0].edited)
        XCTAssertTrue(s.messages[0].isOwn)
        svc.gate?.signal()
        await settle(s) { svc.postCount == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000) // negative window: proves the late answer adds no row
        XCTAssertEqual(s.messages.count, 1, "answer after echo must not add a row")
        XCTAssertTrue(s.failedIDs.isEmpty)
    }

    func testTimeoutVerifiesAndSettlesWithoutRepost() async {
        let svc = FakeService()
        svc.failPosts = 1
        svc.landsAnyway = true // answer lost, message landed
        let s = store(svc)
        s.send(text: "test")
        await settle(s) { !s.messages[0].id.hasPrefix("pending-") }
        XCTAssertEqual(s.messages.map(\.id), ["S101"])
        XCTAssertTrue(s.failedIDs.isEmpty)
        XCTAssertEqual(svc.postCount, 1)
        XCTAssertEqual(svc.landedCount, 1)
    }

    func testTimeoutNotFoundFailsThenRetryReusesClientIDWithoutDuplicate() async {
        let svc = FakeService()
        svc.failPosts = 1 // timed out and did NOT land
        let s = store(svc)
        s.send(text: "test")
        let localID = s.messages[0].id
        await settle(s) { s.failedIDs.contains(localID) }
        XCTAssertEqual(s.messages.map(\.id), [localID], "failed row stays, one row")
        XCTAssertEqual(s.retry(id: localID), "test")
        await settle(s) { !s.messages[0].id.hasPrefix("pending-") }
        XCTAssertEqual(svc.postCount, 2)
        XCTAssertEqual(Set(svc.posts.map(\.clientMessageID)).count, 1, "retry reuses the client id")
        XCTAssertEqual(svc.landedCount, 1, "one server message")
        XCTAssertEqual(s.messages.count, 1)
        XCTAssertTrue(s.failedIDs.isEmpty)
    }

    func testRetryAfterLateLandingSettlesWithoutSecondPost() async {
        let svc = FakeService()
        svc.failPosts = 1
        let s = store(svc)
        s.send(text: "test")
        let localID = s.messages[0].id
        await settle(s) { s.failedIDs.contains(localID) }
        // The first post shows up on the server after the verify read.
        _ = svc.land(svc.posts[0])
        s.retry(id: localID)
        await settle(s) { !s.messages[0].id.hasPrefix("pending-") }
        XCTAssertEqual(svc.postCount, 1, "verify-first retry never re-posts a landed send")
        XCTAssertEqual(s.messages.count, 1)
    }

    func testUnnamedAnswerSettlesViaReadBack() async {
        let svc = FakeService()
        svc.nameIDs = false
        let s = store(svc)
        s.send(text: "test")
        await settle(s) { !s.messages[0].id.hasPrefix("pending-") }
        XCTAssertEqual(s.messages.map(\.id), ["S101"])
    }

    func testIncomingMessageInOpenChatAppendsOnce() {
        let s = ConversationStore()
        s.attachLiveForTesting(
            chatID: "19:chat@thread.v2",
            messages: [ChatMessage(id: "1", sender: "Owner", timestamp: "t1", content: "hi", isOwn: true)],
            ownName: "Owner")
        let reply = RealtimeMessage(
            chatID: "19:chat@thread.v2", msgId: "2", sender: "Alice Smith", text: "reply",
            time: "t2", isEdit: false, clientMessageID: "777")
        s.ingest(realtime: reply)
        s.ingest(realtime: reply) // redelivery (push + poll) = same row
        XCTAssertEqual(s.messages.map(\.id), ["1", "2"])
        XCTAssertFalse(s.messages[1].isOwn)
        XCTAssertFalse(s.messages[1].edited)
    }

    func testPageMergeSettlesLocalRowsByClientIDAndKeepsUnseenConfirmed() {
        let old = ChatMessage(id: "1", sender: "A", timestamp: "t1", content: "a")
        let pending = ChatMessage(id: "pending-5", sender: "Me", timestamp: "t2", content: "x",
                                  isOwn: true, clientMessageID: "5")
        let confirmed = ChatMessage(id: "S7", sender: "Owner", timestamp: "t3", content: "y",
                                    isOwn: true, clientMessageID: "7")
        let list = [old, pending, confirmed]
        // Page carries the pending send (by client id) but predates S7.
        let page = [old, ChatMessage(id: "S5", sender: "Owner", timestamp: "t2", content: "x",
                                     clientMessageID: "5")]
        let merged = ConversationStore.mergedNewest(page, into: list, keeping: ["S7"])
        XCTAssertEqual(merged.map(\.id), ["1", "S5", "S7"])
        // Without the unseen hold the stale page would drop the new send.
        XCTAssertEqual(ConversationStore.mergedNewest(page, into: list).map(\.id), ["1", "S5"])
    }

    func testPollCadenceIsFastAfterActivityAndStopsWhenHidden() {
        var t = Date(timeIntervalSince1970: 1_000)
        let poller = OpenChatPoller(now: { t })
        XCTAssertFalse(poller.shouldPoll(chatOpen: false, visible: true, busy: false))
        XCTAssertTrue(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        t += 1
        XCTAssertFalse(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        t += 1 // 2s: hot cadence
        XCTAssertTrue(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        t += 2
        XCTAssertFalse(poller.shouldPoll(chatOpen: true, visible: false, busy: false), "hidden = no poll")
        XCTAssertFalse(poller.shouldPoll(chatOpen: true, visible: true, busy: true), "never over a load")
        t += 100 // quiet 104s → warm (5s)
        XCTAssertTrue(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        t += 3
        XCTAssertFalse(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        poller.noteActivity(pollNow: true) // focus / arrival
        XCTAssertTrue(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        t += 400 // quiet 400s → idle cadence (15s)
        XCTAssertTrue(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        t += 10
        XCTAssertFalse(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
        t += 5
        XCTAssertTrue(poller.shouldPoll(chatOpen: true, visible: true, busy: false))
    }

    /// File send (§106): a failed attempt keeps the row's client message
    /// id; Retry re-sends with the SAME id and verifies first (a file
    /// message that landed is never posted twice).
    @MainActor
    func testFileSendRetryReusesClientIDAndVerifiesFirst() async {
        let calls = LockedBox<[(String, Bool)]>([])
        let store = ComposeAttachmentsStore(
            uploadIdem: { _, path, cmid, verifyFirst in
                calls.mutate { $0.append((cmid, verifyFirst)) }
                if calls.value.count == 1 { throw URLError(.timedOut) }
                return SharedFileUploadResponse(ok: true, file: SharedFile(id: "f", name: path, size: 1))
            },
            sizeProbe: { _ in 10 })
        store.stage(paths: ["/x/a.pdf"])
        _ = await store.uploadPending(chatID: "19:a_b@unq.gbl.spaces")
        guard let row = store.attachments.first, case .failed = row.state else {
            return XCTFail("first attempt must fail")
        }
        store.retry(id: row.id)
        let done = await store.uploadPending(chatID: "19:a_b@unq.gbl.spaces")
        XCTAssertEqual(done.count, 1)
        let c = calls.value
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].0, c[1].0, "retry reuses the client message id")
        XCTAssertEqual(c[0].0.count, 19)
        XCTAssertFalse(c[0].1)
        XCTAssertTrue(c[1].1, "retry verifies first")
    }

    /// A live push that lands while a poll GET is in flight: the stale
    /// page (served before the push) must not drop the pushed row.
    func testStalePageKeepsRowPushedAfterIt() {
        let a = ChatMessage(id: "1000", sender: "A", timestamp: "t1", content: "x")
        let b = ChatMessage(id: "2000", sender: "B", timestamp: "t2", content: "y")
        let pushed = ChatMessage(id: "3000", sender: "B", timestamp: "t3", content: "z")
        let merged = ConversationStore.mergedNewest([a, b], into: [a, b, pushed])
        XCTAssertEqual(merged.map(\.id), ["1000", "2000", "3000"])
        // A row inside the page window that the page no longer carries
        // (deleted server-side) still goes.
        let gone = ConversationStore.mergedNewest([a, pushed], into: [a, b, pushed])
        XCTAssertEqual(gone.map(\.id), ["1000", "3000"])
    }
}
