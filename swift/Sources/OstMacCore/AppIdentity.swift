// AppIdentity.swift — om-app-union: single source for app branding.
// Moved from the om-package OstMacApp module (deleted in the union);
// About window, Settings, entry, and tests all read these.
// Info.plist (OstMac-Info.plist) mirrors them.
import Foundation

public enum AppIdentity {
    public static let name = "Better Teams"
    public static let bundleID = "dev.ostmac.OstMac"
    public static let version = "1.0.0"
    public static let minimumOS = "14.0"
    public static let aboutWindowID = "about"
    public static let authWindowID = "auth"
    public static let avWindowID = "av"
    public static let callWindowID = "call"
    public static let diagWindowID = "diagnostics"
    public static let callsWindowID = "calls"
    public static let meetWindowID = "meetings"
    public static let meetingWindowID = "meeting"
    public static let chatPopoutID = "chat-popout"
    /// gap-g8: one value-driven window per popped meeting / file.
    public static let meetingPopoutID = "meeting-popout"
    public static let filePopoutID = "file-popout"
    /// gap-g2: one value-driven window per open account (value = account id).
    public static let accountWindowID = "account-window"
    public static let quickComposerPanelID = "quick-composer"
    public static let teamsFrameWindowID = "teams-frame"
    public static let tagline = "Teams client for macOS"
}

// MARK: - Account (Settings window, read-only)

/// Read-only account snapshot for the Settings window.
public struct AccountInfo: Equatable, Sendable {
    public let signedIn: Bool
    public let detail: String

    public init(signedIn: Bool, detail: String) {
        self.signedIn = signedIn
        self.detail = detail
    }

    public static let loading = AccountInfo(signedIn: false, detail: "Loading…")
    public static let unavailable = AccountInfo(signedIn: false, detail: "Status unavailable")

    /// Settings row from the 13-state gate (single source; replaces direct
    /// status reads). signedIn is true only for .signedIn; failures show
    /// the message verbatim so the row is always actionable.
    public static func from(authState: AuthState, status: StatusResponse?) -> AccountInfo {
        switch authState {
        case .unknown:
            return AccountInfo(signedIn: false, detail: "Checking session…")
        case .signedOut:
            return AccountInfo(signedIn: false, detail: "Not signed in")
        case .starting:
            return AccountInfo(signedIn: false, detail: "Contacting Microsoft…")
        case .code:
            return AccountInfo(signedIn: false, detail: "Waiting for browser sign-in…")
        case let .polling(_, attempts):
            if attempts > 0 {
                return AccountInfo(
                    signedIn: false,
                    detail: "Waiting for browser sign-in… (check \(attempts + 1))")
            }
            return AccountInfo(signedIn: false, detail: "Waiting for browser sign-in…")
        case .browser:
            return AccountInfo(signedIn: false, detail: "Signing in with browser…")
        case .browserWorking:
            return AccountInfo(signedIn: false, detail: "Completing browser sign-in…")
        case .signedIn:
            if let status { return summarize(status) }
            return AccountInfo(signedIn: true, detail: "Signed in")
        case .signingOut:
            return AccountInfo(signedIn: false, detail: "Signing out…")
        case .expired:
            return AccountInfo(signedIn: false, detail: "Session expired")
        case .refreshing:
            return AccountInfo(signedIn: false, detail: "Refreshing session…")
        case let .refreshFailed(message):
            return AccountInfo(signedIn: false, detail: message)
        case let .error(message):
            return AccountInfo(signedIn: false, detail: message)
        }
    }

    /// Deterministic one-line summary of a core status response.
    public static func summarize(_ status: StatusResponse) -> AccountInfo {
        guard status.signed_in else {
            return AccountInfo(signedIn: false, detail: "Not signed in")
        }
        let slots = [
            status.tokens.aad.present,
            status.tokens.refresh_present,
            status.tokens.graph.present,
            status.tokens.ic3.present,
            status.tokens.recorder.present,
            status.tokens.skype.present,
            status.tokens.region_gtms_present,
        ]
        let n = slots.filter { $0 }.count
        return AccountInfo(signedIn: true, detail: "Signed in · tokens \(n)/\(slots.count)")
    }
}
