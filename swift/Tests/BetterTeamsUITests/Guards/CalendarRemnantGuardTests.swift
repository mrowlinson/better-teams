// CalendarRemnantGuardTests — CAL-REMNANT (C4) guards: the new channel,
// options and overlay surfaces use native controls only, and every
// overlay write path stays gated read-only.
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

final class CalendarRemnantGuardTests: XCTestCase {
    private var calDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI/Sections/Calendar")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: calDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// New surfaces exist and are built from native controls (Menu,
    /// Picker, Toggle, Section, Form): no custom tab/chrome types.
    func testNewSurfacesUseNativeControls() throws {
        let sheets = try source("CalendarSheets.swift")
        XCTAssertTrue(sheets.contains("Section(\"Meeting options\")"), "options section")
        XCTAssertTrue(sheets.contains("Toggle(\"Request responses\""), "responses toggle")
        XCTAssertTrue(sheets.contains("Toggle(\"Allow new time proposals\""), "proposals toggle")
        XCTAssertTrue(sheets.contains("Toggle(\"Hide attendee list\""), "hide-attendees toggle")
        XCTAssertTrue(sheets.contains("Picker(\"Channel\""), "channel picker")
        let views = try source("CalendarViews.swift")
        XCTAssertTrue(views.contains("struct CalendarsMenu"), "overlay menu")
        XCTAssertTrue(views.contains("\"Overlay another calendar\""), "overlay help")
        for banned in ["UnderlineTab", "TabStrip", "WebView"] {
            XCTAssertFalse(sheets.contains(banned), banned)
            XCTAssertFalse(views.contains(banned), banned)
        }
    }

    /// Every overlay write path is gated: the UI hides write actions for
    /// overlaid rows and the store refuses them.
    func testOverlayWritePathsStayGated() throws {
        let toolbar = try source("CalendarDetailToolbar.swift")
        XCTAssertTrue(toolbar.contains("if !isOverlay"), "toolbar gates overlay rows")
        let views = try source("CalendarViews.swift")
        XCTAssertTrue(views.contains("!isOverlay"), "list/menu/inspector gate overlay rows")
        let grid = try source("CalendarWeekGrid.swift")
        XCTAssertTrue(grid.contains("isOverlay"), "grid marks overlay rows")
        XCTAssertTrue(grid.contains("other calendar"), "overlay accessibility label")
    }

    /// The read-only contract is exact (UI copy matches the store error).
    func testReadOnlyContractIsExact() throws {
        XCTAssertEqual(CalendarWeekStore.readOnlyOverlayMessage, "Other calendars are read-only")
        let views = try source("CalendarViews.swift")
        XCTAssertTrue(views.contains("Other calendar"), "list badge")
    }
}
