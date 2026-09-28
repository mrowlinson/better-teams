// MicCapture.swift — om-avfix: microphone permission gate.
// Mirrors CameraCapture.requestAccess (.video) for the mic test + level
// meter (.audio). Listing devices needs no permission; sampling does, so
// the panel prompts once (on Test) and surfaces denial with a fix-it hint.
import AVFoundation
import Foundation

/// Microphone TCC gate (no state; status reads never prompt).
public enum MicAccess {
    /// Current mic authorization (never prompts).
    public static func status() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// True when the user denied (or is restricted from) mic access.
    public static var denied: Bool {
        let s = status()
        return s == .denied || s == .restricted
    }

    /// Request mic access. True = granted. Mirrors CameraCapture.requestAccess.
    public static func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    /// System Settings deep link to the Microphone privacy row.
    public static let privacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
