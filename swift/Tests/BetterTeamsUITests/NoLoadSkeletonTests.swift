// NoLoadSkeletonTests.swift — NOLOAD: skeleton rows render (list panes
// with nothing cached). BT_NOLOAD_SHOT=<png path> also writes the
// offscreen render for a visual check.
import SwiftUI
import XCTest

@testable import BetterTeamsUI

@MainActor
final class NoLoadSkeletonTests: XCTestCase {
    func testSkeletonRowsRender() throws {
        let view = SkeletonRows()
            .frame(width: 340, height: 420, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 340)
        if let out = ProcessInfo.processInfo.environment["BT_NOLOAD_SHOT"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: out))
        }
    }
}
