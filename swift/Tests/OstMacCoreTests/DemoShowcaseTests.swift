// DemoShowcaseTests.swift — om-demo-showcase: the showcase thread
// exercises every rich feature in one conversation (mentions,
// reactions, replies, pins, cards/bot posts, images, receipts tail,
// day separators), routes through DemoData, zero real data.
import XCTest

@testable import OstMacCore

@MainActor
final class DemoShowcaseTests: XCTestCase {
    /// Every named feature present in one thread.
    func testShowcaseCoversEveryFeature() {
        let msgs = DemoData.showcaseMessages()
        XCTAssertEqual(msgs.count, 11)

        // Mentions: <at> tags mine.
        let atMsgs = msgs.filter { ($0.raw ?? "").contains("<at") }
        XCTAssertGreaterThanOrEqual(atMsgs.count, 2)
        XCTAssertFalse(MessageRender.mentions(fromRaw: atMsgs[0].raw).isEmpty)

        // Reactions: counts on bubbles.
        XCTAssertTrue(msgs.contains { !$0.reactions.isEmpty })

        // Replies: quote blocks resolving to in-thread parents.
        let replies = msgs.filter { $0.reply_to != nil }
        XCTAssertGreaterThanOrEqual(replies.count, 3)
        for r in replies {
            XCTAssertTrue(msgs.contains { $0.id == r.reply_to })
            XCTAssertTrue((r.raw ?? "").contains("<quote"))
        }

        // Pins: strip previews render for the seeded targets.
        for m in msgs.prefix(2) {
            XCTAssertFalse(PinnedMessages.preview(for: m).isEmpty)
        }

        // Cards/bot posts: card JSON + digest rows.
        XCTAssertTrue(msgs.contains { MessageRender.isCardPayload($0.content) })
        XCTAssertTrue(msgs.contains {
            !MessageRender.botPosts(fromRaw: $0.raw ?? $0.content).isEmpty
        })

        // Images: offline demo:// fixtures only (link-row hrefs are
        // inert text, never fetched).
        let imgs = msgs.filter { ($0.raw ?? "").contains("demo://") }
        XCTAssertGreaterThanOrEqual(imgs.count, 2)
        for m in msgs {
            let raw = m.raw ?? ""
            for part in raw.components(separatedBy: "<img") {
                if part.hasPrefix(" src=\"http") {
                    XCTFail("showcase images stay offline: \(m.id)")
                }
            }
        }

        // Receipts: own tail (demo open adopts peers through it → Seen).
        XCTAssertTrue(msgs.last?.isOwn == true)

        // Day separators: Yesterday + Today.
        let days = Set(msgs.map { MessageRender.dayKey($0.timestamp) })
        XCTAssertEqual(days.count, 2)
    }

    /// Wiring: sidebar row, routing, mention flag, shared files.
    func testShowcaseWiring() {
        let row = DemoData.showcaseChat()
        XCTAssertEqual(row.id, DemoData.showcaseID)
        XCTAssertTrue(DemoData.chats.contains { $0.id == DemoData.showcaseID })
        XCTAssertEqual(DemoData.messages(for: DemoData.showcaseID).count, 11)
        XCTAssertEqual(DemoData.name(for: DemoData.showcaseID), "Demo — Showcase")
        XCTAssertTrue(DemoData.mentionedChatIDs.contains(DemoData.showcaseID))
        XCTAssertFalse(DemoData.sharedFiles(for: DemoData.showcaseID).isEmpty)
        // Tail tracks the thread: preview/sender/time match last bubble.
        let last = DemoData.showcaseMessages().last
        XCTAssertEqual(row.last_message_preview, last?.content)
        XCTAssertEqual(row.last_message_sender, last?.sender)
        // Zero real data: only the fictional crew + fictional bots.
        let allowed: Set<String> = [
            "Megan Harper", "Tom Becker", "Ava Lindqvist", "Me",
            "Tech News RSS", "Build Bot",
        ]
        for m in DemoData.showcaseMessages() {
            XCTAssertTrue(allowed.contains(m.sender), "real name leak: \(m.sender)")
        }
    }
}
