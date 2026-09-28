// LiveVideoModel.swift — om-liveav: incoming-AU poll + VT decode for display.
// Drains the Rust incoming queue on a detached loop, decoding every AU in
// order on the same serial path (CALLFIX: no reference frame skipped), and
// publishes the newest frame on-main. Ticks at 30 fps while video flows;
// idle polls never touch main (local liveness token) and back off to 0.5s.
import Combine
import CoreGraphics
import Foundation

/// Lock-guarded loop generation: the poll loop checks liveness locally
/// instead of hopping to main twice per tick.
final class LiveLoopToken: @unchecked Sendable {
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

    /// The core source this model decodes (a meeting tile's MSI); nil =
    /// the 1:1 incoming queue.
    public nonisolated let source: UInt32?
    private nonisolated let loopToken = LiveLoopToken()

    public init(source: UInt32? = nil) {
        self.source = source
    }

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
        let source = source
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoder = H264StreamDecoder()
            var nilStreak = 0
            var needKey = false
            while token.alive(gen) {
                let delay = LiveVideoPacing.delayMs(nilStreak: nilStreak)
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard token.alive(gen) else { return }
                do {
                    // Every queued unit decodes in order (no reference
                    // frame is skipped); only the newest picture shows.
                    let tick = try LiveVideoDrain.run(needKey: &needKey, poll: { () throws -> [Data]? in
                        guard token.alive(gen) else { return nil }
                        let poll: IncomingPoll
                        if let source {
                            poll = try RustCore.videoPollSource(source)
                        } else {
                            poll = try RustCore.videoPollIncoming()
                        }
                        return poll.au?.nals
                    }, decode: { nals in
                        do {
                            return try decoder.decode(nals: nals)
                        } catch H264DecodeError.noImage {
                            return nil // no picture out; the decoder state is intact
                        }
                    })
                    guard tick.units > 0 else {
                        nilStreak += 1
                        continue // idle: no main hop, backoff stretches
                    }
                    nilStreak = 0
                    if let img = tick.latest {
                        let decoded = tick.decoded
                        await MainActor.run { [weak self] in
                            guard let self, token.alive(gen) else { return }
                            self.remoteImage = img
                            self.frames += decoded
                            self.status = "\(img.width)x\(img.height) live"
                        }
                    } else if let error = tick.error {
                        await MainActor.run { [weak self] in
                            guard let self, token.alive(gen) else { return }
                            self.status = "decode: \(error.localizedDescription)"
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
