// GifPlayback.swift — om-gif-playback: animated GIF detect + clip + play gate.
//
// Inline GIFs animate like Teams: the bubble shows the looping clip with
// a native play/stop overlay instead of the old static first frame.
// Reduce Motion starts paused on the first frame (timeline precedent);
// pressing play is explicit user intent and animates either way.
// Pure probe/math stays testable without views; decoding runs off-main.

/// Play/stop + Reduce Motion gate. Pure so tests pin the contract.
public enum GifPlayback {
    /// Autoplay iff the bytes animate and Reduce Motion is off.
    /// The overlay toggle always stays available (explicit user intent).
    public static func initiallyPlaying(animated: Bool, reduceMotion: Bool) -> Bool {
        animated && !reduceMotion
    }
}
