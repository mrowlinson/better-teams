// Guard (TOOLBARLINE, owner: "the grey line extending up ... it looks off
// to me"): the toolbar is one unified band across the window. The rail and
// the info panel start below it (no grey column rising through the toolbar)
// and the traffic lights sit on the toolbar band, never on rail icons.
import XCTest
import AppKit

import OstMacCore
@testable import BetterTeamsUI

@MainActor
final class ToolbarLineGuardTests: XCTestCase {
    func testNoColumnRisesThroughTheToolbar() {
        let split = ShellSplitViewController(rail: NSViewController())
        XCTAssertTrue(split.detailItem.allowsFullHeightLayout, "control: the property is per item")
        XCTAssertFalse(split.railItem.allowsFullHeightLayout, "rail must not start at the window top")
        XCTAssertFalse(split.inspectorItem.allowsFullHeightLayout, "info panel must not start at the window top")
        // A sidebar-behavior item ignores allowsFullHeightLayout: its material
        // always runs to the window top (the grey line). The rail is a plain
        // item that draws the sidebar material itself.
        XCTAssertNotEqual(split.railItem.behavior, .sidebar, "sidebar behavior tints up through the toolbar")
        XCTAssertNotEqual(split.inspectorItem.behavior, .sidebar)
    }

    func testRailDrawsItsOwnSidebarMaterialAsOneView() throws {
        let split = ShellSplitViewController(rail: NSViewController())
        let container = split.railItem.viewController
        let material = try XCTUnwrap(container.view as? NSVisualEffectView, "the rail is one material view")
        XCTAssertEqual(material.material, .sidebar)
        // No second grey band view hides in the rail or the toolbar area.
        let materials = GuardSupport.subviews(of: material).compactMap { $0 as? NSVisualEffectView }
        XCTAssertEqual(materials.count, 1, "one material view, no separate band")
    }

    func testToolbarSeparatorsTrackPlainSplitDividers() throws {
        // The system sidebar separator applies to sidebar items only.
        let order = ShellToolbarController.layout([]).order
        XCTAssertEqual(order.first, .railListSeparator)
        XCTAssertFalse(order.contains(.sidebarTrackingSeparator))
    }

    func testTrafficLightsClearTheRailIcons() throws {
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "toolbarline.guard")  // lights sit lower with a toolbar
        let lights = ChromeGeometry.trafficLights(window)
        XCTAssertEqual(lights.count, 3, "control: close, minimize, zoom exist")
        let bottom = lights.map(\.maxY).max() ?? 0
        // The rail's icons begin at the toolbar's height (RailModel.toolbarSafeArea)
        // at the earliest; the lights end above that line.
        XCTAssertLessThanOrEqual(bottom, RailModel.toolbarSafeArea,
                                 "traffic lights (\(bottom)pt from the top) must end above the rail's first icon")
    }
}
