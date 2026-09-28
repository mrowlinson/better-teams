// CatchUpCLITests.swift — om-catchup-cli lane: opencode-CLI provider
// path. Mock CLI runner seam (never spawns); one test per mode:
// success/parse, CLI missing, auth expiry, timeout, bad output,
// plus provider select (CLI default, CLI-only even with a key set).
import XCTest

@testable import OstMacCore

@MainActor
final class CatchUpCLITests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "test-catchup-cli-\(UUID().uuidString)"
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

    private func cliStore(
        direct: CatchUpCannedTransport,
        runner: CatchUpMockCLIRunner
    ) -> CatchUpStore {
        CatchUpStore(
            transport: direct,
            cliTransport: OpenCodeCLICatchUpTransport(runner: runner),
            defaults: defaults,
            keyStore: CatchUpMemoryKeyStore())
    }

    func testCLIArgumentsShape() {
        let args = CatchUpCLI.arguments(model: "m1", prompt: "hello")
        XCTAssertEqual(args, ["run", "--format", "json", "--model", "m1", "hello"])
    }

    func testParseOutputFindsLastAssistantMessage() throws {
        let stdout = """
        {"type":"message","role":"user","content":"ignore me"}
        {"type":"message","role":"assistant","content":"TL;DR: cli works."}
        """
        XCTAssertEqual(try CatchUpCLI.parseOutput(stdout), "TL;DR: cli works.")
    }

    func testParseOutputRejectsNonJSON() {
        XCTAssertThrowsError(try CatchUpCLI.parseOutput("THIS IS NOT JSON {{{")) { error in
            XCTAssertEqual(error as? CatchUpError, .cliBadOutput)
        }
    }

    func testNoKeyRoutesToCLIDefault() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"type":"message","role":"assistant","content":"TL;DR: cli works."}"#,
            stderr: "", exitCode: 0))
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls[0].model, "opencode/muse-spark-1.3-contributor-free")
        XCTAssertTrue(runner.calls[0].prompt.contains("TL;DR"))
        XCTAssertEqual(store.state, .loaded("TL;DR: cli works."))
    }

    func testKeyConfiguredStillUsesCLIOnly() async {
        // om-catchup-fallback: CLI-selected => CLI ONLY. A configured
        // key no longer reroutes to HTTPS; it is only used when a
        // direct provider is selected.
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"content":"TL;DR: cli works."}"#, stderr: "", exitCode: 0))
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: "k"))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(store.state, .loaded("TL;DR: cli works."))
    }

    func testCLIMissingSurfacesFailed() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(failure: CatchUpError.cliMissing)
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.cliMissing.message))
    }

    func testCLIAuthExpirySurfacesFailed() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: "", stderr: "error: not authenticated, run `opencode auth login`", exitCode: 1))
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.cliAuthExpired.message))
    }

    func testCLITimeoutSurfacesFailed() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(failure: CatchUpError.cliTimeout)
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.cliTimeout.message))
    }

    func testCLIBadOutputSurfacesFailed() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: "THIS IS NOT JSON {{{", stderr: "", exitCode: 0))
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty)
        XCTAssertEqual(store.state, .failed(CatchUpError.cliBadOutput.message))
    }

    // MARK: - om-catchup-clifix: qualified CLI model id

    func testCLIDefaultModelIsQualified() {
        // `opencode run` rejects the bare id (exit 1 +
        // {"type":"error",...}); only provider/model succeeds.
        XCTAssertEqual(
            CatchUpProvider.openCodeCLI.defaultModel,
            "opencode/muse-spark-1.3-contributor-free")
        XCTAssertEqual(
            CatchUpConfig().model, "opencode/muse-spark-1.3-contributor-free")
    }

    func testSelectProviderCLIPreloadsQualifiedModel() {
        let direct = CatchUpCannedTransport(stub: "ok")
        let runner = CatchUpMockCLIRunner()
        let store = cliStore(direct: direct, runner: runner)
        store.selectProvider(.openCodeCLI)
        XCTAssertEqual(store.config.model, "opencode/muse-spark-1.3-contributor-free")
    }

    // MARK: - om-catchup-clifix: type:text parts + type:error blobs

    func testParseOutputFindsTextPart() throws {
        // Live `opencode run --format json` shape (probed 2026-09-24).
        let stdout = """
        {"type":"step_start","part":{"type":"step-start"}}
        {"type":"text","part":{"type":"text","text":"Hi, great to meet you."}}
        {"type":"step_finish","part":{"type":"step-finish","reason":"stop"}}
        """
        XCTAssertEqual(try CatchUpCLI.parseOutput(stdout), "Hi, great to meet you.")
    }

    func testParseOutputTypeErrorThrowsServerWithMessage() {
        let stdout = """
        {"type":"error","error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details."}}}
        """
        XCTAssertThrowsError(try CatchUpCLI.parseOutput(stdout)) { error in
            guard case let .server(detail) = error as? CatchUpError else {
                return XCTFail("expected .server, got \(error)")
            }
            XCTAssertTrue(detail.contains("Unexpected server error"))
        }
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(
            CatchUpCLI.errorMessage(in: #"{"type":"error","error":{"name":"N","data":{"message":"M"}}}"#),
            "M")
        // Fallbacks: error.message, then error.name.
        XCTAssertEqual(
            CatchUpCLI.errorMessage(in: #"{"type":"error","error":{"message":"M2"}}"#),
            "M2")
        XCTAssertEqual(
            CatchUpCLI.errorMessage(in: #"{"type":"error","error":{"name":"N3"}}"#),
            "N3")
        XCTAssertNil(CatchUpCLI.errorMessage(in: #"{"content":"ok"}"#))
        XCTAssertNil(CatchUpCLI.errorMessage(in: ""))
    }

    func testCLIFailureSurfacesStdoutAndStderr() async {
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"type":"error","error":{"name":"N","data":{"message":"bad model"}}}"#,
            stderr: "warn: something",
            exitCode: 1))
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        XCTAssertTrue(direct.prompts.isEmpty)
        guard case let .failed(detail) = store.state else {
            return XCTFail("expected .failed, got \(store.state)")
        }
        XCTAssertTrue(detail.contains("bad model"), detail)
        XCTAssertTrue(detail.contains("warn: something"), detail)
    }

    func testCLIFailureStdoutOnlyKeepsCLIMessage() async {
        // Bare-model-id shape: exit 1, stderr empty, error blob on
        // stdout. Must not collapse to opaque "exit 1".
        let direct = CatchUpCannedTransport(stub: "SHOULD NOT APPEAR")
        let runner = CatchUpMockCLIRunner(result: CatchUpCLIResult(
            stdout: #"{"type":"error","error":{"name":"UnknownError","data":{"message":"Unexpected server error."}}}"#,
            stderr: "",
            exitCode: 1))
        let store = cliStore(direct: direct, runner: runner)
        store.adopt(CatchUpConfig(provider: .openCodeCLI, enabled: true, apiKey: ""))
        await store.summarize(messages: thread(25))
        guard case let .failed(detail) = store.state else {
            return XCTFail("expected .failed, got \(store.state)")
        }
        XCTAssertTrue(detail.contains("Unexpected server error"), detail)
    }
}
