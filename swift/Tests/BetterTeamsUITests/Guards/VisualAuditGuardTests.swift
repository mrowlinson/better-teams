// Guard: visual-audit fix round 2 port (fixpack-audit2): F3 chat list
// sections draw no header rule; F4 an active filter switches the toolbar
// glyph to the filled variant and tints it; F5 the contact card sheet
// closes with Done, not a corner X; F6 LinkedIn is an SF Symbol like its
// siblings; F9 failed send and failed delete share one Messages-style form.
// Evidence-pin anchoring (claimsEvidencePin) keeps the card opening from
// the sender name, not avatars. DELIBERATELY UNPINNED (Teams parity stands
// on main, ChatRowsTests pins it): unread-row weight (source F2), save-menu
// title case (source F8).
import XCTest

@testable import BetterTeamsUI

@MainActor
final class VisualAuditGuardTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testF3SectionsHaveNoHeaderRule() throws {
        let s = try source("BetterTeamsUI/Sections/Chat/ChatListPane.swift")
        let hits = s.components(separatedBy: ".listSectionSeparator(.hidden)").count - 1
        XCTAssertGreaterThanOrEqual(hits, 3, "pinned, favorites, recent sections")
    }

    func testF4FilterGlyphHasFilledActiveVariant() throws {
        XCTAssertTrue(CommandValidation(enabled: true, active: true).active)
        XCTAssertFalse(CommandValidation.enabled.active)
        for cmd in [ChatCommands.all, ActivityCommands.all].flatMap({ $0 }) where cmd.isSubmenu && cmd.symbol?.hasPrefix("line.3") == true {
            let base = try XCTUnwrap(cmd.symbol)
            XCTAssertEqual(base, "line.3.horizontal.decrease.circle")
            XCTAssertNotNil(NSImage(systemSymbolName: base + ".fill", accessibilityDescription: nil), "filled variant exists")
        }
        let s = try source("BetterTeamsUI/Shell/ShellToolbarController.swift")
        XCTAssertTrue(s.contains("base + \".fill\"") && s.contains("style = active ? .prominent : .plain"))
    }

    func testF5ContactSheetClosesWithDone() throws {
        let s = try source("BetterTeamsUI/Shared/ContactCardViews.swift")
        XCTAssertTrue(s.contains("Button(\"Done\")") && s.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertFalse(s.contains("Image(systemName: \"xmark\")"), "no corner X close")
    }

    func testF6LinkedInIsASymbol() throws {
        let s = try source("BetterTeamsUI/Shared/ContactCardViews.swift")
        XCTAssertFalse(s.contains("Text(\"in\")"), "no text glyph")
        XCTAssertTrue(s.contains("Image(systemName: Self.linkedInSymbol)"))
        XCTAssertNotNil(NSImage(systemSymbolName: "person.crop.square", accessibilityDescription: nil))
    }

    func testF9FailedStatesShareOneForm() throws {
        XCTAssertEqual(FailedSendStatus.visibleTitle, "Not Sent")
        XCTAssertEqual(FailedSendStatus.deleteFailedTitle, "Couldn't Delete")
        XCTAssertFalse(FailedSendStatus.visibleTitle.hasSuffix("."))
        let s = try source("BetterTeamsUI/Timeline/MessageRowView.swift")
        let i = try XCTUnwrap(s.range(of: "Button(FailedSendStatus.retryTitle) { actions?.retryDelete(message) }"))
        XCTAssertFalse(s[i.lowerBound...].prefix(120).contains(".buttonStyle(.link)"),
                       "delete Retry is the same bordered control as send Retry")
    }

    func testEvidencePinClaimedBySenderNameOnly() throws {
        for path in ["BetterTeamsUI/Sections/Chat/ChatRow.swift",
                     "BetterTeamsUI/Timeline/MessageRowView.swift"] {
            let s = try source(path)
            XCTAssertTrue(s.contains("claimsEvidencePin: false"), "\(path) avatar stays out of the pin")
        }
        let hover = try source("BetterTeamsUI/Shared/ContactHover.swift")
        XCTAssertTrue(hover.contains("var claimsEvidencePin = true"), "name anchors still claim by default")
    }
}
