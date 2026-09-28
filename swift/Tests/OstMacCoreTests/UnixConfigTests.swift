// UnixConfigTests.swift — om-meetings-dirname: ~/.config rename + migrator.
// - New dir uses the AppIdentity name; legacy leaf is ostmac.
// - Migrate moves the whole legacy dir (both JSON files ride along).
// - No-ops when legacy is missing or the new dir already exists.
import XCTest

@testable import OstMacCore

final class UnixConfigTests: XCTestCase {
    // MARK: helpers

    func scratchConfigHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("unixcfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testBaseURLUsesAppIdentityName() throws {
        let base = try scratchConfigHome()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(
            UnixConfig.baseURL(under: base).path,
            base.appendingPathComponent("Better Teams").path)
        XCTAssertEqual(
            UnixConfig.legacyBaseURL(under: base).path,
            base.appendingPathComponent("ostmac").path)
    }

    func testMigrateMovesLegacyDirWithBothFiles() throws {
        let base = try scratchConfigHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let legacy = UnixConfig.legacyBaseURL(under: base)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("r".utf8).write(to: legacy.appendingPathComponent("rules.json"))
        try Data("s".utf8).write(to: legacy.appendingPathComponent("scheduled.json"))
        XCTAssertTrue(UnixConfig.migrateLegacyDirectory(under: base))
        let fresh = UnixConfig.baseURL(under: base)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertEqual(
            try Data(contentsOf: fresh.appendingPathComponent("rules.json")), Data("r".utf8))
        XCTAssertEqual(
            try Data(contentsOf: fresh.appendingPathComponent("scheduled.json")), Data("s".utf8))
        XCTAssertFalse(UnixConfig.migrateLegacyDirectory(under: base)) // idempotent
    }

    func testMigrateNoopWhenLegacyMissing() throws {
        let base = try scratchConfigHome()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertFalse(UnixConfig.migrateLegacyDirectory(under: base))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: UnixConfig.baseURL(under: base).path))
    }

    func testMigrateNoopWhenNewDirExists() throws {
        let base = try scratchConfigHome()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let legacy = UnixConfig.legacyBaseURL(under: base)
        let fresh = UnixConfig.baseURL(under: base)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("n".utf8).write(to: fresh.appendingPathComponent("rules.json"))
        try Data("l".utf8).write(to: legacy.appendingPathComponent("rules.json"))
        XCTAssertFalse(UnixConfig.migrateLegacyDirectory(under: base))
        XCTAssertEqual(
            try Data(contentsOf: fresh.appendingPathComponent("rules.json")), Data("n".utf8))
        XCTAssertEqual(
            try Data(contentsOf: legacy.appendingPathComponent("rules.json")), Data("l".utf8))
    }
}
