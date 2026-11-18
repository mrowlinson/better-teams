// ReauthPrompt.swift — one expired-session prompt for every surface
// (UI-SPEC §6 error panes; AUTH-UX). The core reports an expired
// session as a raw string (`failed("messages: Stored session expired
// (stored session expired (refresh token rejected: AADSTS...); ...");
// Trace ID ... Correlation ID ...`) built for logs and the CLI, never
// for the screen. These panes show a short human sentence plus the
// app's existing sign-in flow instead. Nothing here prints tokens:
// the raw text is matched, never rendered.
import Foundation

/// The expired-session prompt shared by every error pane.
enum ReauthPrompt {
    /// Short human sentence shown in place of the raw core error.
    static let message = "Your sign-in expired. Sign in again to continue."
    /// Launches the app's existing sign-in sheet (device-code flow).
    static let signInTitle = "Sign In Again"
    /// Retried load, unchanged.
    static let retryTitle = "Try Again"

    /// True when a core error string is an expired-session report. The
    /// match is deliberately textual: the FFI envelope carries the
    /// error as a plain string, so the typed `ReauthRequired` marker
    /// cannot cross it. Each arm names a distinct producer:
    /// - "session expired": the Rust wrap chain (single-wrapped since
    ///   AUTH-UX; matched loosely so a future re-wrap still prompts
    ///   instead of leaking).
    /// - "invalid_grant": the `is_reauth_required` substring fallback
    ///   in `rust/ost/src/auth/oauth.rs`.
    /// - "aadsts": raw IdP error codes (e.g. AADSTS70043), which reach
    ///   the string only inside a rejected-refresh detail.
    /// The redaction list below names what must never render; the
    /// matcher only decides the prompt, it never forwards the text.
    static func isReauth(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("session expired")
            || t.contains("invalid_grant")
            || t.contains("aadsts")
    }

    /// Protocol/session fragments that must never reach the screen.
    /// The prompt renders only `message`; this list pins what it
    /// replaces (guard: ReauthPromptGuardTests).
    /// - AADSTS: raw IdP error codes with tenant detail.
    /// - Trace ID / Correlation ID: log correlation, not user text.
    /// - teams-cli: a CLI command, meaningless in the app.
    static let neverRender = ["AADSTS", "Trace ID", "Correlation ID", "teams-cli"]
}

/// Posts when a pane's Sign In Again button fires; the shell observes
/// it and presents the existing sign-in sheet. A notification (not a
/// sheet request) because the sign-in sheet is an AppKit controller
/// owned by the window controller, outside section-sheet routing.
extension Notification.Name {
    static let showSignIn = Notification.Name("bt.showSignIn")
}
