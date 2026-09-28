// ThreadSummaryTests.swift — d1-summaries lane: on-device provider
// (Apple Foundation Models), availability gate, per-thread cache,
// privacy-note variant. Failing-first: written before the provider.
import XCTest

@testable import OstMacCore

@MainActor
final class ThreadSummaryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test-threadsummary-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func thread(_ n: Int, sender: String = "Megan") -> [ChatMessage] {
        (1 ... n).map {
            ChatMessage(
                id: "m\($0)", sender: $0 % 2 == 0 ? "Tom" : sender,
                timestamp: "2026-09-24T09:0\($0 % 10):00Z",
                content: "message number \($0)")
        }
    }

    private func store(
        http: CatchUpCannedTransport? = nil,
        cli: CatchUpCannedTransport? = nil,
        onDevice: OnDeviceMockRunner? = nil,
        availability: OnDeviceAvailability = .available,
        keys: CatchUpMemoryKeyStore? = nil
    ) -> (CatchUpStore, CatchUpCannedTransport, CatchUpCannedTransport, OnDeviceMockRunner) {
        let h = http ?? CatchUpCannedTransport(stub: "HTTP SHOULD NOT APPEAR")
        let c = cli ?? CatchUpCannedTransport(stub: "CLI SHOULD NOT APPEAR")
        let r = onDevice ?? OnDeviceMockRunner(stub: "TL;DR: on-device works.")
        let k = keys ?? CatchUpMemoryKeyStore()
        let od = OnDeviceCatchUpTransport(runner: r, availability: { availability })
        return (CatchUpStore(
            transport: h, cliTransport: c, onDeviceTransport: od,
            defaults: defaults, keyStore: k), h, c, r)
    }

    // MARK: - Picker + no-credential routing

    func testOnDeviceListedAlongsideCloudProviders() {
        XCTAssertTrue(CatchUpProvider.allCases.contains(.onDevice))
        XCTAssertEqual(CatchUpProvider.onDevice.title, "On-device (Apple Intelligence)")
        XCTAssertEqual(CatchUpProvider.allCases.count, 3)
    }

    func testOnDeviceNeedsNoKeyURLOrCLI() async {
        let (store, http, cli, runner) = store()
        XCTAssertFalse(CatchUp.usesBaseURL(provider: .onDevice, apiKey: ""))
        XCTAssertFalse(CatchUp.usesAPIKey(provider: .onDevice))
        XCTAssertFalse(CatchUp.usesModel(provider: .onDevice))
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
        XCTAssertEqual(store.config.apiKey, "")
        await store.summarize(messages: thread(25), chatID: "chat-a")
        XCTAssertTrue(http.prompts.isEmpty, "on-device must never touch HTTP")
        XCTAssertTrue(cli.prompts.isEmpty, "on-device must never touch CLI")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(store.state, .loaded("TL;DR: on-device works."))
    }

    func testEnabledOffDefaultPreserved() async {
        let (store, http, cli, runner) = store()
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: false))
        await store.summarize(messages: thread(25), chatID: "chat-a")
        XCTAssertTrue(http.prompts.isEmpty)
        XCTAssertTrue(cli.prompts.isEmpty)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.off.message))
    }

    func testOnDeviceNeverTouchesKeychain() async {
        let http = CatchUpCannedTransport(stub: "HTTP SHOULD NOT APPEAR")
        let cli = CatchUpCannedTransport(stub: "CLI SHOULD NOT APPEAR")
        let runner = OnDeviceMockRunner(stub: "TL;DR: ok.")
        let keys = CountingKeyStore2(key: "zk")
        let od = OnDeviceCatchUpTransport(runner: runner, availability: { .available })
        let store = CatchUpStore(
            transport: http, cliTransport: cli, onDeviceTransport: od,
            defaults: defaults, keyStore: keys)
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25), chatID: "chat-a")
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(keys.saves, 0)
        XCTAssertEqual(store.state, .loaded("TL;DR: ok."))
    }

    // MARK: - Availability gate (pure mapping + no-fallback routing)

    func testAvailabilityErrorMapping() {
        XCTAssertNil(OnDeviceSummary.error(for: .available))
        XCTAssertEqual(OnDeviceSummary.error(for: .unsupportedOS), .onDeviceUnsupported)
        XCTAssertEqual(OnDeviceSummary.error(for: .unsupportedDevice), .onDeviceUnsupported)
        XCTAssertEqual(
            OnDeviceSummary.error(for: .disabled), .onDeviceUnavailable(OnDeviceSummary.disabledGuidance))
        XCTAssertEqual(
            OnDeviceSummary.error(for: .downloading), .onDeviceUnavailable(OnDeviceSummary.downloadingGuidance))
        // Guidance copy names the fix, never a cloud fallback.
        for status: OnDeviceAvailability in [.unsupportedOS, .unsupportedDevice, .disabled, .downloading] {
            let msg = OnDeviceSummary.error(for: status)!.message
            XCTAssertFalse(msg.isEmpty)
            XCTAssertFalse(msg.lowercased().contains("http"))
            XCTAssertFalse(msg.lowercased().contains("api key"))
        }
    }

    func testOnDeviceUnavailableFailsWithGuidanceNotFallback() async {
        for status: OnDeviceAvailability in [.unsupportedOS, .unsupportedDevice, .disabled, .downloading] {
            let (store, http, cli, runner) = store(availability: status)
            store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
            await store.summarize(messages: thread(25), chatID: "chat-a")
            XCTAssertTrue(http.prompts.isEmpty, "\(status): no HTTP fallback")
            XCTAssertTrue(cli.prompts.isEmpty, "\(status): no CLI fallback")
            XCTAssertTrue(runner.calls.isEmpty, "\(status): no model session")
            let expected = OnDeviceSummary.error(for: status)!
            XCTAssertEqual(store.lastError, expected, "\(status)")
            XCTAssertEqual(store.state, .failed(expected.message), "\(status)")
        }
    }

    func testOnDeviceRunnerErrorSurfacesFailed() async {
        struct Boom: Error {}
        let runner = OnDeviceMockRunner(stub: "", failure: Boom())
        let (store, http, cli, _) = store(onDevice: runner)
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
        await store.summarize(messages: thread(25), chatID: "chat-a")
        XCTAssertTrue(http.prompts.isEmpty)
        XCTAssertTrue(cli.prompts.isEmpty)
        if case .failed = store.state {} else {
            XCTFail("expected .failed, got \(store.state)")
        }
    }

    // MARK: - Cache

    func testCacheHitSkipsNewSession() async {
        let (store, _, _, runner) = store()
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
        let msgs = thread(25)
        await store.summarize(messages: msgs, chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 1)
        await store.summarize(messages: msgs, chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 1, "re-tap on unchanged thread must use cache")
        XCTAssertEqual(store.state, .loaded("TL;DR: on-device works."))
    }

    func testCacheMissOnNewMessage() async {
        let (store, _, _, runner) = store()
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
        await store.summarize(messages: thread(25), chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 1)
        await store.summarize(messages: thread(26), chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 2, "new message invalidates")
    }

    func testCacheMissOnEdit() async {
        let (store, _, _, runner) = store()
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
        await store.summarize(messages: thread(25), chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 1)
        var edited = thread(25)
        edited[3] = ChatMessage(
            id: edited[3].id, sender: edited[3].sender,
            timestamp: edited[3].timestamp, content: "EDITED CONTENT")
        await store.summarize(messages: edited, chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 2, "edit invalidates")
    }

    func testCacheMissOnChatSwitch() async {
        let (store, _, _, runner) = store()
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
        await store.summarize(messages: thread(25), chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 1)
        await store.summarize(messages: thread(25), chatID: "chat-b")
        XCTAssertEqual(runner.calls.count, 2, "chat switch resets")
    }

    func testCacheLRUCap() {
        var cache = ThreadSummaryCache()
        let msgs = thread(25)
        for i in 0 ..< (ThreadSummaryCache.capacity + 5) {
            cache.store(chatID: "chat-\(i)", messages: msgs, text: "summary-\(i)")
        }
        XCTAssertNil(cache.lookup(chatID: "chat-0", messages: msgs), "oldest evicted past cap")
        XCTAssertEqual(cache.lookup(chatID: "chat-\(ThreadSummaryCache.capacity + 4)", messages: msgs), "summary-\(ThreadSummaryCache.capacity + 4)")
    }

    func testCacheReset() {
        var cache = ThreadSummaryCache()
        let msgs = thread(25)
        cache.store(chatID: "chat-a", messages: msgs, text: "s")
        cache.reset()
        XCTAssertNil(cache.lookup(chatID: "chat-a", messages: msgs))
    }

    func testCloudProvidersBypassCache() async {
        // Out-of-scope guard: cloud routing is untouched by the cache.
        let (store, http, _, _) = store()
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        let msgs = thread(25)
        await store.summarize(messages: msgs, chatID: "chat-a")
        await store.summarize(messages: msgs, chatID: "chat-a")
        XCTAssertEqual(http.prompts.count, 2, "cloud path must not cache")
    }

    // MARK: - Transcript reuse + privacy copy

    func testTranscriptReuseUnchanged() async {
        let (store, _, _, runner) = store()
        store.adopt(CatchUpConfig(provider: .onDevice, enabled: true))
        let msgs = [
            ChatMessage(id: "m1", sender: "Megan", timestamp: "t", content: "ship the picker"),
            ChatMessage(id: "m2", sender: "Tom", timestamp: "t", content: "on it\nsecond line"),
        ]
        await store.summarize(messages: msgs, chatID: "chat-a")
        XCTAssertEqual(runner.calls.count, 1)
        let prompt = runner.calls[0]
        XCTAssertEqual(prompt, CatchUp.prompt(transcript: CatchUp.transcript(from: msgs)))
        XCTAssertTrue(prompt.contains("Megan: ship the picker"))
        XCTAssertTrue(prompt.contains("Tom: on it second line"))
    }

    func testPrivacyNoteVariant() {
        let onDevice = CatchUp.privacyNote(for: .onDevice)
        XCTAssertTrue(onDevice.contains("never leaves this device"))
        for provider: CatchUpProvider in [.openAICompatible, .openCodeCLI] {
            XCTAssertEqual(CatchUp.privacyNote(for: provider), CatchUp.privacyNote)
        }
    }
}

/// Touch-counting key store (local copy — CatchUpTests' is private).
private final class CountingKeyStore2: CatchUpKeyStore, @unchecked Sendable {
    var key: String?
    var loads = 0
    var saves = 0

    init(key: String? = nil) { self.key = key }

    func load() -> String? { loads += 1; return key }
    func save(_ key: String) { saves += 1; self.key = key.isEmpty ? nil : key }
    func clear() { key = nil }
}
