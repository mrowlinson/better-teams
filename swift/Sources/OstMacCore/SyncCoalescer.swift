// SyncCoalescer.swift — launch-r2: one in-flight result shared across
// concurrent sync (blocking) callers with the same key. Same data,
// fewer requests: the owner runs `work`, waiters share its result (or
// error). A bounded wait keeps a stuck owner from hanging waiters —
// they run the work themselves instead.
import Foundation

final class SyncCoalescer<Value: Sendable>: Sendable {
    private let lock = NSLock()
    private final class Flight: @unchecked Sendable {
        var result: Result<Value, Error>?
        let group = DispatchGroup()
    }
    private var flights: [String: Flight] = [:]

    /// Run `work` once per key (see above). Not reentrant per key on
    /// the same thread (the owner never waits on its own flight).
    func run(key: String, timeout: TimeInterval = 90, work: () throws -> Value) throws -> Value {
        lock.lock()
        if let flight = flights[key] {
            lock.unlock()
            // A stuck owner (>timeout) must not hang the launch: run
            // unshared rather than wait forever.
            guard flight.group.wait(timeout: .now() + timeout) == .success else {
                return try work()
            }
            return try result(of: flight)
        }
        let flight = Flight()
        flight.group.enter()
        flights[key] = flight
        lock.unlock()
        do {
            let value = try work()
            finish(key: key, flight: flight, result: .success(value))
            return value
        } catch {
            finish(key: key, flight: flight, result: .failure(error))
            throw error
        }
    }

    private func result(of flight: Flight) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard let result = flight.result else {
            throw CoreCallError.failed("coalescer: owner finished without a result")
        }
        return try result.get()
    }

    private func finish(key: String, flight: Flight, result: Result<Value, Error>) {
        lock.lock()
        flights[key] = nil
        flight.result = result
        lock.unlock()
        flight.group.leave()
    }
}
