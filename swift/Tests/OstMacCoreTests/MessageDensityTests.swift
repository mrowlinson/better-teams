// MessageDensityTests.swift — f2-density: message-density options.
//
// Density is spacing only: Comfortable resolves to today's exact
// constants (pinned against BTSpace/BTSize so any drift fails),
// Compact tightens gaps/padding/avatar. Persistence is one raw-string
// key in a suite-injectable store (GhostStore precedent).
import XCTest

@testable import OstMacCore

@MainActor
final class MessageDensityTests: XCTestCase {
    private func densityDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-density-\(UUID().uuidString)") ?? .standard
    }

    // MARK: - default + raw mapping (accept 1)

    func testFreshInstallDefaultsToComfortable() {
        let store = DensityStore(defaults: densityDefaults())
        XCTAssertEqual(store.mode, .comfortable)
    }

    func testUnknownRawFallsBackToComfortable() {
        let defaults = densityDefaults()
        defaults.set("triple-decker", forKey: DensityStore.modeKey)
        XCTAssertEqual(DensityStore(defaults: defaults).mode, .comfortable)
    }

    func testAllCasesAreComfortableAndCompact() {
        XCTAssertEqual(MessageDensity.allCases, [.comfortable, .compact])
        XCTAssertEqual(MessageDensity.comfortable.displayName, "Comfortable")
        XCTAssertEqual(MessageDensity.compact.displayName, "Compact")
    }

    // MARK: - persistence (accept 4)

    func testModePersistsRawString() {
        let defaults = densityDefaults()
        let store = DensityStore(defaults: defaults)
        store.mode = .compact
        XCTAssertEqual(defaults.string(forKey: DensityStore.modeKey), "compact")
        store.mode = .comfortable
        XCTAssertEqual(defaults.string(forKey: DensityStore.modeKey), "comfortable")
    }

    func testRebuildOnSameSuiteRestoresMode() {
        let defaults = densityDefaults()
        DensityStore(defaults: defaults).mode = .compact
        XCTAssertEqual(DensityStore(defaults: defaults).mode, .compact)
    }

    func testSuitesAreIsolatedFromEachOther() {
        let a = densityDefaults()
        let b = densityDefaults()
        DensityStore(defaults: a).mode = .compact
        XCTAssertEqual(DensityStore(defaults: b).mode, .comfortable)
    }

    func testWritesNeverTouchStandardDefaults() {
        let before = UserDefaults.standard.object(
            forKey: DensityStore.modeKey) as? String
        let store = DensityStore(defaults: densityDefaults())
        store.mode = .compact
        store.mode = .comfortable
        let after = UserDefaults.standard.object(
            forKey: DensityStore.modeKey) as? String
        XCTAssertEqual(after, before)
    }

    // MARK: - spacing map (accepts 2, 3)

}
