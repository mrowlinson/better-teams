// ShareOutlookTests.swift — SHAREOUTLOOK R1: draft prefill, address
// validation, sendMail body shape, and the Graph client on a stub
// transport (zero live network).
import Foundation
import XCTest
@testable import OstMacCore

final class ShareOutlookTests: XCTestCase {
    private func msg(sender: String = "Megan Harper", content: String = "Hello") -> ChatMessage {
        ChatMessage(id: "m1", sender: sender, timestamp: "2026-11-18T10:00:00.0000000",
                    content: content, isOwn: false)
    }

    // MARK: prefill

    func testPrefillNamesSenderAndBody() {
        let d = ShareOutlookDraft.prefill(from: msg(sender: "Megan Harper", content: "Hello there"))
        XCTAssertEqual(d.to, "")
        XCTAssertEqual(d.subject, "Message from Megan Harper")
        XCTAssertEqual(d.body, "Hello there")
    }

    func testPrefillBlankSenderIsUnknown() {
        let d = ShareOutlookDraft.prefill(from: msg(sender: "  ", content: "Hi"))
        XCTAssertEqual(d.subject, "Message from Unknown")
    }

    // MARK: validation

    func testValidAddresses() {
        for a in ["a@b.co", "alex.morgan@example.com", " x@y.zz "] {
            XCTAssertTrue(ShareOutlookDraft.isValidAddress(a), a)
        }
    }

    func testInvalidAddresses() {
        for a in ["", "   ", "plain", "@nodomain", "noat.com", "a@", "@b.co",
                  "a@b", "a@b@", "two@@signs.co", "a@.co", "a@b."] {
            XCTAssertFalse(ShareOutlookDraft.isValidAddress(a), a)
        }
    }

    func testCanSendNeedsValidToAndBody() {
        XCTAssertTrue(ShareOutlookDraft(to: "a@b.co", subject: "", body: "x").canSend,
                      "blank subject is fine")
        XCTAssertFalse(ShareOutlookDraft(to: "nope", subject: "s", body: "x").canSend)
        XCTAssertFalse(ShareOutlookDraft(to: "a@b.co", subject: "s", body: "  ").canSend)
        XCTAssertFalse(ShareOutlookDraft().canSend)
    }

    // MARK: body

    func testSendMailBodyShape() throws {
        let d = ShareOutlookDraft(to: " a@b.co ", subject: "S", body: "B")
        let top = d.sendMailBody()
        XCTAssertEqual(top["saveToSentItems"] as? Bool, true)
        let message = try XCTUnwrap(top["message"] as? [String: Any])
        XCTAssertEqual(message["subject"] as? String, "S")
        let body = try XCTUnwrap(message["body"] as? [String: Any])
        XCTAssertEqual(body["contentType"] as? String, "Text")
        XCTAssertEqual(body["content"] as? String, "B")
        let rcpts = try XCTUnwrap(message["toRecipients"] as? [[String: [String: String]]])
        XCTAssertEqual(rcpts.count, 1)
        XCTAssertEqual(rcpts[0]["emailAddress"]?["address"], "a@b.co")
    }

    // MARK: client

    private func client(_ stub: OOOStubHTTP) -> ShareOutlookGraph {
        ShareOutlookGraph(http: stub) { "token" }
    }

    func testSendPostsToSendMail() throws {
        let stub = OOOStubHTTP()
        try client(stub).send(ShareOutlookDraft(to: "a@b.co", subject: "S", body: "B"))
        XCTAssertEqual(stub.calls.count, 1)
        let call = stub.calls[0]
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.url.host, "graph.microsoft.com")
        XCTAssertEqual(call.url.path, "/v1.0/me/sendMail")
        let raw = try XCTUnwrap(call.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual((json["message"] as? [String: Any])?["subject"] as? String, "S")
        XCTAssertEqual(json["saveToSentItems"] as? Bool, true)
    }

    func testSend403IsMissingScope() {
        let stub = OOOStubHTTP()
        stub.status = 403
        stub.payload = Data("{\"error\":{\"code\":\"ErrorAccessDenied\",\"message\":\"denied\"}}".utf8)
        XCTAssertThrowsError(
            try client(stub).send(ShareOutlookDraft(to: "a@b.co", subject: "S", body: "B")))
        { e in
            XCTAssertTrue(String(describing: e).contains("Mail.Send is not granted"), "\(e)")
        }
    }
}
