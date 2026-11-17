// SpeechReader.swift — Read Aloud (C8d, MSG-13/ACC-01): speaks the
// keyboard-selected message (Edit ▸ Speech ▸ Start/Stop Speaking).
// AVSpeechSynthesizer; `testHook` captures text in tests so the suite
// never speaks aloud.
import AVFoundation
import Foundation

/// One shared speaker (Stop cuts the current utterance).
@MainActor
public enum SpeechReader {
    private static let synth = AVSpeechSynthesizer()
    /// Tests set this: text is captured, never spoken.
    public static var testHook: ((String) -> Void)?
    /// The utterance Start Speaking read last (nil after Stop).
    public private(set) static var lastSpoken: String?

    public static var speaking: Bool { lastSpoken != nil }

    public static func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let hook = testHook {
            lastSpoken = t
            hook(t)
            return
        }
        stopSynth()
        lastSpoken = t
        synth.speak(AVSpeechUtterance(string: t))
    }

    public static func stop() {
        stopSynth()
        lastSpoken = nil
    }

    private static func stopSynth() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
