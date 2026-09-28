// FocusSyncTests.swift — e2-attention lane: Focus reader seam, store,
// fail-open rule, and the quiet-fold contract (Focus-quiet behaves
// EXACTLY like quiet-hours: same reason, same gates, same precedence).
import XCTest

@testable import OstMacCore

/// Lock-guarded bool for the `@Sendable` mock Focus reader.
private final class FocusLiveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var live = false

    func set(_ v: Bool) {
        lock.lock()
        defer { lock.unlock() }
        live = v
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return live
    }
}

@MainActor
final class FocusSyncTests: XCTestCase {
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-focus-sync-\(UUID().uuidString)") ?? .standard
    }

    // MARK: parser (pure, over the real Assertions.json shape)

    /// Real file shape with Focus OFF (captured macOS 27): only
    /// invalidation records, no active key → inactive, no error.
    func testParserInactiveShape() throws {
        let data = """
        {"data":[{"storeInvalidationRequestRecords":[],"storeInvalidationRecords":[]}],"header":{"version":8,"timestamp":811975051.126318}}
        """.data(using: .utf8)!
        XCTAssertFalse(try FocusRead.isActive(assertionsData: data))
    }

    func testParserEmptyActiveListIsInactive() throws {
        let data = """
        {"data":[{"storeActiveAssertionRecords":[]}],"header":{"version":8}}
        """.data(using: .utf8)!
        XCTAssertFalse(try FocusRead.isActive(assertionsData: data))
    }

    func testParserActiveAssertionIsActive() throws {
        let data = """
        {"data":[{"storeActiveAssertionRecords":[{"assertionUUID":"A","assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}]}],"header":{"version":8}}
        """.data(using: .utf8)!
        XCTAssertTrue(try FocusRead.isActive(assertionsData: data))
    }

    func testParserMalformedThrows() throws {
        XCTAssertThrowsError(try FocusRead.isActive(assertionsData: Data("not json".utf8)))
        // Valid JSON with missing keys = inactive (tolerant of OS
        // drift), never an error.
        XCTAssertFalse(try FocusRead.isActive(assertionsData: Data("{}".utf8)))
        XCTAssertFalse(try FocusRead.isActive(assertionsData: Data("[]".utf8)))
    }

    // MARK: store — seam + fail-open

    /// gap-g5: fresh installs (no stored key) default ON.
    func testDefaultsOn() {
        let store = FocusSyncStore(defaults: isolatedDefaults(), reader: { true })
        let (enabled, active) = (store.syncEnabled, store.focusActive)
        XCTAssertTrue(enabled)
        XCTAssertFalse(active)
        let quiet = store.quietNow
        XCTAssertFalse(quiet)
    }

    func testSyncOnPlusFocusIsQuiet() {
        let store = FocusSyncStore(defaults: isolatedDefaults(), reader: { true })
        store.syncEnabled = true
        store.refresh()
        let (active, quiet) = (store.focusActive, store.quietNow)
        XCTAssertTrue(active)
        XCTAssertTrue(quiet)
    }

    func testSyncOffIgnoresFocus() {
        // Sync OFF with Focus active ⇒ identical to today (not quiet).
        let store = FocusSyncStore(defaults: isolatedDefaults(), reader: { true })
        store.syncEnabled = false // gap-g5: fresh default is ON now
        store.refresh()
        let offQuiet = store.quietNow
        XCTAssertFalse(offQuiet)
    }

    func testFocusFlipTakesEffectOnRefresh() {
        let live = FocusLiveBox()
        let store = FocusSyncStore(defaults: isolatedDefaults(), reader: { live.value })
        store.syncEnabled = true
        store.refresh()
        var quiet = store.quietNow
        XCTAssertFalse(quiet)
        live.set(true) // mid-session Focus flip
        store.refresh()
        quiet = store.quietNow
        XCTAssertTrue(quiet)
        live.set(false)
        store.refresh()
        quiet = store.quietNow
        XCTAssertFalse(quiet)
    }

    func testReaderFailureFailsOpen() {
        struct Boom: Error {}
        let store = FocusSyncStore(defaults: isolatedDefaults(), reader: { throw Boom() })
        store.syncEnabled = true
        store.refresh()
        // Unreadable ⇒ NOT quiet (never stuck silent), error recorded.
        let snap = (store.focusActive, store.quietNow, store.error)
        XCTAssertFalse(snap.0)
        XCTAssertFalse(snap.1)
        XCTAssertNotNil(snap.2)
        // Recovery clears the error.
        let ok = FocusSyncStore(defaults: isolatedDefaults(), reader: { false })
        ok.syncEnabled = true
        ok.refresh()
        let okError = ok.error
        XCTAssertNil(okError)
    }

    func testPersistenceRoundTrip() {
        let defaults = isolatedDefaults()
        let first = FocusSyncStore(defaults: defaults, reader: { false })
        first.syncEnabled = true
        let second = FocusSyncStore(defaults: defaults, reader: { false })
        let (enabled2, active2) = (second.syncEnabled, second.focusActive)
        XCTAssertTrue(enabled2)
        // Cached Focus state is session-only (re-polled on tick).
        XCTAssertFalse(active2)
    }

    // MARK: quiet-fold contract (reason reuse, precedence)

    func testFocusQuietReusesQuietReason() {
        // Lane choice: Focus-quiet folds into the existing quiet level
        // with reason "quiet-hours" — ChatFilter untouched (read-only).
        var cfg = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        cfg.applyRules()
        let msg = RealtimeMessage(
            chatID: "19:chat@thread.v2", msgId: "m1", sender: "Ava",
            senderID: "8:orgid:ava", text: "hello", time: "2026-09-25T12:00:00Z",
            isEdit: false, messageType: "Text")
        // App passes quietActive = schedule/DND-quiet OR focus-quiet.
        XCTAssertEqual(
            ChatFilter.decide(message: msg, chatDisplayName: "Team Chat",
                              ownerMRI: "8:orgid:me", rules: cfg, quietActive: true),
            .skip(reason: MentionAlert.quietReason))
        XCTAssertEqual(MentionAlert.quietReason, "quiet-hours")
    }

    func testPresenceDNDBeatsFocusQuiet() {
        var cfg = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        cfg.applyRules()
        let msg = RealtimeMessage(
            chatID: "19:chat@thread.v2", msgId: "m1", sender: "Ava",
            senderID: "8:orgid:ava", text: "hello", time: "2026-09-25T12:00:00Z",
            isEdit: false, messageType: "Text")
        XCTAssertEqual(
            ChatFilter.decide(message: msg, chatDisplayName: "Team Chat",
                              ownerMRI: "8:orgid:me", rules: cfg,
                              dndActive: true, quietActive: true),
            .skip(reason: MentionAlert.dndReason))
    }

    func testMuteYieldsToFocusQuiet() {
        var cfg = RulesConfig(owner: RulesOwner(displayName: "Me", mri: "8:orgid:me"))
        cfg.muted = true
        cfg.applyRules()
        XCTAssertTrue(cfg.effective(forChat: "Team Chat").muted)
        let msg = RealtimeMessage(
            chatID: "19:chat@thread.v2", msgId: "m1", sender: "Ava",
            senderID: "8:orgid:ava", text: "hello", time: "2026-09-25T12:00:00Z",
            isEdit: false, messageType: "Text")
        XCTAssertEqual(
            ChatFilter.decide(message: msg, chatDisplayName: "Team Chat",
                              ownerMRI: "8:orgid:me", rules: cfg, quietActive: true),
            .skip(reason: MentionAlert.quietReason))
    }
}
