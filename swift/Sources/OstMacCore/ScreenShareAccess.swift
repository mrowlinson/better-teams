// ScreenShareAccess.swift — P4 split: verbatim move from ScreenShare.swift.
import CoreGraphics
import Foundation

/// Screen Recording TCC gate (mirrors MicAccess; status reads never prompt).
/// The system picker owns the one authorization prompt — there is no
/// separate request call; post-denial recovery is the Settings deep link.
public enum ScreenShareAccess {
    /// Prompt-free preflight (false headless/denied — never hangs).
    public static func granted() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Current permission (never prompts).
    public static func status() -> ScreenSharePermission {
        ScreenSharePermission(granted: granted())
    }

    /// System Settings deep link to the Screen Recording privacy row.
    public static let privacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}
