// LockedBox.swift — test support: a lock-guarded mutable cell for state
// that @Sendable seams (fetchers, feeds, callbacks) mutate from whatever
// thread invokes them, and the test then asserts on.
import Foundation

/// @unchecked Sendable is sound: every read/write of `inner` goes through
/// `lock`, so concurrent seam calls never race the test's assertions.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var inner: T

    init(_ value: T) { inner = value }

    var value: T {
        get { lock.withLock { inner } }
        set { lock.withLock { inner = newValue } }
    }

    /// Atomic read-modify-write (`box.value += 1` is get-then-set).
    func mutate<R>(_ body: (inout T) throws -> R) rethrows -> R {
        try lock.withLock { try body(&inner) }
    }
}
