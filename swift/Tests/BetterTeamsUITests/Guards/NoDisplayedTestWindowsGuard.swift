// Guard: tests never put a window on a display (owner rule "tests never
// show windows"). Two layers: a source scan (every bare NSWindow/NSPanel
// built in a test is off-display), and a runtime check any window-building
// test can call in tearDown.
import XCTest
import AppKit

@MainActor
enum TestDisplayGuard {
    /// Windows that are ordered in AND overlap a real display.
    static func windowsOnDisplay() -> [NSWindow] {
        NSApplication.shared.windows.filter { w in
            w.isVisible && NSScreen.screens.contains { $0.frame.intersects(w.frame) }
        }
    }
}

@MainActor
final class NoDisplayedTestWindowsGuard: XCTestCase {
    func testNoTestWindowReachesADisplay() {
        XCTAssertTrue(TestDisplayGuard.windowsOnDisplay().isEmpty,
                      "a test left a window on a display: \(TestDisplayGuard.windowsOnDisplay().map { $0.frame })")
    }

    /// Any `NSWindow(` / `NSPanel(` built directly in a test must sit at an
    /// off-display origin; on-display-capable ones must use OffscreenWindow.
    func testEveryBareWindowInTestsIsOffDisplay() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            if url.lastPathComponent == "NoDisplayedTestWindowsGuard.swift" { continue }
            scanned += 1
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("NSWindow(") || line.contains("NSPanel(") {
                if line.contains("-20000") || line.contains("-30000") { continue }
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 5, "control: scan found the test files")
        XCTAssertTrue(offenders.isEmpty, "bare on-display-capable windows: \(offenders)")
    }
}
