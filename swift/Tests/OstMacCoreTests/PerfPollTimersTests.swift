// PerfPollTimersTests — om-perf-poll-timers: FFI poll-path cost pins + microbench.
//
// Before/after medians live in tmp/PERF-POLL-TIMERS-PROOF.md. Bounds here
// are generous regression guards (100x+ above measured), never tight
// perf asserts — CI load must not flake them.
import XCTest
@testable import OstMacCore

final class PerfPollTimersTests: XCTestCase {
    /// Median wall ns of `body` over `n` iters (first iter = warmup, discarded).
    static func medianNs(_ n: Int = 200, _ body: () throws -> Void) rethrows -> Double {
        try body()
        var samples: [Double] = []
        samples.reserveCapacity(n)
        for _ in 0 ..< n {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try body()
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1) - Double(t0))
        }
        samples.sort()
        return samples[n / 2]
    }

    /// Exact empty typed-poll envelope shape (key order irrelevant to decode).
    static let emptyPoll = Data(
        #"{"ok":true,"messages":[],"resync":false,"skipped":0,"calls":[],"typing":[],"roster":[],"backlog":0}"#.utf8)

    /// 300KB synthetic message-list payload (no interior NUL, valid UTF-8).
    static func bigJSONString() -> String {
        let row = #"{"id":"m-0123456789-abcdef","sender":"Ava Lindqvist","timestamp":"2026-09-25T20:00:00Z","content":"Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor."},"#
        return #"{"ok":true,"messages":[\#(String(repeating: row, count: 2000))]}"#
    }

    // MARK: - CString adoption (the RustCore.call fix, pure-Swift measure)

    func testBenchCStringAdoption300K() throws {
        let json = Self.bigJSONString()
        XCTAssertGreaterThan(json.utf8.count, 250_000)
        // Old way (pre-fix RustCore.call): String scan+alloc, then re-encode.
        let oldNs = Self.medianNs {
            let ptr = (json as NSString).utf8String!
            _ = String(cString: ptr).data(using: .utf8)!
        }
        // New way: single length-delimited copy, no String, no re-encode.
        let newNs = Self.medianNs {
            let ptr = (json as NSString).utf8String!
            _ = Data(bytes: UnsafeRawPointer(ptr), count: strlen(ptr))
        }
        print("PERFBENCH cstringAdopt300K oldNs=\(oldNs) newNs=\(newNs)")
        // Byte-identical results.
        let ptr = (json as NSString).utf8String!
        XCTAssertEqual(String(cString: ptr).data(using: .utf8)!, Data(bytes: UnsafeRawPointer(ptr), count: strlen(ptr)))
        // New must not be catastrophically worse (it does strictly less
        // work; the real delta is recorded in the PROOF, not asserted).
        XCTAssertLessThan(newNs, oldNs * 2)
        XCTAssertLessThan(newNs, 100_000_000) // 100ms: absurdly generous
    }

    // MARK: - Decode path (routes through decodeOrThrow like every poll)

    func testBenchEmptyPollDecode() throws {
        let env = Self.emptyPoll
        let med = try Self.medianNs { _ = try decodeOrThrow(RealtimePoll.self, from: env) }
        print("PERFBENCH emptyPollDecodeNs=\(med)")
        XCTAssertLessThan(med, 5_000_000)
    }

    func testBenchLargeDecode() throws {
        let data = Data(Self.bigJSONString().utf8)
        struct BigList: Decodable { let ok: Bool; let messages: [ChatMessage] }
        let med = try Self.medianNs(50) { _ = try decodeOrThrow(BigList.self, from: data) }
        print("PERFBENCH largeDecode300KNs=\(med)")
        XCTAssertLessThan(med, 500_000_000)
    }

    // MARK: - Live FFI roundtrip (slot read, no network)

    func testBenchCallStatusFFI() throws {
        let med = try Self.medianNs(100) { _ = try RustCore.callStatus() }
        print("PERFBENCH callStatusNs=\(med)")
        XCTAssertLessThan(med, 50_000_000)
    }

    func testBenchEmptyTypedPollFFI() throws {
        // Real drain_wait(0) + typed envelope + full Swift decode.
        let med = try Self.medianNs(100) { _ = try RustCore.trouterPollTyped() }
        print("PERFBENCH emptyTypedPollNs=\(med)")
        XCTAssertLessThan(med, 50_000_000)
    }

    // MARK: - Behavior parity pins (the fix must preserve these)

    func testCallNullThrows() {
        XCTAssertThrowsError(try RustCore.call(nil, as: RealtimePoll.self)) { e in
            guard case CoreCallError.failed(let m) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(m, "null from core")
        }
    }

    func testErrorEnvelopeStillThrows() {
        let data = Data(#"{"ok":false,"error":"arg","detail":"bad id"}"#.utf8)
        XCTAssertThrowsError(try decodeOrThrow(RealtimePoll.self, from: data)) { e in
            guard case CoreCallError.failed(let m) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(m, "arg: bad id")
        }
    }
}
