// CopilotTests.swift — COPILOT-BUILD: envelope decode, markdown,
// demo seeds, store state machine (stub transport, no core).
import XCTest

@testable import OstMacCore

@MainActor
final class CopilotTests: XCTestCase {
    // MARK: - envelopes

    func testLicensePayloadDecodes() throws {
        let p: CopilotLicensePayload = try CoreCopilotTransport.decode(Data(
            #"{"ok":true,"status":"UNLICENSED","is_eap":false,"is_debug":false,"licensed":false,"reason":"no seat"}"#.utf8))
        XCTAssertEqual(p.status, "UNLICENSED")
        XCTAssertFalse(p.licensed)
        XCTAssertEqual(p.reason, "no seat")
    }

    func testAuthFailureKeepsKind() throws {
        do {
            let _: CopilotLicensePayload = try CoreCopilotTransport.decode(Data(
                #"{"ok":false,"code":"auth","error":"sign in to use Copilot"}"#.utf8))
            XCTFail("must throw")
        } catch let f as CopilotFailure {
            XCTAssertEqual(f.kind, .auth)
            XCTAssertEqual(f.message, "sign in to use Copilot")
        }
    }

    func testSharedErrorShapeSurfacesCodeDetail() throws {
        do {
            let _: CopilotPollPayload = try CoreCopilotTransport.decode(Data(
                #"{"ok":false,"error":"arg","detail":"unknown turn"}"#.utf8))
            XCTFail("must throw")
        } catch let f as CopilotFailure {
            XCTAssertEqual(f.kind, .server)
            XCTAssertTrue(f.message.contains("unknown turn"))
        }
    }

    func testPollPayloadDecodesAnswer() throws {
        let p: CopilotPollPayload = try CoreCopilotTransport.decode(Data(
            #"{"ok":true,"turn_id":"t","text":"Hi","done":true,"answer":{"text":"Hi","attributions":[{"title":"Doc","url":"https://example.invalid/d"}],"suggestions":["More?"],"conversation_id":"c1"}}"#.utf8))
        XCTAssertTrue(p.done)
        XCTAssertEqual(p.answer?.attributions?.first?.title, "Doc")
        XCTAssertEqual(p.answer?.suggestions, ["More?"])
        XCTAssertEqual(p.answer?.conversationID, "c1")
    }

    // MARK: - markdown

    func testMarkdownBoldAndFallback() {
        let a = CopilotMarkdown.attributed("**Hi** there")
        XCTAssertEqual(String(a.characters), "Hi there")
        // Unparseable input falls back to verbatim, never empty.
        let b = CopilotMarkdown.attributed("[broken](ht tp://x)")
        XCTAssertFalse(String(b.characters).isEmpty)
    }

    // MARK: - demo seeds

    func testDemoSeedsCoverFourStates() {
        let empty = CopilotDemo.seed(.empty)
        XCTAssertTrue(empty.messages.isEmpty)
        XCTAssertEqual(empty.chat, .idle)
        let streaming = CopilotDemo.seed(.streaming)
        XCTAssertEqual(streaming.messages.count, 2)
        XCTAssertTrue(streaming.messages[1].isStreaming)
        XCTAssertEqual(streaming.chat, .streaming)
        XCTAssertEqual(streaming.progress, CopilotDemo.progress)
        let finished = CopilotDemo.seed(.finished)
        XCTAssertEqual(finished.messages[1].attributions.count, 2)
        XCTAssertEqual(finished.messages[1].suggestions.count, 2)
        XCTAssertEqual(finished.chat, .ready)
        let gated = CopilotDemo.seed(.unlicensed)
        XCTAssertEqual(gated.chat, .disabled(CopilotDemo.unlicensedReason))
        let gatedStore = CopilotStore(transport: StubCopilotTransport(
            licensePayload: CopilotLicensePayload(status: "UNLICENSED", licensed: false,
                                           reason: CopilotDemo.unlicensedReason, error: nil)))
        gatedStore.adoptDemo(messages: gated.messages, state: gated.chat,
                             license: gated.license, progress: gated.progress)
        XCTAssertFalse(gatedStore.inputEnabled)
    }

    func testWorkGroundedIsPaidSeatOnly() {
        XCTAssertTrue(CopilotLicenseState.licensed(status: "COPILOT_LICENSE", note: nil).workGrounded)
        XCTAssertFalse(CopilotLicenseState.licensed(status: "PAYG", note: nil).workGrounded)
        XCTAssertFalse(CopilotLicenseState.licensed(status: "PROMO_WITH_CREDITS", note: nil).workGrounded)
        XCTAssertFalse(CopilotLicenseState.unlicensed(reason: "x").workGrounded)
        XCTAssertFalse(CopilotLicenseState.unknown.workGrounded)
    }

    func testDemoPinHoldsSeedAgainstRefresh() async {
        let store = CopilotStore(transport: StubCopilotTransport(
            licensePayload: CopilotLicensePayload(status: "COPILOT_LICENSE", licensed: true,
                                                 reason: nil, error: nil)))
        let gated = CopilotDemo.seed(.unlicensed)
        store.adoptDemo(messages: gated.messages, state: gated.chat,
                        license: gated.license, progress: gated.progress)
        store.refreshLicense()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.state, .disabled(CopilotDemo.unlicensedReason))
        XCTAssertEqual(store.license, .unlicensed(reason: CopilotDemo.unlicensedReason))
        // A user gesture unpins: the next refresh lands.
        store.newChat()
        store.refreshLicense()
        await Self.settle { store.inputEnabled }
        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(store.license, .licensed(status: "COPILOT_LICENSE", note: nil))
    }

    // MARK: - store

    func testUnlicensedDisablesInputWithReason() async {
        let store = CopilotStore(transport: StubCopilotTransport(
            licensePayload: CopilotLicensePayload(status: "UNLICENSED", licensed: false,
                                           reason: "no seat", error: nil)))
        store.refreshLicense()
        await Self.settle { store.license != .unknown && store.license != .checking }
        XCTAssertEqual(store.license, .unlicensed(reason: "no seat"))
        XCTAssertEqual(store.state, .disabled("no seat"))
        XCTAssertFalse(store.inputEnabled)
        store.send("hello")
        XCTAssertTrue(store.messages.isEmpty, "disabled input sends nothing")
    }

    func testLicensedSendStreamsToReady() async {
        let store = CopilotStore(transport: StubCopilotTransport(
            licensePayload: CopilotLicensePayload(status: "COPILOT_LICENSE", licensed: true,
                                           reason: nil, error: nil),
            polls: [
                CopilotPollPayload(turnID: "t", text: "Hel", done: false, progress: nil,
                                   answer: nil, error: nil),
                CopilotPollPayload(turnID: "t", text: "Hello", done: true, progress: nil,
                                   answer: CopilotAnswerPayload(
                                       text: "Hello",
                                       attributions: [CopilotAttributionPayload(title: "Doc", url: "https://example.invalid/d")],
                                       suggestions: ["More?"], conversationID: "c1", chatName: nil),
                                   error: nil),
            ]))
        store.refreshLicense()
        await Self.settle { store.inputEnabled }
        store.send("hello")
        XCTAssertEqual(store.state, .streaming)
        await Self.settle { store.state == .ready }
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages[0].text, "hello")
        XCTAssertEqual(store.messages[1].text, "Hello")
        XCTAssertFalse(store.messages[1].isStreaming)
        XCTAssertEqual(store.messages[1].suggestions, ["More?"])
        XCTAssertEqual(store.messages[1].attributions.count, 1)
    }

    func testFailedTurnKeepsUserPromptAndErrors() async {
        let store = CopilotStore(transport: StubCopilotTransport(
            licensePayload: CopilotLicensePayload(status: "COPILOT_LICENSE", licensed: true,
                                           reason: nil, error: nil),
            polls: [CopilotPollPayload(turnID: "t", text: "", done: true, progress: nil,
                                       answer: nil, error: "OutOfCredits")]))
        store.refreshLicense()
        await Self.settle { store.inputEnabled }
        store.send("hello")
        await Self.settle { store.state != .streaming }
        if case .error(let m) = store.state {
            XCTAssertTrue(m.contains("OutOfCredits"))
        } else {
            XCTFail("expected error, got \(store.state)")
        }
        XCTAssertEqual(store.messages.count, 1, "empty bubble dropped, prompt kept")
        XCTAssertTrue(store.inputEnabled, "error keeps the input live")
    }

    func testNewChatClears() async {
        let store = CopilotStore(transport: StubCopilotTransport(
            licensePayload: CopilotLicensePayload(status: "COPILOT_LICENSE", licensed: true,
                                           reason: nil, error: nil)))
        store.refreshLicense()
        await Self.settle { store.inputEnabled }
        store.send("hello")
        await Self.settle { store.state == .ready }
        XCTAssertFalse(store.messages.isEmpty)
        store.newChat()
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.state, .idle)
    }

    /// Spin until `ready` (3 s cap): the store polls on a timer.
    private static func settle(_ ready: @MainActor @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while await MainActor.run(resultType: Bool.self, body: ready) == false,
              Date() < deadline
        {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - stubs

struct StubCopilotTransport: CopilotTransport {
    var licensePayload: CopilotLicensePayload
    var polls: [CopilotPollPayload] = []
    private let served = Locked(0)

    func license() throws -> CopilotLicensePayload { licensePayload }

    func start(prompt: String, conversationID: String?) throws -> String { "t" }

    func poll(turnID: String) throws -> CopilotPollPayload {
        let i = served.next()
        if i < polls.count { return polls[i] }
        return CopilotPollPayload(turnID: turnID, text: "", done: true, progress: nil,
                                  answer: CopilotAnswerPayload(text: "", attributions: nil,
                                                               suggestions: nil, conversationID: nil,
                                                               chatName: nil),
                                  error: nil)
    }

    func stop(turnID: String) throws {}
}

/// Tiny locked counter (polls arrive off-main).
final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) { self.value = value }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let out = value
        value += 1
        return out
    }
}
