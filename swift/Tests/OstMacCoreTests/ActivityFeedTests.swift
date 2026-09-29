// ActivityFeedTests.swift — DEMOLEAK: the live Activity feed reads the
// Teams feed (48:notifications), merges without flashing, keeps rows on
// failure, and stale demo fixtures are scrubbed from live defaults.
import XCTest

@testable import OstMacCore

@MainActor
final class ActivityFeedTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test-activityfeed-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// One feed message; `activity` rides as a JSON string (as Teams
    /// sends it) unless `asObject`.
    private func message(
        id: String, type: String, subtype: String? = nil, thread: String? = "19:abc@thread.v2",
        source: String? = "1759000000000", actor: String = "Emma Clarke",
        preview: String = "<p>Can you review this?</p>", at: String = "2026-09-28T09:00:00.000Z",
        read: Bool = false, asObject: Bool = false
    ) -> [String: Any] {
        var act: [String: Any] = [
            "activityType": type, "activityId": "a-\(id)", "sourceUserImDisplayName": actor,
            "messagePreview": preview, "activityTimestamp": at, "sourceUserId": "8:orgid:caller",
        ]
        if let subtype { act["activitySubtype"] = subtype }
        if let thread { act["sourceThreadId"] = thread }
        if let source { act["sourceMessageId"] = source }
        let actValue: Any = asObject
            ? act
            : String(data: try! JSONSerialization.data(withJSONObject: act), encoding: .utf8)!
        return ["id": id, "properties": ["activity": actValue, "isread": read ? "true" : "false"]]
    }

    private func page(_ messages: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["messages": messages])
    }

    func testParseMapsEveryKindWithUnreadAndJumpTargets() {
        let data = page([
            message(id: "1", type: "mentionInChat", at: "2026-09-28T09:06:00Z"),
            message(id: "2", type: "mentionInChat", subtype: "everyone", source: "1759000000002",
                    at: "2026-09-28T09:05:00Z", asObject: true),
            message(id: "3", type: "replyToReply", source: "1759000000003", at: "2026-09-28T09:04:00Z", read: true),
            message(id: "4", type: "reactionInChat", source: "1759000000004", at: "2026-09-28T09:03:00Z"),
            message(id: "5", type: "callMissed", source: nil, at: "2026-09-28T09:02:00Z"),
            message(id: "6", type: "meetingStarted", source: nil, at: "2026-09-28T09:01:00Z"),
            message(id: "7", type: "customActivity", thread: nil, source: nil, actor: "Approvals"),
            ["id": "8", "properties": ["isread": "false"]], // not an activity item
        ])
        let items = ActivityFeed.parse(data)
        XCTAssertEqual(items.map(\.kind), [.mention, .channelBlast, .reply, .reaction, .missedCall, .meeting, .app])
        XCTAssertEqual(items[0].id, ActivityItem.makeID(kind: .mention, chatID: "19:abc@thread.v2",
                                                        messageID: "1759000000000"),
                       "same id as the realtime path, so the two never double up")
        XCTAssertEqual(items[0].snippet, "Can you review this?")
        XCTAssertEqual(items[0].actor, "Emma Clarke")
        XCTAssertFalse(items[0].reviewed)
        XCTAssertTrue(items[2].reviewed, "feed read flag → reviewed")
        XCTAssertEqual(items[4].callerID, "8:orgid:caller")
        XCTAssertNil(items[4].messageID)
        XCTAssertEqual(items[0].at, 1_790_586_360)
        XCTAssertTrue(ActivityTarget(chatID: items[0].chatID, messageID: items[0].messageID).canJump)
        XCTAssertFalse(ActivityTarget(chatID: items[6].chatID, messageID: items[6].messageID).canJump)
    }

    func testAdoptFeedKeepsLocalStateAndPublishesOnlyOnChange() {
        let store = ActivityStore(defaults: defaults)
        let first = ActivityFeed.parse(page([
            message(id: "1", type: "mentionInChat", at: "2026-09-28T09:06:00Z"),
            message(id: "2", type: "replyInChat", source: "1759000000002", at: "2026-09-28T09:05:00Z"),
        ]))
        store.adoptFeed(first)
        XCTAssertEqual(store.items.count, 2)
        store.markReviewed(id: first[0].id)
        var publishes = 0
        let sub = store.objectWillChange.sink { publishes += 1 }
        store.adoptFeed(first) // same page again, server still unread
        XCTAssertEqual(publishes, 0, "an unchanged page must not republish (no flash)")
        XCTAssertTrue(store.item(id: first[0].id)!.reviewed, "local review survives a refresh")
        store.adoptFeed(ActivityFeed.parse(page([
            message(id: "2", type: "replyInChat", source: "1759000000002", at: "2026-09-28T09:05:00Z", read: true),
        ])))
        XCTAssertTrue(store.item(id: first[1].id)!.reviewed, "read in Teams → reviewed here")
        XCTAssertEqual(store.items.count, 2, "rows the page no longer lists stay")
        sub.cancel()
        XCTAssertEqual(ActivityStore(defaults: defaults).items.count, 2, "feed rows persist")
    }

    func testRefreshFailureKeepsRowsAndSetsQuietError() async {
        let store = ActivityStore(defaults: defaults)
        let rows = ActivityFeed.parse(page([message(id: "1", type: "mentionInChat")]))
        store.feedReader = { rows }
        await store.refresh()
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNil(store.lastError)
        struct Down: Error {}
        store.feedReader = { throw Down() }
        await store.refresh()
        XCTAssertEqual(store.items.map(\.id), rows.map(\.id), "failure keeps the last real rows")
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.items.contains { DemoFixture.isFixtureID($0.chatID) }, "never demo")
        store.feedReader = { rows }
        await store.refresh()
        XCTAssertNil(store.lastError, "a good read clears the notice")
    }

    /// Root cause pin: an old demo run left fixture rows in the live
    /// defaults. The scrub drops them (and a demo selection) and keeps
    /// real rows and unrelated keys byte-for-byte.
    func testScrubDropsPersistedDemoRowsOnly() throws {
        let gate = try XCTUnwrap(DemoGate.launch(args: ["--demo"]))
        let demoRows = ActivityStore.demo(gate).items
        XCTAssertFalse(demoRows.isEmpty)
        let real = ActivityFeed.parse(page([message(id: "1", type: "mentionInChat")]))
        defaults.set(try JSONEncoder().encode(real + demoRows), forKey: ActivityStore.defaultsKey)
        let nav = #"{"activity":{"path":["mention:demo-showcase:sc-1"]},"chat":{"path":["19:abc@thread.v2"]}}"#
        defaults.set(Data(nav.utf8), forKey: "bt.nav.default")
        defaults.set("demo-2", forKey: "om.lastChat")
        defaults.set("demo-day notes", forKey: "draft.keep")
        defaults.set(["19:abc@thread.v2"], forKey: "pins.keep")

        let touched = DemoFixture.scrubLive(defaults)
        XCTAssertEqual(Set(touched), [ActivityStore.defaultsKey, "bt.nav.default", "om.lastChat"])
        XCTAssertEqual(ActivityStore(defaults: defaults).items.map(\.id), real.map(\.id))
        let navOut = try XCTUnwrap(defaults.data(forKey: "bt.nav.default"))
        XCTAssertFalse(String(decoding: navOut, as: UTF8.self).contains("demo-"))
        XCTAssertTrue(String(decoding: navOut, as: UTF8.self).contains("19:abc@thread.v2"))
        XCTAssertNil(defaults.object(forKey: "om.lastChat"))
        XCTAssertEqual(defaults.string(forKey: "draft.keep"), "demo-day notes", "text with spaces is not an id")
        XCTAssertEqual(defaults.stringArray(forKey: "pins.keep"), ["19:abc@thread.v2"])
        XCTAssertEqual(DemoFixture.scrubLive(defaults), [], "idempotent")
    }

    func testFixtureIDShapes() {
        for id in ["demo-2", "mention:demo-showcase:sc-1", "missedCall:-:demo-missed", "web:demo-tab-sprint"] {
            XCTAssertTrue(DemoFixture.isFixtureID(id), id)
        }
        for id in ["19:abc@thread.v2", "48:notifications", "8:orgid:1234", "demo", "demo-", "a demo-2", "ta.demo-app"] {
            XCTAssertFalse(DemoFixture.isFixtureID(id), id)
        }
    }

    /// Type strings seen on a live feed page (CONTACTCARD2): followed
    /// channel posts and Graph-sent meeting items were landing as app
    /// notifications.
    func testLiveTypesMapFollowedPostsAndGraphMeetings() {
        XCTAssertEqual(ActivityFeed.kind(type: "follow", subtype: "channelNewMessage"), .channelPost)
        XCTAssertEqual(ActivityFeed.kind(type: "msGraph", subtype: "privateMeetingCreated"), .meeting)
        XCTAssertEqual(ActivityFeed.kind(type: "msGraph", subtype: "channelMeetingCanceled"), .meeting)
        XCTAssertEqual(ActivityFeed.kind(type: "msGraph", subtype: "approvalRequested"), .app)
        XCTAssertEqual(ActivityFeed.kind(type: "mention", subtype: "team"), .channelBlast)
        XCTAssertEqual(ActivityFeed.kind(type: "mentionInChat", subtype: "person"), .mention)
        XCTAssertEqual(ActivityFeed.kind(type: "reactionInChat", subtype: "yes-tone2"), .reaction)
        let items = ActivityFeed.parse(page([
            message(id: "1", type: "follow", subtype: "channelNewMessage", source: "1759000000011"),
            message(id: "2", type: "msGraph", subtype: "privateMeetingUpdated", thread: nil, source: "1759000000012"),
        ]))
        let post = items.first { $0.kind == .channelPost }
        XCTAssertEqual(post?.messageID, "1759000000011", "a followed post jumps to its message")
        XCTAssertEqual(post?.id, ActivityItem.makeID(kind: .channelPost, chatID: "19:abc@thread.v2", messageID: "1759000000011"))
        XCTAssertEqual(items.first { $0.kind == .meeting }?.chatID, "", "Graph meeting items have no thread")
    }
}
