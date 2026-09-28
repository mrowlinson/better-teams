// FfiMoveNowTests.swift — R12 ffi-move-now: ports of the Rust tests for
// moved symbols (red→green against Swift impls, no FFI).
import XCTest

@testable import OstMacCore

final class FfiMoveNowTests: XCTestCase {
    // MARK: - B0 helpers

    var tmpDir: URL!
    var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ffi-now-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suite = UserDefaults(suiteName: "ffi-now-\(UUID().uuidString)")!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        for k in suite.dictionaryRepresentation().keys { suite.removeObject(forKey: k) }
        super.tearDown()
    }

    func write(_ name: String, _ body: String) {
        try! body.write(to: tmpDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - B0: version / init

    func testVersionIs100() {
        XCTAssertEqual(RustCore.version(), "1.0.0")
        XCTAssertEqual(CoreLocal.version(), "1.0.0")
    }

    func testInitializeIsZero() {
        XCTAssertEqual(RustCore.initialize(), 0)
    }

    // MARK: - B0: profile path mapping (matches ost config)

    func testNormalize() {
        XCTAssertEqual(TomlConfig.normalize(""), "default")
        XCTAssertEqual(TomlConfig.normalize("   "), "default")
        XCTAssertEqual(TomlConfig.normalize("  acct-1 "), "acct-1")
    }

    func testSanitizeAsciiOnly() {
        XCTAssertEqual(TomlConfig.sanitize("acct-1.x_y"), "acct-1.x_y")
        XCTAssertEqual(TomlConfig.sanitize("a/b c@d"), "a_b_c_d")
        XCTAssertEqual(TomlConfig.sanitize(String(repeating: "a", count: 100)).count, 64)
        // Non-ASCII alphanumerics are NOT kept (Rust is_ascii_alphanumeric).
        XCTAssertEqual(TomlConfig.sanitize("é"), "_")
    }

    func testFileName() {
        XCTAssertEqual(TomlConfig.fileName(profile: ""), "config.toml")
        XCTAssertEqual(TomlConfig.fileName(profile: "default"), "config.toml")
        XCTAssertEqual(TomlConfig.fileName(profile: "DEFAULT"), "config.toml")
        XCTAssertEqual(TomlConfig.fileName(profile: "acct-1"), "config-acct-1.toml")
        XCTAssertEqual(TomlConfig.fileName(profile: "a/b"), "config-a_b.toml")
    }

    // MARK: - B0: status reads

    func testStatusMissingFileIsUnsigned() throws {
        let st = try CoreLocal.status(profile: "no-such-profile", configDir: tmpDir)
        XCTAssertTrue(st.ok)
        XCTAssertFalse(st.signed_in)
        XCTAssertFalse(st.tokens.aad.present)
        XCTAssertFalse(st.tokens.aad.expired)
        XCTAssertFalse(st.tokens.refresh_present)
        XCTAssertFalse(st.tokens.region_gtms_present)
        XCTAssertFalse(st.tokens.graph.present)
        XCTAssertFalse(st.tokens.ic3.present)
        XCTAssertFalse(st.tokens.recorder.present)
        XCTAssertFalse(st.tokens.skype.present)
    }

    func testStatusMachineShapedFile() throws {
        let future = UInt64(Date().timeIntervalSince1970) + 3600
        write("config.toml", """
        refresh_token = "r"
        tenant_id = "t"
        region_gtms = '{"a":"b"}'

        [access_token]
        token = "aad"
        expires_at = \(future)

        [skype_token]
        token = "s"
        expires_at = \(future)

        [graph_token]
        token = "g"
        expires_at = \(future)

        [ic3_token]
        token = "i"
        expires_at = \(future)

        [recorder_token]
        token = "r"
        expires_at = \(future)
        """)
        let st = try CoreLocal.status(profile: "default", configDir: tmpDir)
        XCTAssertTrue(st.ok)
        XCTAssertTrue(st.signed_in)
        XCTAssertTrue(st.tokens.aad.present)
        XCTAssertFalse(st.tokens.aad.expired)
        XCTAssertTrue(st.tokens.refresh_present)
        XCTAssertTrue(st.tokens.region_gtms_present)
        XCTAssertTrue(st.tokens.skype.present)
    }

    func testStatusExpiredSkew() {
        // now + 300 >= exp → expired (matches StoredToken::is_expired).
        XCTAssertTrue(TomlConfig.expired(1000, now: 700))
        XCTAssertTrue(TomlConfig.expired(1000, now: 701))
        XCTAssertFalse(TomlConfig.expired(1000, now: 699))
        XCTAssertFalse(TomlConfig.expired(nil, now: 9_999_999))
    }

    func testStatusExpiredFileSignsOut() throws {
        let past = UInt64(Date().timeIntervalSince1970) - 3600
        write("config.toml", "[access_token]\ntoken = \"a\"\nexpires_at = \(past)\n")
        let st = try CoreLocal.status(profile: "", configDir: tmpDir)
        XCTAssertTrue(st.ok)
        XCTAssertFalse(st.signed_in)
        XCTAssertTrue(st.tokens.aad.present)
        XCTAssertTrue(st.tokens.aad.expired)
    }

    func testStatusTokenWithoutExpiryStaysFresh() throws {
        write("config.toml", "[access_token]\ntoken = \"a\"\n")
        let st = try CoreLocal.status(profile: "default", configDir: tmpDir)
        XCTAssertTrue(st.signed_in)
        XCTAssertTrue(st.tokens.aad.present)
        XCTAssertFalse(st.tokens.aad.expired)
    }

    func testStatusPerProfileIsolation() throws {
        let future = UInt64(Date().timeIntervalSince1970) + 3600
        write("config-acct-a.toml", "[access_token]\ntoken = \"a\"\nexpires_at = \(future)\n")
        let a = try CoreLocal.status(profile: "acct-a", configDir: tmpDir)
        XCTAssertTrue(a.signed_in)
        let b = try CoreLocal.status(profile: "acct-b", configDir: tmpDir)
        XCTAssertFalse(b.signed_in)
    }

    func testStatusGarbageIsConfigLoad() {
        write("config.toml", "{{{\n")
        XCTAssertThrowsError(try CoreLocal.status(profile: "default", configDir: tmpDir)) { err in
            guard case CoreCallError.failed(let msg) = err else { return XCTFail("wrong error \(err)") }
            XCTAssertTrue(msg.hasPrefix("config_load"), msg)
        }
    }

    func testStatusWrongTypesAreConfigLoad() {
        for body in [
            "refresh_token = 123\n",
            "region_gtms = true\n",
            "[access_token]\ntoken = 1\n",
            "[access_token]\ntoken = \"a\"\nexpires_at = 1.5\n",
            "[access_token]\nexpires_at = 5\n", // missing token field
            "access_token = \"x\"\n", // token table shape
            "a = 1\na = 2\n", // duplicate key
            "[access_token]\n[access_token]\n", // duplicate table
            "a = \"unterminated\n",
            "a = \"bad \\q escape\"\n",
            "no-equals-here\n",
        ] {
            write("config.toml", body)
            XCTAssertThrowsError(
                try CoreLocal.status(profile: "default", configDir: tmpDir), "body: \(body)"
            ) { err in
                guard case CoreCallError.failed(let msg) = err else {
                    return XCTFail("wrong error \(err) for \(body)")
                }
                XCTAssertTrue(msg.hasPrefix("config_load"), "\(msg) for \(body)")
            }
        }
    }

    func testStatusBareCRAndControlsAreConfigLoad() {
        for body in [
            "a = \"x\"\ry\n",
            "a = \"x\u{01}y\"\n",
            "a = 'x\u{7F}y'\n",
        ] {
            write("config.toml", body)
            XCTAssertThrowsError(
                try CoreLocal.status(profile: "default", configDir: tmpDir), "body: \(body)"
            )
        }
        // Tab inside strings is legal TOML.
        write("config.toml", "a = \"x\ty\"\n[access_token]\ntoken = \"a\"\n")
        XCTAssertNoThrow(try CoreLocal.status(profile: "default", configDir: tmpDir))
    }

    func testStatusIgnoresUnknownKeys() throws {
        write("config.toml", """
        # comment line
        future_key = "v" # trailing comment
        count = -5
        ratio = 1.5
        flag = true
        when = 2024-01-02T03:04:05Z
        list = [1, "a"]
        [unknown_table]
        anything = "goes"
        [access_token]
        token = "a"
        noted = "extra"
        """)
        let st = try CoreLocal.status(profile: "default", configDir: tmpDir)
        XCTAssertTrue(st.ok)
        XCTAssertTrue(st.signed_in)
    }

    func testStatusCRLFAndLiteralStrings() throws {
        write("config.toml", "refresh_token = 'r#c'\r\nregion_gtms = '{\"k\":\"v#1\"}'\r\n")
        let st = try CoreLocal.status(profile: "default", configDir: tmpDir)
        XCTAssertTrue(st.ok)
        XCTAssertTrue(st.tokens.refresh_present)
        XCTAssertTrue(st.tokens.region_gtms_present)
        XCTAssertFalse(st.signed_in)
    }

    func testStatusEnvelopeKeys() throws {
        // Mirror of the deleted Rust status_envelope_has_expected_keys.
        let st = try CoreLocal.status(profile: "no-such", configDir: tmpDir)
        XCTAssertTrue(st.ok)
        // Tokens struct shape is compile-checked; booleans decode:
        XCTAssertFalse(st.signed_in)
    }

    // MARK: - B0: active profile

    func testProfileActiveDefaultsToDefault() throws {
        let p = try CoreLocal.profileActive(defaults: suite)
        XCTAssertTrue(p.ok)
        XCTAssertEqual(p.profile, "default")
    }

    func testProfileActiveReadsPersisted() throws {
        suite.set("acct-9", forKey: AccountStore.activeKey)
        let p = try CoreLocal.profileActive(defaults: suite)
        XCTAssertEqual(p.profile, "acct-9")
    }

    func testProfileActiveBlankIsDefault() throws {
        suite.set("  ", forKey: AccountStore.activeKey)
        let p = try CoreLocal.profileActive(defaults: suite)
        XCTAssertEqual(p.profile, "default")
    }

    func testStatusNoArgUsesPersistedActive() throws {
        let future = UInt64(Date().timeIntervalSince1970) + 3600
        write("config-acct-z.toml", "[access_token]\ntoken = \"a\"\nexpires_at = \(future)\n")
        suite.set("acct-z", forKey: AccountStore.activeKey)
        let st = try CoreLocal.status(defaults: suite, configDir: tmpDir)
        XCTAssertTrue(st.signed_in)
    }

    // MARK: - B1: join-parse (port of Rust join_parse_json_matrix + edges)

    func parse(_ raw: String) throws -> JoinTarget {
        try RustCore.meetingJoinParse(raw: raw).target
    }

    func testJoinParseThreadLink() throws {
        let t = try parse("https://teams.microsoft.com/l/meetup-join/19%3Ameeting_abc%40thread.v2/0")
        XCTAssertEqual(t.kind, "thread")
        XCTAssertEqual(t.threadID, "19:meeting_abc@thread.v2")
        XCTAssertNil(t.meetingID)
        XCTAssertTrue(t.canJoinInApp)
    }

    func testJoinParseBareThreadIDs() throws {
        for id in ["19:abc@thread.v2", "19:x@thread.tacv2", "48:1234abcd", "8:orgid:xyz"] {
            let t = try parse(id)
            XCTAssertEqual(t.kind, "thread", id)
            XCTAssertEqual(t.threadID, id)
            XCTAssertEqual(t.url, id)
        }
    }

    func testJoinParseLiveMeet() throws {
        let t = try parse("https://teams.live.com/meet/9347123456789")
        XCTAssertEqual(t.kind, "meeting-id")
        XCTAssertEqual(t.meetingID, "9347123456789")
        XCTAssertNil(t.threadID)
        XCTAssertTrue(t.canOpenExternally)
    }

    func testJoinParseLiveMeetStopsAtQuery() throws {
        let t = try parse("https://teams.live.com/meet/9347123456789?x=1&y=2")
        XCTAssertEqual(t.meetingID, "9347123456789")
    }

    func testJoinParseLiveMeetEmptyIDFallsToURL() throws {
        let t = try parse("https://teams.live.com/meet/")
        XCTAssertEqual(t.kind, "url")
        XCTAssertNil(t.meetingID)
    }

    func testJoinParseLiveMeetUppercaseIsURL() throws {
        // Gate is case-insensitive but the marker search is case-sensitive.
        let t = try parse("https://TEAMS.LIVE.COM/MEET/123")
        XCTAssertEqual(t.kind, "url")
    }

    func testJoinParseGarbageNeverDials() throws {
        let t = try parse("hello")
        XCTAssertEqual(t.kind, "unknown")
        XCTAssertNil(t.threadID)
        XCTAssertNil(t.meetingID)
        XCTAssertEqual(t.url, "hello")
        XCTAssertFalse(t.canJoinInApp)
        XCTAssertFalse(t.canOpenExternally)
    }

    func testJoinParseEmptyIsUnknownBlankURL() throws {
        for raw in ["", "   ", "<>"] {
            let t = try parse(raw)
            XCTAssertEqual(t.kind, "unknown", raw)
            XCTAssertEqual(t.url, "", raw)
        }
    }

    func testJoinParseStripsBracketsAndQuotes() throws {
        let t = try parse("<https://teams.live.com/meet/123>")
        XCTAssertEqual(t.kind, "meeting-id")
        XCTAssertEqual(t.meetingID, "123")
        XCTAssertEqual(t.url, "https://teams.live.com/meet/123")
        let q = try parse("\"19:abc@thread.v2\"")
        XCTAssertEqual(q.kind, "thread")
        XCTAssertEqual(q.threadID, "19:abc@thread.v2")
    }

    func testJoinParseMeetupWithoutThreadIsURL() throws {
        let t = try parse("https://teams.microsoft.com/l/meetup-join/abc")
        XCTAssertEqual(t.kind, "url")
        let h = try parse("http://teams.microsoft.com/l/meetup-join/abc")
        XCTAssertEqual(h.kind, "url")
    }

    func testJoinParseMeetupWithoutSchemeFallsThrough() throws {
        // No thread + no http(s) prefix: falls past the meetup branch.
        let t = try parse("teams.microsoft.com/l/meetup-join/abc")
        XCTAssertEqual(t.kind, "unknown")
    }

    func testJoinParseMeetPathIsURL() throws {
        let t = try parse("https://teams.microsoft.com/meet/123")
        XCTAssertEqual(t.kind, "url")
    }

    func testJoinParseThreadIDWithWhitespaceIsUnknown() throws {
        let t = try parse("19:a b@thread.v2")
        XCTAssertEqual(t.kind, "unknown")
    }

    func testJoinParseThread19WithoutAtIsURL() throws {
        let t = try parse("https://teams.microsoft.com/l/meetup-join/19:abc/0")
        XCTAssertEqual(t.kind, "url")
    }

    func testJoinParseUppercaseHostStillExtracts() throws {
        let t = try parse("HTTPS://TEAMS.MICROSOFT.COM/L/MEETUP-JOIN/19:abc@thread.v2/0")
        XCTAssertEqual(t.kind, "thread")
        XCTAssertEqual(t.threadID, "19:abc@thread.v2")
    }

    func testJoinParseStopsAtDelimitersAndTrimsPunct() throws {
        let t = try parse("https://teams.microsoft.com/l/meetup-join/19:abc@thread.v2?x=1")
        XCTAssertEqual(t.threadID, "19:abc@thread.v2")
        let p = try parse("https://teams.microsoft.com/l/meetup-join/19:abc@thread.v2).")
        XCTAssertEqual(p.threadID, "19:abc@thread.v2")
    }

    func testJoinParseMalformedPctPassesThrough() throws {
        // %zz stays literal, so no "19:" span exists → url (matches Rust).
        let t = try parse("https://teams.microsoft.com/l/meetup-join/19%zzabc%40thread.v2")
        XCTAssertEqual(t.kind, "url")
        XCTAssertNil(t.threadID)
        // ...but a valid span keeps the literal run inside the id.
        let u = try parse("https://teams.microsoft.com/l/meetup-join/19:abc@thread.v2%zz")
        XCTAssertEqual(u.kind, "thread")
        XCTAssertEqual(u.threadID, "19:abc@thread.v2%zz")
    }

    func testJoinParsePlainHTTPIsUnknown() throws {
        let t = try parse("http://example.com/x")
        XCTAssertEqual(t.kind, "unknown")
        let h = try parse("https://example.com/x")
        XCTAssertEqual(h.kind, "url")
        XCTAssertEqual(h.url, "https://example.com/x")
    }

    func testJoinParseResponseOK() throws {
        let r = try RustCore.meetingJoinParse(raw: "hello")
        XCTAssertTrue(r.ok)
    }

    // MARK: - B1: av_info (mirror of deleted Rust av_info_shape, full keys)

    func testAvInfoCaps() throws {
        let info = try RustCore.avInfo()
        XCTAssertTrue(info.ok)
        XCTAssertEqual(info.mic, "cpal")
        XCTAssertEqual(info.speaker, "cpal")
        XCTAssertEqual(info.camera, "avfoundation")
        XCTAssertEqual(info.display, "swiftui")
        XCTAssertTrue(info.tone)
        XCTAssertEqual(info.packetizer, "rust-h264")
        XCTAssertEqual(info.srtp, "rust-aes-128-cm")
        XCTAssertTrue(info.dry_run)
    }

    // MARK: - B0: perf smoke (generous bounds; guards against regressions)

    func testStatusParsePerf() throws {
        let future = UInt64(Date().timeIntervalSince1970) + 3600
        let body = """
        refresh_token = "r"
        tenant_id = "t"
        region_gtms = '{"a":"b"}'
        [access_token]
        token = "aad"
        expires_at = \(future)
        [graph_token]
        token = "g"
        expires_at = \(future)
        """
        let t0 = Date()
        for _ in 0 ..< 1000 { _ = try TomlConfig.parse(body) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
    }

    // MARK: - B2: tone_check (mirror of Rust av_tone_check_detects + test_tone)

    func testToneCheckDetects() throws {
        let v = try RustCore.toneCheck()
        XCTAssertTrue(v.ok)
        XCTAssertTrue(v.detected, "peak=\(v.correlation_peak)")
        XCTAssertGreaterThan(abs(v.correlation_peak), 0.3)
    }

    func testToneCheckDeterministic() throws {
        let a = try RustCore.toneCheck()
        let b = try RustCore.toneCheck()
        XCTAssertEqual(a.correlation_peak, b.correlation_peak)
        XCTAssertEqual(a.delay_ms, b.delay_ms)
        XCTAssertEqual(a.detected, b.detected)
    }

    func testToneGeneratorFrame() {
        var gen = ToneDsp.ToneGenerator()
        let frame = gen.nextFrame()
        XCTAssertEqual(frame.count, 160)
        XCTAssertTrue(frame.contains(where: { $0 > 1000 }))
        XCTAssertTrue(frame.contains(where: { $0 < -1000 }))
    }

    func testDetectEchoSilence() {
        let r = ToneDsp.detectEcho(
            received: [Int16](repeating: 0, count: 8000),
            toneFreq: 1000.0, sampleRate: 8000.0
        )
        XCTAssertFalse(r.detected)
        XCTAssertEqual(r.correlationPeak, 0)
    }

    func testDetectEchoShortInputIsZero() {
        let r = ToneDsp.detectEcho(
            received: [Int16](repeating: 100, count: 8),
            toneFreq: 1000.0, sampleRate: 8000.0
        )
        XCTAssertFalse(r.detected)
        XCTAssertEqual(r.delayMs, 0)
        XCTAssertEqual(r.correlationPeak, 0)
    }

    func testDetectEchoToneAfterSilence() {
        var gen = ToneDsp.ToneGenerator()
        var samples = [Int16](repeating: 0, count: 400)
        for _ in 0 ..< 25 { samples.append(contentsOf: gen.nextFrame()) }
        let r = ToneDsp.detectEcho(received: samples, toneFreq: 1000.0, sampleRate: 8000.0)
        XCTAssertTrue(r.detected, "peak=\(r.correlationPeak)")
        XCTAssertGreaterThan(r.delayMs, 0)
    }

    func testToneCheckPerf() throws {
        // Release tier: ~26µs/run (measured standalone); debug is ~40ms.
        // Loose bound guards against algorithmic regressions only.
        let t0 = Date()
        for _ in 0 ..< 30 { _ = try RustCore.toneCheck() }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5.0)
    }

    func testJoinParsePerf() {
        let urls = [
            "https://teams.microsoft.com/l/meetup-join/19%3Ameeting_abc%40thread.v2/0",
            "19:abc@thread.v2",
            "https://teams.live.com/meet/9347123456789",
            "hello",
        ]
        let t0 = Date()
        for _ in 0 ..< 2500 {
            for u in urls { _ = JoinParse.parse(raw: u) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.0)
    }
}
