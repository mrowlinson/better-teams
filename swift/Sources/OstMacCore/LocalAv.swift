// LocalAv.swift — R12 ffi-move-now B1/B2: av_info (B1) + tone_check (B2)
// moved from Rust FFI to Swift (static caps + deterministic DSP self-check).
import Foundation

/// Deterministic tone DSP: exact port of ost's `calling::test_tone`
/// (1kHz sine frames + matched-filter echo detect). No hardware.
enum ToneDsp {
    struct ToneGenerator {
        var phase = 0.0
        let frequency = 1000.0
        let sampleRate = 8000.0
        let amplitude = 0.8

        /// Next 160-sample frame (20ms at 8kHz).
        mutating func nextFrame() -> [Int16] {
            var samples: [Int16] = []
            samples.reserveCapacity(160)
            let phaseInc = 2.0 * Double.pi * frequency / sampleRate
            for _ in 0 ..< 160 {
                // Rust `as i16` truncates + saturates; clamp then convert.
                let raw = (sin(phase) * amplitude * 32767.0).rounded(.towardZero)
                let clamped = min(max(raw, -32768.0), 32767.0)
                samples.append(clamped.isNaN ? 0 : Int16(clamped))
                phase += phaseInc
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            }
            return samples
        }
    }

    struct EchoResult {
        var detected: Bool
        var delayMs: Double
        var correlationPeak: Double
    }

    /// Matched-filter echo detect: slides a one-period reference sine
    /// over `received`, normalized cross-correlation, 0.3 threshold.
    static func detectEcho(
        received: [Int16], toneFreq: Double, sampleRate: Double
    ) -> EchoResult {
        let periodSamples = Int(sampleRate / toneFreq)
        guard received.count >= periodSamples * 2 else {
            return EchoResult(detected: false, delayMs: 0, correlationPeak: 0)
        }
        var reference: [Double] = []
        reference.reserveCapacity(periodSamples)
        for i in 0 ..< periodSamples {
            let t = Double(i) / sampleRate
            reference.append(sin(2.0 * Double.pi * toneFreq * t))
        }
        let refEnergy = reference.reduce(0.0) { $0 + $1 * $1 }
        var bestCorr = 0.0
        var bestOffset = 0
        let maxOffset = received.count - periodSamples
        for offset in 0 ..< maxOffset {
            var cross = 0.0
            var sigEnergy = 0.0
            for (i, r) in reference.enumerated() {
                let s = Double(received[offset + i]) / 32768.0
                cross += r * s
                sigEnergy += s * s
            }
            let denom = (refEnergy * sigEnergy).squareRoot()
            let corr = denom > 1e-10 ? cross / denom : 0.0
            if abs(corr) > abs(bestCorr) {
                bestCorr = corr
                bestOffset = offset
            }
        }
        return EchoResult(
            detected: abs(bestCorr) > 0.3,
            delayMs: Double(bestOffset) / sampleRate * 1000.0,
            correlationPeak: bestCorr
        )
    }
}

extension CoreLocal {
    /// Deterministic tone echo self-check (was `ostmac_tone_check`).
    static func toneCheck() throws -> ToneCheckResult {
        var gen = ToneDsp.ToneGenerator()
        var samples = [Int16](repeating: 0, count: 400)
        for _ in 0 ..< 25 { samples.append(contentsOf: gen.nextFrame()) }
        let r = ToneDsp.detectEcho(received: samples, toneFreq: 1000.0, sampleRate: 8000.0)
        let data = try statusJSONData([
            "ok": true,
            "detected": r.detected,
            "delay_ms": r.delayMs,
            "correlation_peak": r.correlationPeak,
        ])
        return try decodeOrThrow(ToneCheckResult.self, from: data)
    }

    /// Static capability map (was `ostmac_av_info`). No hardware touched.
    static func avInfo() throws -> AvInfo {
        let data = try statusJSONData([
            "ok": true,
            "mic": "cpal",
            "speaker": "cpal",
            "camera": "avfoundation",
            "display": "swiftui",
            "tone": true,
            "packetizer": "rust-h264",
            "srtp": "rust-aes-128-cm",
            "dry_run": true,
        ])
        return try decodeOrThrow(AvInfo.self, from: data)
    }
}
