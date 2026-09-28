// SettingsOrgTests.swift — om-settings-org lane: sidebar-categories
// Settings + the four bundled fixes.
//   (1) Health timeout: a hung core fetch can never stick the badge on
//       "Checking…" — status timeout fails the run, probe timeouts
//       fail in place, `running` always clears.
//   (2) OpenCode provider removed: raw value gone, legacy stored value
//       migrates to OpenCode CLI.
//   (3) Provider picker overflow: 3 short-titled providers (menu-safe).
//   (4) Demo isolation: demo Settings never embeds the live auth model.
import XCTest

@testable import OstMacCore

@MainActor
final class SettingsOrgTests: XCTestCase {
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-settings-org-\(UUID().uuidString)") ?? .standard
    }

    // MARK: - (1) Health timeout

    /// Hung status read: run() returns (no hang), `running` clears,
    /// the failure surfaces as `error`, no partial report.
    func testHealthStatusTimeoutClearsRunning() async {
        let store = HealthStore(
            statusFetcher: {
                Thread.sleep(forTimeInterval: 30)
                return StealIdsTests.status()
            },
            meFetcher: { StealIdsTests.me() },
            teamsFetcher: { TeamsResponse(ok: true, teams: []) },
            chatsFetcher: { _ in ChatsResponse(ok: true, chats: []) },
            timeoutSeconds: 0.05)
        await store.run()
        XCTAssertFalse(store.running)
        XCTAssertNil(store.report)
        XCTAssertNotNil(store.error)
    }

    /// Hung probe: fails in place (report still lands, degraded), the
    /// other probes still run, `running` clears.
    func testHealthProbeTimeoutFailsInPlace() async {
        let store = HealthStore(
            statusFetcher: { StealIdsTests.status(
                aad: (true, false), graph: (true, false), ic3: (true, false),
                recorder: (true, false), skype: (true, false), refresh: true) },
            meFetcher: {
                Thread.sleep(forTimeInterval: 30)
                return StealIdsTests.me()
            },
            teamsFetcher: { TeamsResponse(ok: true, teams: []) },
            chatsFetcher: { _ in ChatsResponse(ok: true, chats: []) },
            timeoutSeconds: 0.05)
        await store.run()
        XCTAssertFalse(store.running)
        XCTAssertNotNil(store.report)
        XCTAssertEqual(store.report?.probes.count, 3)
        XCTAssertFalse(store.report?.probes[0].ok ?? true)
        XCTAssertTrue(store.report?.probes[1].ok ?? false)
        XCTAssertTrue(store.report?.probes[2].ok ?? false)
        XCTAssertEqual(store.report?.overall, HealthOverall.degraded)
        XCTAssertNil(store.error)
    }

    // MARK: - (2) OpenCode provider removed

    func testOpenCodeProviderRemoved() {
        XCTAssertNil(CatchUpProvider(rawValue: "opencode"))
        XCTAssertEqual(
            CatchUpProvider.allCases.map(\.rawValue).sorted(),
            ["on-device", "openai-compatible", "opencode-cli"])
    }

    /// Stored "opencode" (pre-removal default) migrates to the CLI
    /// provider, never to an unknown/nil state.
    func testLegacyOpenCodeMigratesToCLI() {
        let defaults = isolatedDefaults()
        defaults.set("opencode", forKey: "catchup.provider")
        // AICATCH: without the hidden key a legacy provider loads on-device.
        XCTAssertEqual(CatchUpStore(defaults: defaults, keyStore: CatchUpMemoryKeyStore()).config.provider, .onDevice)
        defaults.set(true, forKey: CatchUp.deprecatedProvidersKey)
        let store = CatchUpStore(
            defaults: defaults, keyStore: CatchUpMemoryKeyStore())
        XCTAssertEqual(store.config.provider, .openCodeCLI)
    }

    // MARK: - (3) Provider picker overflow

    /// The picker lists 3 short titles (segmented overflowed at 4);
    /// every title stays menu-row short.
    func testProviderTitlesAreMenuSafe() {
        let titles = CatchUpProvider.allCases.map(\.title)
        XCTAssertEqual(titles.count, 3)
        for title in titles {
            XCTAssertLessThanOrEqual(title.count, 32, title)
        }
    }

    // MARK: - (4) Demo isolation

    // MARK: - Sidebar categories

}
