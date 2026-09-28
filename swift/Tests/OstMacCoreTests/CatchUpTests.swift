// CatchUpTests.swift — om-catchup lane: OFF default, mock transport,
// prompt shape, threshold gate, endpoint join, transcript cap.
// om-catchup-oc: provider picker preload, keychain key store (injected
// memory store — never the real keychain), legacy-key migration.
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        // Isolated persistence per test (never touches the real defaults).
        suite = "test-catchup-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func thread(_ n: Int) -> [ChatMessage] {
        (1 ... n).map {
            ChatMessage(
                id: "m\($0)", sender: "User \($0 % 3)",
                timestamp: "2026-09-22T09:0\($0 % 10):00Z",
                content: "message number \($0)")
        }
    }

    private func store(
        transport: (any CatchUpTransport)? = nil,
        cliTransport: (any CatchUpTransport)? = nil,
        keys: CatchUpMemoryKeyStore? = nil
    ) -> (CatchUpStore, CatchUpMemoryKeyStore) {
        let k = keys ?? CatchUpMemoryKeyStore()
        return (CatchUpStore(transport: transport, cliTransport: cliTransport, defaults: defaults, keyStore: k), k)
    }

    func testDefaultsOff() {
        let (store, _) = store()
        XCTAssertFalse(store.config.enabled)
        XCTAssertEqual(store.config.provider, .openCodeCLI)
        XCTAssertEqual(store.config.baseURL, "https://opencode.ai/zen/v1")
        XCTAssertEqual(store.config.model, "opencode/muse-spark-1.3-contributor-free")
        XCTAssertEqual(store.config.apiKey, "")
        XCTAssertEqual(store.state, .idle)
    }

    func testDisabledNeverCallsTransport() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let (store, _) = store(transport: mock, cliTransport: cliMock)
        store.adopt(CatchUpConfig(enabled: false, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(mock.prompts.isEmpty)
        XCTAssertTrue(cliMock.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.off.message))
    }

    func testMissingKeyFailsWithoutCalling() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let (store, _) = store(transport: mock, cliTransport: cliMock)
        // Direct providers still require a key (CLI provider falls
        // through to the shell-out instead — see CatchUpCLITests).
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "  "))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(mock.prompts.isEmpty)
        XCTAssertTrue(cliMock.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.missingKey.message))
    }

    func testEmptyThreadFailsWithoutCalling() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let (store, _) = store(transport: mock, cliTransport: cliMock)
        store.adopt(CatchUpConfig(enabled: true, apiKey: "k"))
        await store.summarize(messages: [])
        XCTAssertTrue(mock.prompts.isEmpty)
        XCTAssertTrue(cliMock.prompts.isEmpty)
        if case .failed = store.state {} else {
            XCTFail("expected .failed, got \(store.state)")
        }
    }

    func testMockSuccessLoadsText() async {
        let mock = CatchUpCannedTransport(stub: "TL;DR: standup happened.")
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let (store, _) = store(transport: mock, cliTransport: cliMock)
        // Direct provider: HTTPS path (the CLI provider never uses
        // it, even with a key — see CatchUpFallbackTests).
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(mock.prompts.count, 1)
        XCTAssertTrue(cliMock.prompts.isEmpty)
        XCTAssertEqual(store.state, .loaded("TL;DR: standup happened."))
    }

    func testPromptCarriesTranscriptAndSections() async {
        let mock = CatchUpCannedTransport(stub: "ok")
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let (store, _) = store(transport: mock, cliTransport: cliMock)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        let msgs = [
            ChatMessage(id: "m1", sender: "Megan", timestamp: "t", content: "ship the picker"),
            ChatMessage(id: "m2", sender: "Tom", timestamp: "t", content: "on it\nsecond line"),
        ]
        await store.summarize(messages: msgs)
        XCTAssertEqual(mock.prompts.count, 1)
        XCTAssertTrue(cliMock.prompts.isEmpty)
        let prompt = mock.prompts[0]
        XCTAssertTrue(prompt.contains("TL;DR"))
        XCTAssertTrue(prompt.contains("Key points"))
        XCTAssertTrue(prompt.contains("Action items"))
        XCTAssertTrue(prompt.contains("Megan: ship the picker"))
        // Multiline content collapses to one transcript line.
        XCTAssertTrue(prompt.contains("Tom: on it second line"))
    }

    func testTransportErrorSurfacesFailed() async {
        struct Boom: Error {}
        let mock = CatchUpCannedTransport(stub: "", failure: Boom())
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let (store, _) = store(transport: mock, cliTransport: cliMock)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(cliMock.prompts.isEmpty)
        if case .failed = store.state {} else {
            XCTFail("expected .failed, got \(store.state)")
        }
    }

    func testThresholdGate() {
        XCTAssertFalse(CatchUp.shouldOffer(messageCount: CatchUp.threshold - 1))
        XCTAssertTrue(CatchUp.shouldOffer(messageCount: CatchUp.threshold))
        XCTAssertTrue(CatchUp.shouldOffer(messageCount: CatchUp.threshold + 100))
    }

    func testEndpointJoinsBaseURL() {
        XCTAssertEqual(
            CatchUp.endpoint(baseURL: "https://api.openai.com/v1"),
            "https://api.openai.com/v1/chat/completions")
        // Trailing slashes collapse to exactly one join slash.
        XCTAssertEqual(
            CatchUp.endpoint(baseURL: "http://localhost:1234/v1///"),
            "http://localhost:1234/v1/chat/completions")
    }

    func testTranscriptTailCap() {
        var msgs = thread(5)
        msgs.append(ChatMessage(
            id: "big", sender: "Spammer", timestamp: "t",
            content: String(repeating: "x", count: CatchUp.maxTranscriptChars + 500) + "TAILMARK"))
        let text = CatchUp.transcript(from: msgs)
        XCTAssertLessThanOrEqual(text.count, CatchUp.maxTranscriptChars)
        // Tail wins: newest content survives, oldest lines are dropped.
        XCTAssertTrue(text.contains("TAILMARK"))
        XCTAssertFalse(text.contains("message number 1"))
    }

    func testRequestBodyShape() throws {
        let data = CatchUp.requestBody(model: "m1", prompt: "hello")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "m1")
        let msgs = json?["messages"] as? [[String: String]]
        XCTAssertEqual(msgs?.count, 1)
        XCTAssertEqual(msgs?[0]["role"], "user")
        XCTAssertEqual(msgs?[0]["content"], "hello")
    }

    func testChatCompletionsDecode() throws {
        let data = """
        {"choices": [{"message": {"content": "TL;DR: ok"}}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        XCTAssertEqual(decoded.choices.first?.message.content, "TL;DR: ok")
    }

    func testConfigPersistsAcrossStores() {
        let keys = CatchUpMemoryKeyStore()
        let a = CatchUpStore(defaults: defaults, keyStore: keys)
        a.adopt(CatchUpConfig(
            provider: .openAICompatible, enabled: true,
            baseURL: "http://x/v1", model: "mm", apiKey: "kk"))
        let b = CatchUpStore(defaults: defaults, keyStore: keys)
        // Lazy key: non-secret config restores at init, the key only
        // after the first load trigger.
        XCTAssertEqual(b.config.apiKey, "")
        b.ensureKeyLoaded()
        XCTAssertEqual(b.config, CatchUpConfig(
            provider: .openAICompatible, enabled: true,
            baseURL: "http://x/v1", model: "mm", apiKey: "kk"))
    }

    // MARK: - om-catchup-oc: provider picker

    func testCLIPreloadsZenBaseAndQualifiedModel() {
        let (store, _) = store()
        store.adopt(CatchUpConfig(
            enabled: true, baseURL: "http://custom/v1", model: "custom",
            apiKey: "test-key-DO-NOT-USE"))
        store.selectProvider(.openCodeCLI)
        XCTAssertEqual(store.config.provider, .openCodeCLI)
        XCTAssertEqual(store.config.baseURL, "https://opencode.ai/zen/v1")
        XCTAssertEqual(store.config.model, "opencode/muse-spark-1.3-contributor-free")
        // Switch preloads endpoint fields only — key + enabled survive.
        XCTAssertEqual(store.config.apiKey, "test-key-DO-NOT-USE")
        XCTAssertTrue(store.config.enabled)
    }

    func testProviderSwitchBackPreloadsOpenAI() {
        let (store, _) = store()
        store.selectProvider(.openCodeCLI)
        store.selectProvider(.openAICompatible)
        XCTAssertEqual(store.config.provider, .openAICompatible)
        XCTAssertEqual(store.config.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(store.config.model, "gpt-4o-mini")
    }

    func testProviderPersistsAcrossStores() {
        let keys = CatchUpMemoryKeyStore()
        let a = CatchUpStore(defaults: defaults, keyStore: keys)
        a.selectProvider(.openCodeCLI)
        let b = CatchUpStore(defaults: defaults, keyStore: keys)
        XCTAssertEqual(b.config.provider, .openCodeCLI)
        XCTAssertEqual(b.config.baseURL, "https://opencode.ai/zen/v1")
        XCTAssertEqual(b.config.model, "opencode/muse-spark-1.3-contributor-free")
    }

    // MARK: - om-catchup-oc: keychain key store

    func testKeyLoadsFromKeyStore() {
        let keys = CatchUpMemoryKeyStore(key: "zk")
        let store = CatchUpStore(defaults: defaults, keyStore: keys)
        // Lazy: init leaves the key empty; the load trigger fills it.
        XCTAssertEqual(store.config.apiKey, "")
        store.ensureKeyLoaded()
        XCTAssertEqual(store.config.apiKey, "zk")
    }

    func testKeyWritesToKeyStoreNeverDefaults() {
        let (store, keys) = store()
        store.adopt(CatchUpConfig(enabled: true, apiKey: "test-key-DO-NOT-USE"))
        XCTAssertEqual(keys.load(), "test-key-DO-NOT-USE")
        XCTAssertNil(defaults.string(forKey: "catchup.apiKey"))
    }

    func testNoKeyInStoreMeansMissingKey() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let (store, _) = store(transport: mock, cliTransport: cliMock)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(mock.prompts.isEmpty)
        XCTAssertTrue(cliMock.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.missingKey.message))
    }

    func testLegacyDefaultsKeyMigratesToKeyStore() {
        defaults.set("legacy-k", forKey: "catchup.apiKey")
        let keys = CatchUpMemoryKeyStore()
        let store = CatchUpStore(defaults: defaults, keyStore: keys)
        // Lazy: migration waits for the first load trigger.
        XCTAssertEqual(store.config.apiKey, "")
        XCTAssertEqual(defaults.string(forKey: "catchup.apiKey"), "legacy-k")
        store.ensureKeyLoaded()
        XCTAssertEqual(store.config.apiKey, "legacy-k")
        XCTAssertEqual(keys.load(), "legacy-k")
        XCTAssertNil(defaults.string(forKey: "catchup.apiKey"))
    }

    func testKeychainServiceAndAccount() {
        XCTAssertEqual(CatchUpSystemKeychain.service, "dev.ostmac.OstMac.catchup")
        XCTAssertEqual(CatchUpSystemKeychain.account, "catchup-api-key")
    }

    // MARK: - om-keychain-gate: lazy keychain

    func testInitNeverTouchesKeyStore() {
        let keys = CountingKeyStore(key: "zk")
        let store = CatchUpStore(defaults: defaults, keyStore: keys)
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(keys.saves, 0)
        XCTAssertEqual(store.config.apiKey, "")
        // A keyless config change pre-load must not wipe the stored
        // key (empty apiKey = "not loaded", not "no key").
        store.selectProvider(.openAICompatible)
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(keys.saves, 0)
        XCTAssertEqual(keys.key, "zk")
    }

    func testSummarizeWithKeyProviderLoadsLazily() async {
        let mock = CatchUpCannedTransport(stub: "TL;DR: lazy works.")
        let keys = CountingKeyStore(key: "zk")
        let store = CatchUpStore(
            transport: mock, defaults: defaults, keyStore: keys)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: ""))
        XCTAssertEqual(keys.loads, 0)
        await store.summarize(messages: thread(25))
        XCTAssertEqual(keys.loads, 1)
        XCTAssertEqual(store.config.apiKey, "zk")
        XCTAssertEqual(mock.prompts.count, 1)
        XCTAssertEqual(store.state, .loaded("TL;DR: lazy works."))
        // Second run reuses the in-memory key (one read per store).
        await store.summarize(messages: thread(25))
        XCTAssertEqual(keys.loads, 1)
    }

    func testSummarizeWithCLIProviderNeverLoads() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"content":"TL;DR: cli works."}"#, stderr: "", exitCode: 0))
        let keys = CountingKeyStore(key: "zk")
        let store = CatchUpStore(
            transport: direct,
            cliTransport: OpenCodeCLICatchUpTransport(runner: runner),
            defaults: defaults, keyStore: keys)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(keys.saves, 0)
        XCTAssertEqual(store.state, .loaded("TL;DR: cli works."))
    }

    func testDisabledSummarizeNeverLoads() async {
        let mock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let cliMock = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let keys = CountingKeyStore(key: "zk")
        let store = CatchUpStore(
            transport: mock, cliTransport: cliMock,
            defaults: defaults, keyStore: keys)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: false, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(keys.saves, 0)
        XCTAssertEqual(store.state, .failed(CatchUpError.off.message))
    }

    func testExplicitKeyThenClearPropagates() {
        let keys = CountingKeyStore()
        let store = CatchUpStore(defaults: defaults, keyStore: keys)
        // Explicit set persists even pre-load (marks state known).
        store.adopt(CatchUpConfig(enabled: true, apiKey: "k"))
        XCTAssertEqual(keys.saves, 1)
        XCTAssertEqual(keys.key, "k")
        // …so a later clear is a real clear, not a skipped write.
        store.adopt(CatchUpConfig(enabled: true, apiKey: ""))
        XCTAssertEqual(keys.saves, 2)
        XCTAssertNil(keys.key)
    }

    func testLoadedKeyDoesNotWriteBack() {
        let keys = CountingKeyStore(key: "zk")
        let store = CatchUpStore(defaults: defaults, keyStore: keys)
        store.ensureKeyLoaded()
        XCTAssertEqual(store.config.apiKey, "zk")
        XCTAssertEqual(keys.loads, 1)
        XCTAssertEqual(keys.saves, 0)
    }
}

/// Touch-counting key store: proves the lazy contract (zero
/// keychain touches on init; reads only on key-needing runs).
private final class CountingKeyStore: CatchUpKeyStore, @unchecked Sendable {
    var key: String?
    var loads = 0
    var saves = 0

    init(key: String? = nil) { self.key = key }

    func load() -> String? { loads += 1; return key }
    func save(_ key: String) { saves += 1; self.key = key.isEmpty ? nil : key }
    func clear() { key = nil }
}
