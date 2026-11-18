// Guard: AUTH-UX — expired-session errors surface as a clean sign-in
// prompt, never raw protocol text (owner 11-18: doubled
// "Stored session expired (stored session expired ..." + AADSTS/trace
// IDs/a CLI command on the channel chat screen). Source-scan shape
// (cf. SignInGuardTests): SwiftUI buttons are not inspectable under
// xctest, so these pin the exact strings and the wiring points the
// panes call. Nothing is shown on screen.
import XCTest

@testable import BetterTeamsUI

final class ReauthPromptGuardTests: XCTestCase {
    static func uiSource(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BetterTeamsUI")
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The exact user-facing expired-session sentence is pinned where
    /// it is defined (ReauthPrompt, single source of truth), and the
    /// pane is pinned to render that constant rather than raw text.
    func testExpiredSessionSentenceIsPinned() throws {
        let prompt = try Self.uiSource("Shared/ReauthPrompt.swift")
        XCTAssertTrue(prompt.contains("Your sign-in expired. Sign in again to continue."),
                      "expired-session sentence missing from ReauthPrompt.swift")
        let panes = try Self.uiSource("Shared/StateViews.swift")
        XCTAssertTrue(panes.contains("ReauthPrompt.message"),
                      "ErrorPane does not render the pinned sentence")
    }

    /// Error panes route expired-session errors through the reauth
    /// prompt instead of rendering the raw core string.
    func testErrorPaneDetectsExpiredSession() throws {
        let src = try Self.uiSource("Shared/StateViews.swift")
        XCTAssertTrue(src.contains("isReauth"), "ErrorPane has no expired-session branch")
    }

    /// The prompt offers Sign In Again (launches the app's existing
    /// sign-in sheet) alongside the retained Try Again.
    func testSignInAgainActionIsWired() throws {
        let panes = try Self.uiSource("Shared/StateViews.swift")
        XCTAssertTrue(panes.contains("Sign In Again"), "no Sign In Again button in the panes")
        let shell = try Self.uiSource("Shell/ShellWindowController.swift")
        XCTAssertTrue(shell.contains("showSignIn"), "sign-in sheet has no pane trigger")
    }

    /// Raw protocol/session text never reaches the screen: the prompt
    /// helper knows the IdP codes, trace/correlation IDs, and CLI
    /// commands it must never render.
    func testTraceIDsNeverReachTheScreen() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BetterTeamsUI/Shared/ReauthPrompt.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "Shared/ReauthPrompt.swift missing")
        let src = try String(contentsOf: root, encoding: .utf8)
        for token in ["AADSTS", "Trace ID", "Correlation ID", "teams-cli"] {
            XCTAssertTrue(src.contains(token), "redaction list missing \(token)")
        }
    }

    /// Direct detector coverage: the exact owner-reported string
    /// prompts, ordinary failures do not, and the pinned sentence
    /// itself carries none of the redacted fragments.
    func testDetectorCatchesExpiredSessionStrings() {
        let owner = "failed(\"messages: Stored session expired (stored session expired "
            + "(refresh token rejected: AADSTS70043 ... Trace ID ... Correlation ID ...); "
            + "run `teams-cli login` to sign in again).\")"
        XCTAssertTrue(ReauthPrompt.isReauth(owner))
        XCTAssertTrue(ReauthPrompt.isReauth("stored session expired (refresh token rejected: invalid_grant)"))
        XCTAssertTrue(ReauthPrompt.isReauth("Token refresh failed: invalid_grant."))
    }

    func testDetectorStaysQuietOnOrdinaryFailures() {
        XCTAssertFalse(ReauthPrompt.isReauth("network timeout"))
        XCTAssertFalse(ReauthPrompt.isReauth("Couldn't load: 500 internal error"))
        XCTAssertFalse(ReauthPrompt.isReauth(""))
    }

    func testPinnedSentenceCarriesNoRedactedFragments() {
        for token in ReauthPrompt.neverRender {
            XCTAssertFalse(ReauthPrompt.message.lowercased().contains(token.lowercased()),
                           "pinned sentence leaks \(token)")
        }
    }
}
