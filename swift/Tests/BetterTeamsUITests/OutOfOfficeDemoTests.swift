// OutOfOfficeDemoTests.swift — OOO-SET R2 demo verify: the section
// hosts its AppKit-backed controls in demo mode (live=false) with an
// inert store — offscreen, no window shown, zero network. Picker/buttons
// don't materialize AppKit views in this harness (proven over 3 hosting
// shapes), so their native-control shape is pinned by source scan below
// (VisfixM1 established pattern).
import AppKit
import SwiftUI
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

@MainActor
final class OutOfOfficeDemoTests: XCTestCase {
    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    private func source(_ rel: String) throws -> String {
        try String(contentsOf: sourcesDir.appendingPathComponent(rel), encoding: .utf8)
    }

    private func hosted() -> [NSView] {
        let view = OutOfOfficeSection(presence: PresenceStore(), live: false)
        let host = NSHostingView(rootView: Form { view }.formStyle(.grouped))
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return GuardSupport.subviews(of: host)
    }

    func testDemoHostsFieldAndStartPicker() {
        let views = hosted()
        XCTAssertFalse(views.compactMap({ $0 as? NSTextField }).isEmpty, "message field present")
        XCTAssertFalse(views.compactMap({ $0 as? NSDatePicker }).isEmpty, "start picker present")
    }

    /// Native controls only (HIG foundation: no web-style pickers or
    /// custom buttons in the OOO editor).
    func testSectionUsesNativeControls() throws {
        let src = try source("Settings/PresenceSections.swift")
        for token in ["TextField(\"Reply message\"", "DatePicker(\"Starts\"",
                      "Picker(\"Duration\"", "Button(\"Set Out of Office\")",
                      "Button(\"Turn Off\""] {
            XCTAssertTrue(src.contains(token), "\(token) in OutOfOfficeSection")
        }
        XCTAssertFalse(src.contains("WebView"), "no web views in presence settings")
    }

    /// The section is wired into Settings ▸ Notifications.
    func testPaneWiresOutOfOffice() throws {
        let pane = try source("Settings/NotificationsPane.swift")
        XCTAssertTrue(pane.contains("OutOfOfficeSection(presence: presence, live: live)"),
                      "NotificationsPane hosts the OOO section")
    }
}
