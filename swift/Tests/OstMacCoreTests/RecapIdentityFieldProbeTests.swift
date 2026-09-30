// RecapIdentityFieldProbeTests.swift — opt-in live probe for the meeting
// identity the recap needs (notes "noIdentity"). RECAP_FIELDS_LIVE=1 to run.
// Read-only GETs: chat list, then per meeting chat one messages page, the
// thread, and the meeting-artifacts object when an identity is found.
// Prints field NAMES, counts, booleans and status codes only (the core
// computes the shape; values never cross into Swift). Any line that looks
// like an id, address, URL or token is suppressed and fails the test.
import COstMac
import Foundation
import XCTest
@testable import OstMacCore

final class RecapIdentityFieldProbeTests: XCTestCase {
    static let leakPatterns = [
        #"https?:"#, #"19:"#, #"8:orgid"#, #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}"#, #"[0-9a-fA-F]{16}"#,
        #"@[A-Za-z0-9-]+\.[A-Za-z]{2,}"#, #"eyJ"#, #"(?i)skypetoken|bearer|ESTSAUTH|FedAuth|rtFa|SPOIDCRL"#,
    ]

    static func leaks(_ line: String) -> Bool {
        leakPatterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    func testLeakCheckCatchesSamples() {
        XCTAssertTrue(Self.leaks("x https://a"))
        XCTAssertTrue(Self.leaks("x 19:meeting_abc"))
        XCTAssertTrue(Self.leaks("x 0f1e2d3c-aaaa-bbbb"))
        XCTAssertTrue(Self.leaks("x someone@example.com"))
        XCTAssertTrue(Self.leaks("x eyJhbGciOi"))
        XCTAssertFalse(Self.leaks(#"{"identity":{"genericMessageKeys":["iCalUid","meetingOrganizerId"]},"names":["@type"]}"#))
    }

    func testLiveIdentityFieldNames() throws {
        guard ProcessInfo.processInfo.environment["RECAP_FIELDS_LIVE"] == "1" else {
            throw XCTSkip("set RECAP_FIELDS_LIVE=1 to run the read-only identity field-name probe")
        }
        func note(_ s: String) {
            let line = "RECAPFIELDS " + s
            if Self.leaks(line) {
                print("RECAPFIELDS line suppressed (leak check)")
                XCTFail("leak check tripped")
            } else {
                print(line)
            }
        }
        let list: [ChatItem]
        do {
            list = ChatListViewModel.recencyOrdered(try CoreReads.chats(limit: 200).chats)
        } catch {
            note("chatList error")
            return
        }
        let meeting = list.filter { $0.chatId.contains("19:meeting_") }
        note("chatList total=\(list.count) meetingChats=\(meeting.count)")
        for (i, chat) in meeting.prefix(6).enumerated() {
            guard let raw = chat.chatId.withCString({ ostmac_meeting_recap_field_shape($0) }) else {
                note("chat\(i + 1) null")
                continue
            }
            let text = String(cString: raw)
            ostmac_free(raw)
            // Re-serialize with sorted keys (stable, compact).
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
               let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                note("chat\(i + 1) " + String(decoding: data, as: UTF8.self))
            } else {
                note("chat\(i + 1) unparsable")
            }
        }
    }
}
