// BlockingExecutor.swift — CHATPERF R22.2: the ONE place blocking core /
// FFI / sync-network work runs.
//
// Why: `Task.detached { try RustCore.x() }` puts a thread-blocking call on
// the Swift cooperative pool (one thread per core). At launch dozens of
// stores fan out blocking calls; once every pool thread is parked in one,
// every other async hop in the app (a chat-open read, a `MainActor` task
// awaiting a nonisolated function) queues behind them until some call
// returns. That is the multi-minute spinner.
//
// Fix: blocking bodies run on threads this file owns, never the pool.
//   * `Task.blocking { ... }` is the drop-in for `Task.detached { ... }`
//     (same result/error/cancel handle, same `[weak self]` etc.).
//   * `BlockingExecutor.run { ... }` bridges one synchronous throwing call
//     to async (what `ChatListViewModel.offPool` was).
// Width is bounded (thread count can never balloon the way GCD's does) and
// priority-aware: interactive work (.userInitiated and above) may use every
// thread; everything else is capped below the total, so a user-driven read
// always finds a free thread even while background fan-out is parked in
// slow calls. Queued interactive jobs are also served before background.
//
// A `Task` running here only holds a thread while it executes synchronously;
// an `await` inside the body returns the thread and resumes on this executor.
// Lint: BlockingLintTests fails on any `Task.detached` outside this file.
import Foundation

public final class BlockingExecutor: TaskExecutor, @unchecked Sendable {
    /// The app-wide executor. 32 threads total, 16 usable by background work.
    public static let shared = BlockingExecutor(
        name: "dev.ostmac.blocking", width: 32, backgroundWidth: 16)

    /// TEST SEAM (mutation check): when true, `Task.blocking` degrades to
    /// `Task.detached` (the pre-CHATPERF cooperative-pool behaviour) so
    /// tests can prove the starvation test fails on the old pattern.
    /// Never set outside tests.
    nonisolated(unsafe) static var legacyCooperativePool = false

    public let width: Int
    public let backgroundWidth: Int

    private let name: String
    private let cond = NSCondition()
    private var interactive: [UnownedJob] = []
    private var background: [UnownedJob] = []
    private var threads = 0
    private var idle = 0
    private var runningBackground = 0

    public init(name: String, width: Int, backgroundWidth: Int) {
        precondition(width >= 2 && backgroundWidth >= 1 && backgroundWidth < width)
        self.name = name
        self.width = width
        self.backgroundWidth = backgroundWidth
    }

    /// Threads spawned so far (never above `width`).
    public var threadCount: Int {
        cond.lock(); defer { cond.unlock() }
        return threads
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let interactiveJob = job.priority.rawValue >= TaskPriority.userInitiated.rawValue
        let unowned = UnownedJob(job)
        cond.lock()
        if interactiveJob { interactive.append(unowned) } else { background.append(unowned) }
        // Grow when runnable jobs outnumber idle threads (an idle thread
        // already signalled but not yet awake still counts as idle).
        let runnable = interactive.count + min(background.count, max(0, backgroundWidth - runningBackground))
        if runnable > idle, threads < width {
            threads += 1
            let n = threads
            let t = Thread { [self] in workerLoop() }
            t.name = "\(name).\(n)"
            t.stackSize = 1 << 20
            t.start()
        }
        cond.signal()
        cond.unlock()
    }

    private func workerLoop() {
        let executor = asUnownedTaskExecutor()
        while true {
            cond.lock()
            var job: UnownedJob?
            var isBackground = false
            while job == nil {
                if !interactive.isEmpty {
                    job = interactive.removeFirst()
                } else if !background.isEmpty, runningBackground < backgroundWidth {
                    job = background.removeFirst()
                    isBackground = true
                    runningBackground += 1
                } else {
                    idle += 1
                    cond.wait()
                    idle -= 1
                }
            }
            cond.unlock()

            pthread_set_qos_class_self_np(
                isBackground ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED, 0)
            job!.runSynchronously(on: executor)

            if isBackground {
                cond.lock()
                runningBackground -= 1
                // A background job may now be startable.
                if !background.isEmpty { cond.signal() }
                cond.unlock()
            }
        }
    }

    /// Run one synchronous, possibly blocking, throwing call off the
    /// cooperative pool and return its result. Interactive by default
    /// (the callers were user-driven list/timeline reads).
    public static func run<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ op: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task<T, Error>.blocking(priority: priority) { try op() }.value
    }
}

// MARK: - Task.blocking (drop-in for Task.detached)

extension Task where Failure == Never {
    /// `Task.detached` whose body runs on `BlockingExecutor.shared`.
    @discardableResult
    public static func blocking(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if BlockingExecutor.legacyCooperativePool {
            return Task.detached(priority: priority, operation: operation)
        }
        return Task.detached(
            executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
    }
}

extension Task where Failure == Error {
    /// Throwing flavour of `Task.blocking`.
    @discardableResult
    public static func blocking(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        if BlockingExecutor.legacyCooperativePool {
            return Task.detached(priority: priority, operation: operation)
        }
        return Task.detached(
            executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
    }
}
