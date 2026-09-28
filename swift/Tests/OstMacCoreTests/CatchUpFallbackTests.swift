// CatchUpFallbackTests.swift — om-catchup-fallback lane: provider
// exclusivity (CLI-selected => CLI ONLY, HTTP never attempted),
// missing-CLI detection + install-prompt state, and HTTP 403/other
// failures landing in a clean error state with a Retry path (never
// trapped in .loading). Mock seams only — never spawns, never hits
// the network or the real keychain.
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpFallbackTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test-catchup-fallback-\(UUID().uuidString)"
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
                timestamp: "2026-09-23T09:0\($0 % 10):00Z",
                content: "message number \($0)")
        }
    }

    private func store(
        direct: CatchUpCannedTransport,
        runner: CatchUpMockCLIRunner
    ) -> CatchUpStore {
        CatchUpStore(
            transport: direct,
            cliTransport: OpenCodeCLICatchUpTransport(runner: runner),
            defaults: defaults,
            keyStore: CatchUpMemoryKeyStore())
    }

    // MARK: - Exclusivity

    func testCLISelectedWithKeyNeverAttemptsHTTP() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"content":"TL;DR: cli works."}"#, stderr: "", exitCode: 0))
        let store = store(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty, "CLI-selected must never attempt HTTP")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(store.state, .loaded("TL;DR: cli works."))
        XCTAssertNil(store.lastError)
    }

    func testCLISelectedWithoutKeyNeverAttemptsHTTP() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"content":"TL;DR: cli works."}"#, stderr: "", exitCode: 0))
        let store = store(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty, "CLI-selected must never attempt HTTP")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(store.state, .loaded("TL;DR: cli works."))
    }

    func testDirectProviderNeverTouchesCLI() async {
        let direct = CatchUpCannedTransport(stub: "TL;DR: direct works.")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"content":"SHOULD NOT APPEAR"}"#, stderr: "", exitCode: 0))
        let store = store(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(runner.calls.isEmpty, "direct providers must never shell out")
        XCTAssertEqual(direct.prompts.count, 1)
        XCTAssertEqual(store.state, .loaded("TL;DR: direct works."))
    }

    // MARK: - Missing CLI

    func testMissingCLISurfacesInstallPromptState() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(failure: CatchUpError.cliMissing, isAvailable: false)
        let store = store(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty, "missing CLI must not fall back to HTTP")
        XCTAssertEqual(store.state, .failed(CatchUpError.cliMissing.message))
        // The sheet keys its install prompt off this.
        XCTAssertEqual(store.lastError, .cliMissing)
        XCTAssertFalse(store.cliAvailable)
    }

    func testCLIStatusRefreshPicksUpInstall() {
        let direct = CatchUpCannedTransport(stub: "ok")
        let runner = CatchUpMockCLIRunner(isAvailable: false)
        let store = store(direct: direct, runner: runner)
        XCTAssertFalse(store.cliAvailable)
        runner.isAvailable = true
        store.refreshCLIStatus()
        XCTAssertTrue(store.cliAvailable)
    }

    func testInstallGuideConstants() {
        XCTAssertEqual(CatchUpCLI.installSite, "https://opencode.ai")
        XCTAssertTrue(CatchUpCLI.installCommand.contains("opencode.ai/install"))
        XCTAssertEqual(CatchUpCLI.loginCommand, "opencode auth login")
        XCTAssertTrue(CatchUpError.cliMissing.message.contains("opencode.ai"))
    }

    // MARK: - HTTP failures: clean state, never trapped

    func testHTTPStatusMapping() {
        XCTAssertEqual(CatchUpError.http(403), .forbidden)
        XCTAssertEqual(CatchUpError.http(401), .server("HTTP 401"))
        XCTAssertEqual(CatchUpError.http(500), .server("HTTP 500"))
        XCTAssertTrue(CatchUpError.forbidden.message.contains("403"))
        XCTAssertTrue(CatchUpError.forbidden.message.lowercased().contains("retry"))
    }

    func test403SurfacesCleanStateThenRetryRecovers() async {
        let direct = CatchUpCannedTransport(stub: "", failure: CatchUpError.forbidden)
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"content":"SHOULD NOT APPEAR"}"#, stderr: "", exitCode: 0))
        let store = store(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.forbidden.message))
        XCTAssertEqual(store.lastError, .forbidden)
        // Retry (same tap the sheet's Retry button issues) recovers —
        // the failure never traps the store.
        direct.failure = nil
        direct.stub = "TL;DR: recovered."
        await store.summarize(messages: thread(25))
        XCTAssertEqual(store.state, .loaded("TL;DR: recovered."))
        XCTAssertNil(store.lastError)
    }

    func testGenericServerFailureSurfacesCleanState() async {
        let direct = CatchUpCannedTransport(stub: "", failure: CatchUpError.http(500))
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"content":"SHOULD NOT APPEAR"}"#, stderr: "", exitCode: 0))
        let store = store(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(store.state, .failed(CatchUpError.server("HTTP 500").message))
        XCTAssertEqual(store.lastError, .server("HTTP 500"))
    }

    func testResetClearsLastError() async {
        let direct = CatchUpCannedTransport(stub: "", failure: CatchUpError.forbidden)
        let runner = CatchUpMockCLIRunner()
        let store = store(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openAICompatible, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertEqual(store.lastError, .forbidden)
        store.reset()
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.lastError)
    }
}
