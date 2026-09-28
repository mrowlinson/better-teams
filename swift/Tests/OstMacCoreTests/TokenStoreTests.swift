// TokenStoreTests.swift — R13 token-store lane: store accepts.
//
// Fixture tokens ONLY (FIXTURE- prefix); never the real config dir or the
// real keychain — every test uses MemoryTokenStore and/or a tmp configDir.
import XCTest

@testable import OstMacCore

final class TokenStoreTests: XCTestCase {
    // MARK: - Helpers

    /// Real-now-anchored exps so CoreLocal (real clock) agrees with us.
    private func liveNow() -> UInt64 { TokenStatus.nowSecs() }

    private func tok(_ name: String, exp: UInt64?) -> StoredTokenValue {
        StoredTokenValue(token: "FIXTURE-\(name)", expiresAt: exp)
    }

    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private func write(_ dir: URL, profile: String, toml: String) throws -> URL {
        let url = dir.appendingPathComponent(TomlConfig.fileName(profile: profile))
        try Data(toml.utf8).write(to: url, options: .atomic)
        return url
    }

    /// 4 canonical fixture profiles (accept #2): valid / expired /
    /// no-RT / missing-derived.
    private func fixtures(now: UInt64) -> [String: String] {
        let fresh = now + 3600
        let stale = now >= 100 ? now - 100 : 0
        let gtms = "{\\\"chatService\\\":\\\"https://FIXTURE.chat/\\\"}"
        let valid = """
            refresh_token = "FIXTURE-RT"
            region_gtms = "\(gtms)"
            [access_token]
            token = "FIXTURE-AAD"
            expires_at = \(fresh)
            [skype_token]
            token = "FIXTURE-SKYPE"
            expires_at = \(fresh)
            [graph_token]
            token = "FIXTURE-GRAPH"
            expires_at = \(fresh)
            [ic3_token]
            token = "FIXTURE-IC3"
            expires_at = \(fresh)
            [recorder_token]
            token = "FIXTURE-REC"
            expires_at = \(fresh)

            """
        let expired = """
            refresh_token = "FIXTURE-RT"
            [access_token]
            token = "FIXTURE-AAD"
            expires_at = \(stale)
            [skype_token]
            token = "FIXTURE-SKYPE"
            expires_at = \(fresh)
            [graph_token]
            token = "FIXTURE-GRAPH"
            expires_at = \(stale)

            """
        let noRT = """
            [access_token]
            token = "FIXTURE-AAD"
            expires_at = \(stale)

            """
        let missingDerived = """
            refresh_token = "FIXTURE-RT"
            [access_token]
            token = "FIXTURE-AAD"
            expires_at = \(fresh)
            [graph_token]
            token = "FIXTURE-GRAPH"
            expires_at = \(fresh)

            """
        return [
            "fx-valid": valid, "fx-expired": expired, "fx-nort": noRT,
            "fx-missing": missingDerived,
        ]
    }

    private func summaryLines(_ s: StatusResponse) -> [String] {
        func slot(_ t: TokenSlot) -> String { "\(t.present ? 1 : 0)\(t.expired ? 1 : 0)" }
        return [
            "signed_in=\(s.signed_in ? 1 : 0)",
            "aad=\(slot(s.tokens.aad))",
            "rt=\(s.tokens.refresh_present ? 1 : 0)",
            "graph=\(slot(s.tokens.graph))",
            "ic3=\(slot(s.tokens.ic3))",
            "rec=\(slot(s.tokens.recorder))",
            "skype=\(slot(s.tokens.skype))",
            "gtms=\(s.tokens.region_gtms_present ? 1 : 0)",
        ]
    }

    // MARK: - Skew boundary (accept #3: 299 expired, 301 valid)

    func testSkewBoundary() {
        let now: UInt64 = 1_800_000_000
        XCTAssertTrue(tok("a", exp: now + 299).isExpired(now: now))
        XCTAssertTrue(tok("a", exp: now + 300).isExpired(now: now))
        XCTAssertFalse(tok("a", exp: now + 301).isExpired(now: now))
        XCTAssertFalse(tok("a", exp: nil).isExpired(now: now))
    }

    func testSkewConstantMatchesRust() {
        XCTAssertEqual(TokenSlots.expirySkew, 300)
        XCTAssertEqual(TokenSlots.expirySkew, TomlConfig.expirySkew)
    }

    // MARK: - Slot present/expired matrix + signed_in rule

    func testStatusMatrix() {
        let now: UInt64 = 1_800_000_000
        var slots = TokenSlots()
        slots.accessToken = tok("aad", exp: now + 3600)
        slots.refreshToken = "FIXTURE-RT"
        slots.graphToken = tok("g", exp: now + 10) // within skew → expired
        // ic3/recorder/skype absent; region absent
        let st = TokenStatus.summarize(slots, now: now)
        XCTAssertTrue(st.ok)
        XCTAssertTrue(st.signed_in)
        XCTAssertEqual([st.tokens.aad.present, st.tokens.aad.expired], [true, false])
        XCTAssertTrue(st.tokens.refresh_present)
        XCTAssertEqual([st.tokens.graph.present, st.tokens.graph.expired], [true, true])
        XCTAssertEqual([st.tokens.ic3.present, st.tokens.ic3.expired], [false, false])
        XCTAssertEqual([st.tokens.skype.present, st.tokens.skype.expired], [false, false])
        XCTAssertFalse(st.tokens.region_gtms_present)
    }

    func testSignedInRequiresValidAAD() {
        let now: UInt64 = 1_800_000_000
        var expired = TokenSlots()
        expired.accessToken = tok("aad", exp: now - 1)
        XCTAssertFalse(TokenStatus.summarize(expired, now: now).signed_in)
        XCTAssertFalse(TokenStatus.summarize(TokenSlots(), now: now).signed_in)
    }

    // MARK: - TOML codec

    func testTOMLGoldenRoundTrip() throws {
        // Fixed golden: exact bytes in, equal slots out, exact bytes back.
        let golden = """
            refresh_token = "FIXTURE-RT"
            tenant_id = "FIXTURE-TENANT"
            region_gtms = "{\\"a\\":1}"
            [access_token]
            token = "FIXTURE-AAD"
            expires_at = 1800003600
            [skype_token]
            token = "FIXTURE-SKYPE"
            [graph_token]
            token = "FIXTURE-GRAPH"
            expires_at = 1800003600
            [ic3_token]
            token = "FIXTURE-IC3"
            expires_at = 1800003600
            [recorder_token]
            token = "FIXTURE-REC"
            expires_at = 1800003600

            """
        let slots = try TokenTOML.parse(golden)
        XCTAssertEqual(slots.refreshToken, "FIXTURE-RT")
        XCTAssertEqual(slots.tenantID, "FIXTURE-TENANT")
        XCTAssertEqual(slots.regionGtms, "{\"a\":1}")
        XCTAssertEqual(slots.accessToken?.token, "FIXTURE-AAD")
        XCTAssertEqual(slots.accessToken?.expiresAt, 1_800_003_600)
        XCTAssertEqual(slots.skypeToken?.token, "FIXTURE-SKYPE")
        XCTAssertNil(slots.skypeToken?.expiresAt)
        XCTAssertEqual(TokenTOML.serialize(slots), golden)
        // Strict validator accepts our bytes (Rust-shape parity).
        _ = try TomlConfig.parse(TokenTOML.serialize(slots))
    }

    func testTOMLEscapesRoundTrip() throws {
        var slots = TokenSlots()
        slots.regionGtms = "{\"u\":\"a\\\"b\\\\c\"}"
        slots.refreshToken = "FIXTURE-RT-\n-\t-\"-\\"
        let text = TokenTOML.serialize(slots)
        _ = try TomlConfig.parse(text)
        let back = try TokenTOML.parse(text)
        XCTAssertEqual(back, slots)
    }

    func testTOMLUnknownKeysIgnoredWrongTypesThrow() throws {
        let ok = "unknown_key = [1, 2]\nrefresh_token = \"FIXTURE-RT\"\n"
        XCTAssertEqual(try TokenTOML.parse(ok).refreshToken, "FIXTURE-RT")
        XCTAssertThrowsError(try TokenTOML.parse("refresh_token = 42\n"))
        XCTAssertThrowsError(try TokenTOML.parse("[access_token]\n"))
    }

    func testTOMLClearedSerializesEmpty() {
        XCTAssertEqual(TokenTOML.serialize(TokenSlots.cleared()), "")
    }

    // MARK: - Login survival (accept #2)

    func testExistingLoginsSurvive() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = liveNow()
        for (profile, toml) in fixtures(now: now) {
            _ = try write(dir, profile: profile, toml: toml)
        }
        // Pre-import oracle: direct TOML status (R12 path, no store).
        var pre: [String: [String]] = [:]
        for profile in fixtures(now: now).keys {
            let st = try CoreLocal.status(profile: profile, configDir: dir)
            pre[profile] = summaryLines(st)
        }
        XCTAssertEqual(pre["fx-valid"]?[0], "signed_in=1")
        XCTAssertEqual(pre["fx-expired"]?[0], "signed_in=0")
        XCTAssertEqual(pre["fx-nort"]?[0], "signed_in=0")
        XCTAssertEqual(pre["fx-missing"]?[0], "signed_in=1")

        // Post-import: Swift store agrees on every slot, every profile.
        let store = try PersistentTokenStore(
            blob: MemoryTokenStore(), configDir: dir
        )
        for profile in fixtures(now: now).keys {
            XCTAssertEqual(
                summaryLines(store.status(profile: profile)), pre[profile],
                "profile \(profile)"
            )
        }
        // TOML files still strict-parse after the import run.
        for profile in fixtures(now: now).keys {
            let url = dir.appendingPathComponent(
                TomlConfig.fileName(profile: profile)
            )
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = try TomlConfig.parse(text)
            _ = try TokenTOML.parse(text)
        }
    }

    // MARK: - Write-through (accept #4 Swift→Rust)

    func testWriteThroughBytesAndMode() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PersistentTokenStore(
            blob: MemoryTokenStore(), configDir: dir
        )
        let now = liveNow()
        var slots = TokenSlots()
        slots.accessToken = tok("aad", exp: now + 3600)
        slots.refreshToken = "FIXTURE-RT-NEW"
        slots.regionGtms = "{\"chatService\":\"https://FIXTURE.chat/\"}"
        let before = Date()
        try store.save(slots, profile: "wt-user")
        let url = dir.appendingPathComponent(
            TomlConfig.fileName(profile: "wt-user")
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        XCTAssertGreaterThanOrEqual(
            (attrs[.modificationDate] as? Date) ?? .distantPast, before
        )
        // Bytes strict-parse and round-trip (what Rust `status` would read).
        let text = try String(contentsOf: url, encoding: .utf8)
        _ = try TomlConfig.parse(text)
        XCTAssertEqual(try TokenTOML.parse(text), slots)
    }

    // MARK: - Rust→Swift visibility (accept #4)

    func testRustSaveShowsUpOnNextSwiftLoad() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PersistentTokenStore(
            blob: MemoryTokenStore(), configDir: dir
        )
        let now = liveNow()
        // First sight: empty (no file).
        XCTAssertFalse(store.status(profile: "r2s").signed_in)
        // External (Rust-side) save with different bytes.
        _ = try write(dir, profile: "r2s", toml: """
            refresh_token = "FIXTURE-RT"
            [access_token]
            token = "FIXTURE-AAD-RUST"
            expires_at = \(now + 3600)

            """)
        XCTAssertTrue(store.status(profile: "r2s").signed_in)
        XCTAssertEqual(
            store.load(profile: "r2s").accessToken?.token, "FIXTURE-AAD-RUST"
        )
    }

    // MARK: - Sign-out isolation (accept #5)

    func testSignOutIsolation() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PersistentTokenStore(
            blob: MemoryTokenStore(), configDir: dir
        )
        let now = liveNow()
        var a = TokenSlots()
        a.accessToken = tok("aad-a", exp: now + 3600)
        a.refreshToken = "FIXTURE-RT-A"
        var b = TokenSlots()
        b.accessToken = tok("aad-b", exp: now + 3600)
        b.refreshToken = "FIXTURE-RT-B"
        try store.save(a, profile: "so-a")
        try store.save(b, profile: "so-b")
        let urlB = dir.appendingPathComponent(
            TomlConfig.fileName(profile: "so-b")
        )
        let bytesBefore = try Data(contentsOf: urlB)

        try store.clear(profile: "so-a")

        // A: gone everywhere; B: byte-identical.
        let urlA = dir.appendingPathComponent(
            TomlConfig.fileName(profile: "so-a")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: urlA.path))
        XCTAssertFalse(store.load(profile: "so-a").hasAnything)
        XCTAssertEqual(try Data(contentsOf: urlB), bytesBefore)
        XCTAssertEqual(store.load(profile: "so-b"), b)
    }

    func testSignOutDefaultKeepsClearedFile() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PersistentTokenStore(
            blob: MemoryTokenStore(), configDir: dir
        )
        var slots = TokenSlots()
        slots.refreshToken = "FIXTURE-RT"
        try store.save(slots, profile: "default")
        try store.clear(profile: "default")
        let url = dir.appendingPathComponent(
            TomlConfig.fileName(profile: "default")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(
            try TokenTOML.parse(try String(contentsOf: url, encoding: .utf8)),
            TokenSlots.cleared()
        )
        XCTAssertFalse(store.status(profile: "default").signed_in)
    }

    // MARK: - Status purity (accept #5)

    func testStatusMakesNoChanges() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = liveNow()
        _ = try write(dir, profile: "pure", toml: fixtures(now: now)["fx-valid"]!)
        let store = try PersistentTokenStore(
            blob: MemoryTokenStore(), configDir: dir
        )
        _ = store.status(profile: "pure") // import run
        let url = dir.appendingPathComponent(
            TomlConfig.fileName(profile: "pure")
        )
        let bytes = try Data(contentsOf: url)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date
        // Steady-state status: pure read, no writes, no fetcher exists.
        for _ in 0 ..< 3 {
            XCTAssertTrue(store.status(profile: "pure").signed_in)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
                as? Date,
            mtime
        )
    }

    // MARK: - KLIPY/catchup non-interference (accept #1, static half)

    func testTokenServiceIsItsOwn() {
        XCTAssertEqual(KeychainTokenStore.service, "dev.ostmac.OstMac.tokens")
        XCTAssertNotEqual(
            KeychainTokenStore.service, KlipySystemKeychain.service
        )
        XCTAssertNotEqual(
            KeychainTokenStore.service, CatchUpSystemKeychain.service
        )
        XCTAssertEqual(
            KeychainTokenStore.account(profile: "default"), "profile:default"
        )
        XCTAssertEqual(
            KeychainTokenStore.account(profile: ""), "profile:default"
        )
        XCTAssertEqual(
            KeychainTokenStore.account(profile: "user@x"),
            "profile:\(TomlConfig.sanitize("user@x"))"
        )
    }

    func testMemoryStoreRoundTrip() throws {
        let mem = MemoryTokenStore(now: { 1_800_000_000 })
        var slots = TokenSlots()
        slots.accessToken = tok("aad", exp: 1_800_003_600)
        try mem.save(slots, profile: "m")
        XCTAssertEqual(mem.load(profile: "m"), slots)
        XCTAssertTrue(mem.status(profile: "m").signed_in)
        try mem.clear(profile: "m")
        XCTAssertFalse(mem.load(profile: "m").hasAnything)
    }
}
