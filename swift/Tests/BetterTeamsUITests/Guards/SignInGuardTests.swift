// Guard: SIGNIN — owner 09-30: "it would also be great if we could
// integreate the signin directly into the app, even if it's just loading
// with a webview frame in the main window when no accounts are signed in."
// (a) signed out (no account): the main window's content is the sign-in
//     pane, and Microsoft sign-in shows embedded in it, not in a sheet;
// (b) the in-app sign-in path never hands a URL to the system browser
//     (source scan with a positive control; the end-to-end test in
//     SignInEmbedTests also asserts no open call).
import AppKit
import WebKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class SignInGuardTests: XCTestCase {
    /// (a) The window with no account shows the sign-in pane; the web
    /// sign-in is inside the window's own content view.
    func testSignedOutWindowEmbedsSignIn() throws {
        let wc = ShellWindowController(graph: AppState(args: ["--demo"]), options: LaunchOptions(args: ["--demo", "--evidence"]))
        let window = try XCTUnwrap(wc.window)
        window.setFrame(NSRect(x: -30000, y: -30000, width: 900, height: 700), display: false)
        addTeardownBlock { @MainActor in wc.close() }
        // Closed port: the page never loads; only placement is checked.
        wc.showSignIn(evidence: .web(URL(string: "http://127.0.0.1:9/authorize")!))
        let vc = try XCTUnwrap(window.contentViewController as? SignInViewController, "no sign-in pane in the main window")
        let web = try XCTUnwrap(vc.webSignIn?.web, "sign-in web view missing")
        XCTAssertTrue(web.isDescendant(of: try XCTUnwrap(window.contentView)))
        XCTAssertNil(window.attachedSheet, "sign-in must be in the window, not a sheet")
        XCTAssertEqual(window.title, "Sign In")
        window.layoutIfNeeded() // a layout pass: nothing may shrink the window back
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, SignInWebController.contentSize,
                       "the window sizes to the embedded sign-in")
        // Native chrome around the page: a footer below it (Cancel, code
        // fallback) and nothing under the title bar.
        let content = try XCTUnwrap(window.contentView)
        let webFrame = web.convert(web.bounds, to: content)
        let titleBar = content.bounds.height - window.contentLayoutRect.height
        XCTAssertGreaterThanOrEqual(content.isFlipped ? webFrame.minY : content.bounds.height - webFrame.maxY, titleBar - 0.5,
                                    "web view runs under the title bar")
        XCTAssertGreaterThanOrEqual(content.isFlipped ? content.bounds.height - webFrame.maxY : webFrame.minY, 40,
                                    "no footer below the web view: \(webFrame) in \(content.bounds)")
        XCTAssertFalse(window.isVisible)
    }

    /// (a) Production default: the signed-out window starts sign-in by
    /// itself (off only under XCTest, so tests never reach Microsoft).
    func testAutoStartIsOnOutsideTests() throws {
        let src = try Self.source("Auth/SignInViewController.swift")
        XCTAssertTrue(src.contains(#"defaultAutoStart = NSClassFromString("XCTestCase") == nil"#))
        XCTAssertTrue(src.contains("autoStart: Bool = SignInViewController.defaultAutoStart"))
    }

    /// Calls that would leave the app for a browser.
    static let banned = try! NSRegularExpression(
        pattern: #"NSWorkspace|TeamsLinkRouter\s*\.\s*open|openBrowser\s*\(|openURL|LSOpen|/usr/bin/open\b|ASWebAuthenticationSession"#)

    static func violations(in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("///") { return false }
            let code = line.components(separatedBy: " // ").first ?? line
            return banned.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }
    }

    /// (b) The embedded sign-in files never open the browser.
    func testInAppPathNeverOpensTheBrowser() throws {
        XCTAssertFalse(Self.violations(in: "_ = NSWorkspace.shared.open(url)").isEmpty, "scanner blind (positive control)")
        XCTAssertFalse(Self.violations(in: "auth.openBrowser()").isEmpty, "scanner blind (positive control)")
        XCTAssertTrue(Self.violations(in: "// NSWorkspace.shared.open(url)").isEmpty, "scanner flags comments")
        for file in ["Auth/SignInWebController.swift", "Auth/SignInViewController.swift"] {
            let bad = Self.violations(in: try Self.source(file))
            XCTAssertTrue(bad.isEmpty, "\(file) opens the browser: \(bad)")
        }
    }

    static func source(_ rel: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BetterTeamsUI")
        return try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }
}
