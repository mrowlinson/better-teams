// EchoFixCellsTests.swift — ECHO-FIX: the 3 echo cells decode from the
// core payload; legacy payloads (keys absent) decode to nil.
import XCTest

@testable import OstMacCore

@MainActor
final class EchoFixCellsTests: XCTestCase {
    private func decode(_ json: String) throws -> ChatMessage {
        try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
    }

    func testCellsDecode() throws {
        let m = try decode("""
        {"id":"1","sender":"Ann","timestamp":"2026-11-19T18:28:32Z",\
        "content":"hi","raw":"<p>hi</p>","reactions":[],"reply_to":null,\
        "client_message_id":null,"importance":"high","subject":"Weekly sync",\
        "mentions":[{"id":"0","display":"channel","kind":"channel"}]}
        """)
        XCTAssertEqual(m.importance, "high")
        XCTAssertEqual(m.subject, "Weekly sync")
        XCTAssertEqual(m.mentionEntities, [ChatMention(id: "0", display: "channel", kind: "channel")])
    }

    func testLegacyPayloadDecodesToNil() throws {
        let m = try decode("""
        {"id":"1","sender":"Ann","timestamp":"2026-11-19T18:28:32Z",\
        "content":"hi","raw":"<p>hi</p>","reactions":[]}
        """)
        XCTAssertNil(m.importance)
        XCTAssertNil(m.subject)
        XCTAssertNil(m.mentionEntities)
    }

    func testNullCellsDecodeToNil() throws {
        let m = try decode("""
        {"id":"1","sender":"Ann","timestamp":"2026-11-19T18:28:32Z",\
        "content":"hi","importance":null,"subject":null,"mentions":null}
        """)
        XCTAssertNil(m.importance)
        XCTAssertNil(m.subject)
        XCTAssertNil(m.mentionEntities)
    }

    func testMentionsPreferEntities() throws {
        let m = try decode("""
        {"id":"1","sender":"Ann","timestamp":"2026-11-19T18:28:32Z",\
        "content":"hey","raw":"<p>hey</p>",\
        "mentions":[{"id":"0","display":"channel","kind":"channel"}]}
        """)
        XCTAssertEqual(m.mentions.count, 1)
        XCTAssertEqual(m.mentions[0].mentionType, "channel")
        XCTAssertTrue(Mentions.mentionsChannelOrEveryone(m.mentions))
        let mined = try decode("""
        {"id":"2","sender":"Ann","timestamp":"2026-11-19T18:28:32Z",\
        "content":"hey","raw":"<p>hey <at id=\\"0\\">channel</at></p>"}
        """)
        XCTAssertEqual(mined.mentions.count, 1)
        XCTAssertNil(mined.mentions[0].mentionType)
    }

    func testMentionRefMriJSON() {
        let stamped = WireMentionRef(token: "@channel", id: "0", display: "channel",
                                     kind: "channel", mri: "19:X@thread.tacv2")
        XCTAssertTrue(WireMentionRef.json(for: [stamped]).contains("19:X@thread.tacv2"))
    }

    func testMentionRefWithMri() {
        let bare = WireMentionRef(token: "@channel", id: "0", display: "channel", kind: "channel")
        XCTAssertEqual(bare.mri, "")
        XCTAssertEqual(bare.with(mri: "19:X@thread.tacv2").mri, "19:X@thread.tacv2")
        let set = WireMentionRef(token: "@channel", id: "0", display: "channel",
                                 kind: "channel", mri: "8:orgid:me")
        XCTAssertEqual(set.with(mri: "19:X@thread.tacv2").mri, "8:orgid:me")
    }
}
