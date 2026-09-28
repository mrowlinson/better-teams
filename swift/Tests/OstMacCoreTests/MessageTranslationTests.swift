// MessageTranslationTests.swift — e1-translation lane: inline on-device
// translation policy (eligibility, same-language no-op, cache), the
// stubbed provider seam (offline green), the macOS-14 availability gate
// (both branches forced), toggle state, and AppKit/keyboard menu parity.
import XCTest

@testable import OstMacCore

@MainActor
final class MessageTranslationTests: XCTestCase {
    private func msg(
        id: String = "m1", sender: String = "Tom Becker",
        timestamp: String = "2026-09-22T09:04:47Z",
        content: String = "Pushed new mocks last night.",
        raw: String? = nil
    ) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: timestamp, content: content, raw: raw)
    }

    override func setUp() {
        super.setUp()
        MessageTranslation.availabilityOverride = true
    }

    override func tearDown() {
        MessageTranslation.availabilityOverride = nil
        super.tearDown()
    }

    // MARK: - Eligibility (accept 1)

    func testTextBubbleIsEligible() {
        XCTAssertTrue(MessageTranslation.isEligible(msg()))
    }

    func testEmptyTextBubbleIsIneligible() {
        XCTAssertFalse(MessageTranslation.isEligible(msg(content: "")))
    }

    func testWhitespaceOnlyBubbleIsIneligible() {
        XCTAssertFalse(MessageTranslation.isEligible(msg(content: "   \n  ")))
    }

    func testImageOnlyBubbleIsIneligible() {
        // Image-only payload: no bubble text, no card lines, no rows.
        let raw = """
            <div><img src="https://example.com/p.png" alt="Plot"/></div>
            """
        let m = msg(content: "", raw: raw)
        XCTAssertEqual(MessageActions.copyText(for: m), "")
        XCTAssertFalse(MessageTranslation.isEligible(m))
    }

    func testEligibilityReadsCopyText() {
        // Card copy lines count as text (same source as Copy).
        XCTAssertEqual(
            MessageTranslation.inputText(for: msg()),
            MessageActions.copyText(for: msg()))
        XCTAssertFalse(MessageTranslation.inputText(for: msg(content: "")).isEmpty == false)
    }

    // MARK: - Menu parity (accept 1: BOTH menus, same title)

    func testTranslateTitleConstantShared() {
        XCTAssertEqual(MessageTranslation.menuTitle, "Translate")
    }

    // MARK: - Same-language no-op (accept 4)

    func testSameLanguageIsNoOp() async {
        let stub = StubMessageTranslator()
        let store = TranslationStore(provider: stub, defaults: .emptyTranslationDefaults())
        store.targetLanguageCode = "en"
        await store.translate(msg(content: "Hello team, standup at nine."))
        let entry = store.entry(for: "m1")
        XCTAssertEqual(entry?.state, .sameLanguage)
        XCTAssertEqual(stub.calls, 0)
        XCTAssertNotNil(entry?.text)
    }

    func testSameLanguageMatchesRegionVariants() {
        XCTAssertTrue(MessageTranslation.sameLanguage("en-US", "en"))
        XCTAssertTrue(MessageTranslation.sameLanguage("en", "en-GB"))
        XCTAssertFalse(MessageTranslation.sameLanguage("en", "es"))
        XCTAssertFalse(MessageTranslation.sameLanguage("", "en"))
    }

    // MARK: - Default target (accept 4)

    func testDefaultTargetIsSystemLanguage() {
        let sys = Locale.preferredLanguages.first
            .flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
            ?? "en"
        XCTAssertEqual(MessageTranslation.defaultTargetCode(), sys)
    }

    func testFreshStoreTargetsSystemLanguage() {
        let store = TranslationStore(provider: StubMessageTranslator(), defaults: .emptyTranslationDefaults())
        XCTAssertEqual(store.targetLanguageCode, MessageTranslation.defaultTargetCode())
    }

    // MARK: - Cache (accept 6)

    func testCacheHitReusesWithoutRecompute() async {
        let stub = StubMessageTranslator(mapping: ["Hola equipo": "Hello team"])
        let store = TranslationStore(provider: stub, defaults: .emptyTranslationDefaults())
        store.targetLanguageCode = "en"
        let m = msg(content: "Hola equipo")
        await store.translate(m)
        await store.translate(m)
        XCTAssertEqual(stub.calls, 1)
        XCTAssertEqual(store.entry(for: "m1")?.text, "Hello team")
        XCTAssertEqual(store.entry(for: "m1")?.state, .translated)
    }

    func testCacheKeyIncludesTargetLanguage() async {
        let stub = StubMessageTranslator(mapping: ["Hola equipo": "Hello team"])
        let store = TranslationStore(provider: stub, defaults: .emptyTranslationDefaults())
        let m = msg(content: "Hola equipo")
        store.targetLanguageCode = "en"
        await store.translate(m)
        store.targetLanguageCode = "fr"
        await store.translate(m)
        XCTAssertEqual(stub.calls, 2)
    }

    func testEditedTextRetranslates() async {
        let stub = StubMessageTranslator(mapping: ["Hola": "Hello", "Hola equipo": "Hello team"])
        let store = TranslationStore(provider: stub, defaults: .emptyTranslationDefaults())
        store.targetLanguageCode = "en"
        await store.translate(msg(content: "Hola"))
        await store.translate(msg(content: "Hola equipo"))
        XCTAssertEqual(stub.calls, 2)
        XCTAssertEqual(store.entry(for: "m1")?.text, "Hello team")
    }

    // MARK: - Toggle (accept 2)

    func testToggleHidesAndRestoresWithoutRecompute() async {
        let stub = StubMessageTranslator(mapping: ["Hola equipo": "Hello team"])
        let store = TranslationStore(provider: stub, defaults: .emptyTranslationDefaults())
        store.targetLanguageCode = "en"
        let m = msg(content: "Hola equipo")
        await store.toggle(m)
        XCTAssertEqual(store.entry(for: "m1")?.isVisible, true)
        await store.toggle(m)
        XCTAssertEqual(store.entry(for: "m1")?.isVisible, false)
        await store.toggle(m)
        XCTAssertEqual(store.entry(for: "m1")?.isVisible, true)
        XCTAssertEqual(stub.calls, 1)
    }

    func testFailedEntryRetriesOnToggle() async {
        let stub = StubMessageTranslator(mapping: ["Hola equipo": "Hello team"], failures: 1)
        let store = TranslationStore(provider: stub, defaults: .emptyTranslationDefaults())
        store.targetLanguageCode = "en"
        let m = msg(content: "Hola equipo")
        await store.toggle(m)
        XCTAssertEqual(store.entry(for: "m1")?.state, .failed)
        await store.toggle(m)
        XCTAssertEqual(store.entry(for: "m1")?.state, .translated)
        XCTAssertEqual(stub.calls, 2)
    }

    /// P0: the live (Apple) path with no session ever attached fails
    /// immediately with a named reason — never the 30 s session wait.
    func testUnattachedLiveSessionFailsFast() async {
        let store = TranslationStore(defaults: .emptyTranslationDefaults())
        store.targetLanguageCode = "en"
        XCTAssertFalse(store.isSessionAttached)
        let start = Date()
        await store.translate(
            msg(content: "Hola equipo, nos vemos mañana en la reunión"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(store.entry(for: "m1")?.state, .failed)
        XCTAssertEqual(store.lastFailure, .sessionNotAttached)
    }

    // MARK: - Availability gate (accept 5)

    func testUnavailableHidesTranslate() {
        MessageTranslation.availabilityOverride = false
        XCTAssertFalse(MessageTranslation.isAvailable)
        XCTAssertFalse(MessageTranslation.isEligible(msg()))
        XCTAssertEqual(
            MessageTranslation.unavailableReason,
            "Translation needs macOS 15 or later.")
    }

    func testAvailableShowsTranslate() {
        MessageTranslation.availabilityOverride = true
        XCTAssertTrue(MessageTranslation.isAvailable)
        XCTAssertTrue(MessageTranslation.isEligible(msg()))
    }

    func testStoreTranslateWhileUnavailableFailsQuietly() async {
        MessageTranslation.availabilityOverride = false
        let store = TranslationStore(provider: StubMessageTranslator(), defaults: .emptyTranslationDefaults())
        await store.translate(msg())
        XCTAssertEqual(store.entry(for: "m1")?.state, .failed)
    }

    // MARK: - On-device pin (accept 3)

    func testTranslationPathHasNoNetworkHosts() throws {
        // The translation path is on-device only: no URL hosts, no
        // URLSession, no http in the two translation sources.
        let here = URL(fileURLWithPath: #filePath)
        let sources = here
            .deletingLastPathComponent() // file
            .deletingLastPathComponent() // OstMacCoreTests dir
            .deletingLastPathComponent() // Tests dir → swift dir
            .appendingPathComponent("Sources/OstMacCore")
        for name in ["MessageTranslation.swift", "TranslationStore.swift"] {
            let body = try String(
                contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for needle in ["https://", "http://", "URLSession", "URLRequest", ".resume()"] {
                XCTAssertFalse(
                    body.contains(needle),
                    "\(name) must stay offline (found \(needle))")
            }
        }
    }

    func testStubRunsOffline() async {
        // Stubbed provider: full flow with no models, no network.
        let stub = StubMessageTranslator(mapping: ["Bonjour": "Hello"])
        let store = TranslationStore(provider: stub, defaults: .emptyTranslationDefaults())
        store.targetLanguageCode = "en"
        await store.translate(msg(content: "Bonjour"))
        XCTAssertEqual(store.entry(for: "m1")?.text, "Hello")
    }
}

private extension UserDefaults {
    /// Isolated defaults so tests never touch the suite's real target.
    static func emptyTranslationDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "MessageTranslationTests")!
        d.removeObject(forKey: MessageTranslation.targetDefaultsKey)
        return d
    }
}
