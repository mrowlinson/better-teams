// GifPlayerState.swift — P4 split: verbatim move from GifPlayer.swift.
import Combine
import Foundation

/// Playhead state shared by the bubble player and the zoom viewer.
/// Wall-time driven: views feed TimelineView dates into `tick`.
@MainActor
public final class GifPlayerState: ObservableObject {
    @Published public private(set) var playing: Bool
    /// Seconds into the loop; frozen while paused.
    @Published public private(set) var playhead: Double = 0
    private var lastTick: Date?

    public init(playing: Bool) {
        self.playing = playing
    }

    public func toggle() {
        playing.toggle()
        lastTick = nil // resume without a jump
    }

    /// Advance the playhead by wall time, wrapping the loop. While
    /// paused the playhead freezes (the still stays up); degenerate
    /// loops just restamp.
    public func tick(now: Date, totalDuration: Double) {
        guard playing, totalDuration > 0 else {
            lastTick = now
            return
        }
        if let last = lastTick {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                playhead = (playhead + dt)
                    .truncatingRemainder(dividingBy: totalDuration)
            }
        }
        lastTick = now
    }

    /// Reduce Motion pauses on the still; turning it off resumes
    /// autoplay. A manual toggle sticks until the setting changes again.
    public func applyReduceMotion(_ reduceMotion: Bool) {
        playing = GifPlayback.initiallyPlaying(
            animated: true, reduceMotion: reduceMotion)
        lastTick = nil
    }
}
