// SyncCoalescerTests.swift — launch-r2: concurrent same-key callers
// share one fetch (same data, fewer requests).
import XCTest

@testable import OstMacCore

final class SyncCoalescerTests: XCTestCase {
    func testConcurrentSameKeySharesOneRun() {
        let calls = LockedBox(0)
        let coder = SyncCoalescer<String>()
        let results = LockedBox<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let v = try coder.run(key: "k") {
                    calls.mutate { $0 += 1 }
                    Thread.sleep(forTimeInterval: 0.2)
                    return "v"
                }
                results.mutate { $0.append(v) }
            } catch {
                XCTFail("unexpected throw: \(error)")
            }
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(results.value, Array(repeating: "v", count: 8))
    }

    func testErrorSharedByWaiters() {
        struct Boom: Error {}
        let calls = LockedBox(0)
        let coder = SyncCoalescer<Int>()
        let failures = LockedBox(0)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                _ = try coder.run(key: "k") { () -> Int in
                    calls.mutate { $0 += 1 }
                    Thread.sleep(forTimeInterval: 0.2)
                    throw Boom()
                }
                XCTFail("expected throw")
            } catch is Boom {
                failures.mutate { $0 += 1 }
            } catch {
                XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(failures.value, 4)
    }

    func testDifferentKeysRunSeparately() throws {
        let calls = LockedBox(0)
        let coder = SyncCoalescer<Int>()
        let a = try coder.run(key: "a") { calls.mutate { $0 += 1 }; return 1 }
        let b = try coder.run(key: "b") { calls.mutate { $0 += 1 }; return 2 }
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 2)
        XCTAssertEqual(calls.value, 2)
    }

    func testSequentialCallsRerun() throws {
        let calls = LockedBox(0)
        let coder = SyncCoalescer<Int>()
        _ = try coder.run(key: "k") { calls.mutate { $0 += 1 }; return 1 }
        _ = try coder.run(key: "k") { calls.mutate { $0 += 1 }; return 2 }
        XCTAssertEqual(calls.value, 2)
    }
}
