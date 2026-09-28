// SettingsTrimTests.swift — om-settings-trim lane: every remaining
// Settings row is wired to real behavior.
//   - Banner toggle persists (UserDefaults) and gates posting.
//   - Catch-up Base URL row hides exactly when the transport ignores it.
import XCTest

@testable import OstMacCore

final class SettingsTrimTests: XCTestCase {
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-settings-trim-\(UUID().uuidString)") ?? .standard
    }

    // MARK: - Banner toggle persistence

    func testBannerDefaultsOn() async {
        // Fake backend: the real center needs an app bundle (xctest has none).
        let notifs = await MessageNotifications(
            backend: FakeNotificationCenter(), defaults: isolatedDefaults())
        let enabled = await MainActor.run { notifs.enabled }
        XCTAssertTrue(enabled)
    }

    func testBannerPersistsAcrossInstances() async {
        let defaults = isolatedDefaults()
        let first = await MessageNotifications(
            backend: FakeNotificationCenter(), defaults: defaults)
        await MainActor.run { first.enabled = false }
        XCTAssertFalse(defaults.bool(forKey: MessageNotifications.enabledKey))
        let second = await MessageNotifications(
            backend: FakeNotificationCenter(), defaults: defaults)
        let enabled = await MainActor.run { second.enabled }
        XCTAssertFalse(enabled)
    }

    func testPersistedOffStillGatesPosting() async {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: MessageNotifications.enabledKey)
        let fake = FakeNotificationCenter()
        let notifs = await MessageNotifications(backend: fake, defaults: defaults)
        await notifs.handle(RealtimeMessage(
            chatID: "19:abc@thread.v2", msgId: "m1", sender: "Megan Harper",
            text: "hello", time: "2026-09-23T10:00:00Z",
            isEdit: false, editedID: nil))
        let posted = await fake.posted
        XCTAssertEqual(posted.count, 0)
    }

    // MARK: - Catch-up Base URL relevance

    /// CLI without a key shells out (baseURL ignored) — the row hides.
    func testBaseURLUnusedForKeylessCLI() {
        XCTAssertFalse(CatchUp.usesBaseURL(provider: .openCodeCLI, apiKey: ""))
        XCTAssertFalse(CatchUp.usesBaseURL(provider: .openCodeCLI, apiKey: "   "))
    }

    /// CLI with a key still shells out (exclusive routing) — the row
    /// stays hidden.
    func testBaseURLUnusedForCLIWithKey() {
        XCTAssertFalse(CatchUp.usesBaseURL(provider: .openCodeCLI, apiKey: "k"))
    }

    /// Direct providers always use the Base URL — the row shows.
    func testBaseURLUsedForDirectProviders() {
        XCTAssertTrue(CatchUp.usesBaseURL(provider: .openAICompatible, apiKey: ""))
        XCTAssertTrue(CatchUp.usesBaseURL(provider: .openAICompatible, apiKey: "k"))
    }
}
