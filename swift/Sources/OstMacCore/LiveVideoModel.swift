// LiveVideoModel.swift — om-liveav: incoming-AU poll + VT decode for display.
// Drains the Rust incoming queue on a detached loop, decodes AUs on the
// same serial path, publishes the latest frame on-main. Idle polls never
// touch main (local liveness token) and back off 250ms -> 1s.
import Combine
import CoreGraphics
import Foundation

/// Lock-guarded loop generation: the poll loop checks liveness locally
/// instead of hopping to main twice per tick.
private final class LiveLoopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    /// Begin a new loop run; invalidates every older run.
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    func alive(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }
}

@MainActor
public final class LiveVideoModel: ObservableObject {
    @Published public private(set) var remoteImage: CGImage?
    @Published public private(set) var status = "idle"
    @Published public private(set) var frames = 0
    @Published public private(set) var running = false

    private nonisolated let loopToken = LiveLoopToken()

    public init() {}

    deinit {
        // The poll loop holds self weakly: invalidate its run so a
        // deallocated model never leaves a background poller behind.
        _ = loopToken.next()
    }

    public func start() {
        guard !running else { return }
        running = true
        status = "waiting for video…"
        let gen = loopToken.next()
        let token = loopToken
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoder = H264StreamDecoder()
            var nilStreak = 0
            while token.alive(gen) {
                let delay = LiveVideoPacing.delayMs(nilStreak: nilStreak)
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard token.alive(gen) else { return }
                do {
                    let poll = try RustCore.videoPollIncoming()
                    guard let au = poll.au else {
                        nilStreak += 1
                        continue // idle: no main hop, backoff stretches
                    }
                    nilStreak = 0
                    if let img = try decoder.decode(nals: au.nals) {
                        await MainActor.run { [weak self] in
                            guard let self, token.alive(gen) else { return }
                            self.remoteImage = img
                            self.frames += 1
                            self.status = "\(img.width)x\(img.height) live"
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, token.alive(gen) else { return }
                        self.status = "decode: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    public func stop() {
        _ = loopToken.next()
        running = false
        status = "stopped"
    }
}
