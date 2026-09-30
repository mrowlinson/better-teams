// Guard: NATIVEUI — chrome uses native macOS controls. Owner 09-29: "this is
// macos native ui design compliant? plain text with underlines for the
// selected option?"; "the sidebar paradigm with the buttons can stay but
// every other surface must be macos native ui deisgn compliant".
// (a) source scan of BetterTeamsUI (Rail/ exempt) for underline tabs,
//     Capsule chrome and brand-purple tab chrome, with positive and
//     negative controls for the scanner;
// (b) a hosted ChatTabBar contains a real NSSegmentedControl (offscreen
//     NSHostingView, no window);
// (c) pure tests for the segment title and the "More" menu rule.
import AppKit
import SwiftUI
import XCTest

@testable import BetterTeamsUI
@testable import OstMacCore

enum NativeControlsScanner {
    /// Files where a Capsule is content, not chrome (path suffix, reason).
    static let capsuleAllowlist: [(suffix: String, reason: String)] = [
        ("Sections/Calendar/CalendarWeekGrid.swift", "today marker behind the day number (Apple Calendar style)"),
        ("Sections/Calendar/CalendarMonthGrid.swift", "today marker behind the day number (Apple Calendar style)"),
    ]
    static let bannedIdentifiers = ["TabStrip", "UnderlineTab", "ChatTabItem"]
    static let noBrandChromeFiles = ["Conversation/ChatTabs.swift", "Shared/ContactCardViews.swift"]

    /// Findings for one source file. `path` is relative to BetterTeamsUI.
    static func violations(in source: String, path: String) -> [String] {
        var out: [String] = []
        let lines = source.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let code = line.components(separatedBy: "//").first ?? line
            if code.contains("Rectangle()") {
                let snippet = lines[i..<min(lines.count, i + 5)].joined(separator: "\n")
                let bar = snippet.range(of: #"\.frame\(height:\s*[1-4](\.0)?\)"#, options: .regularExpression) != nil
                let selectedState = snippet.contains(" ? ") || snippet.contains("Color.clear")
                if bar && selectedState { out.append("\(path):\(i + 1): underline-tab indicator (Rectangle bar with selected state)") }
            }
            for id in bannedIdentifiers where code.range(of: "\\b\(id)\\b", options: .regularExpression) != nil {
                out.append("\(path):\(i + 1): banned identifier \(id)")
            }
            if noBrandChromeFiles.contains(where: path.hasSuffix), code.contains("Palette.mention") {
                out.append("\(path):\(i + 1): Palette.mention in tab chrome")
            }
            if code.contains("Capsule("), !capsuleAllowlist.contains(where: { path.hasSuffix($0.suffix) }) {
                out.append("\(path):\(i + 1): Capsule outside the content allowlist")
            }
        }
        return out
    }
}

@MainActor
final class NativeControlsGuardTests: XCTestCase {
    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    // MARK: (a) scan

    func testNoNonNativeChromeInSources() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(sourcesDir.path.count + 1))
            if rel.hasPrefix("Rail/") { continue }
            scanned += 1
            found += NativeControlsScanner.violations(in: try String(contentsOf: url, encoding: .utf8), path: rel)
        }
        XCTAssertGreaterThan(scanned, 50, "control: scan found the source files")
        XCTAssertTrue(found.isEmpty, "non-native chrome:\n" + found.joined(separator: "\n"))
    }

    func testAllowlistedCapsuleFilesStillExist() {
        for (suffix, _) in NativeControlsScanner.capsuleAllowlist {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourcesDir.appendingPathComponent(suffix).path), suffix)
        }
    }

    /// Positive controls: the scanner flags each pattern. Negative controls: it leaves a divider and an allowlisted Capsule alone.
    func testScannerPositiveAndNegativeControls() {
        let underline = """
            Rectangle()
                .fill(on ? Palette.mention : Color.clear)
                .frame(height: 2)
            """
        XCTAssertEqual(NativeControlsScanner.violations(in: underline, path: "Foo/Tabs.swift").count, 1, "underline flagged")
        let capsule = "Text(x).background(Capsule().fill(.tint))"
        XCTAssertEqual(NativeControlsScanner.violations(in: capsule, path: "Sections/Chat/Pill.swift").count, 1, "capsule flagged")
        XCTAssertTrue(NativeControlsScanner.violations(in: capsule, path: "Sections/Calendar/CalendarWeekGrid.swift").isEmpty,
                      "allowlisted capsule ok")
        XCTAssertEqual(NativeControlsScanner.violations(in: "struct TabStrip: View {}", path: "Foo.swift").count, 1, "identifier flagged")
        XCTAssertEqual(NativeControlsScanner.violations(in: "let c = Palette.mention", path: "Conversation/ChatTabs.swift").count, 1)
        XCTAssertTrue(NativeControlsScanner.violations(in: "let c = Palette.mention", path: "Timeline/AttachmentViews.swift").isEmpty)
        let divider = """
            Rectangle()
                .fill(Color.gray)
                .frame(height: 1)
            """
        XCTAssertTrue(NativeControlsScanner.violations(in: divider, path: "Foo/Tabs.swift").isEmpty, "plain divider not flagged")
    }

    // MARK: (b) hosted tab bar

    private func segmentedControls(width: CGFloat, layout: ChatTabLayout, selected: ChatTabKey) -> [NSSegmentedControl] {
        let bar = ChatTabBar(layout: layout, selection: .constant(selected), opened: nil, open: { _ in }, close: {})
        let host = NSHostingView(rootView: bar)
        host.frame = CGRect(x: 0, y: 0, width: width, height: 60)
        host.layoutSubtreeIfNeeded()
        return GuardSupport.subviews(of: host).compactMap { $0 as? NSSegmentedControl }
    }

    func testChatTabBarHostsANativeSegmentedControl() throws {
        let layout = ChatTabLayout(kind: .group, tabs: DemoChatTabs.tabs(for: "demo"))
        let selected = ChatTabKey.builtin(.chat)
        let folds = layout.folds(selected: selected, opened: nil)
        let wide = segmentedControls(width: 1600, layout: layout, selected: selected)
        let control = try XCTUnwrap(wide.first, "an NSSegmentedControl is in the tab bar")
        XCTAssertEqual(wide.count, 1)
        XCTAssertEqual(control.segmentCount, try XCTUnwrap(folds.first).segments.count)
        let narrow = try XCTUnwrap(segmentedControls(width: 200, layout: layout, selected: selected).first)
        XCTAssertLessThan(narrow.segmentCount, control.segmentCount, "narrow pane folds segments into More")
        // Pinned segments keep their symbol beside the title; built-ins are text only.
        let segments = try XCTUnwrap(folds.first).segments
        XCTAssertTrue(segments.contains { if case .pinned = $0.key { true } else { false } }, "demo chat has pinned tabs")
        for (i, e) in segments.enumerated() {
            XCTAssertFalse((control.label(forSegment: i) ?? "").isEmpty, "segment \(i) has a title")
            if case .pinned = e.key {
                XCTAssertNotNil(control.image(forSegment: i), "pinned segment \(e.name) shows its symbol")
            } else {
                XCTAssertNil(control.image(forSegment: i), "built-in segment \(e.name) is text only")
            }
        }
    }

    // MARK: (c) pure

    func testSegmentTitle() {
        XCTAssertEqual(ChatTabLayout.segmentTitle("Notes"), "Notes")
        XCTAssertEqual(ChatTabLayout.segmentTitle(String(repeating: "a", count: 24)), String(repeating: "a", count: 24))
        let file = "Quarterly Engineering Release Notes and Migration Checklist (final, reviewed).docx"
        let t = ChatTabLayout.segmentTitle(file)
        XCTAssertLessThanOrEqual(t.count, ChatTabLayout.maxSegmentTitle)
        XCTAssertTrue(t.hasSuffix(".docx"), t)
        XCTAssertTrue(t.contains("\u{2026}"), t)
        XCTAssertTrue(t.hasPrefix("Quarterly"), t)
        let plain = ChatTabLayout.segmentTitle("A very long tab name with no extension at all")
        XCTAssertLessThanOrEqual(plain.count, ChatTabLayout.maxSegmentTitle)
        XCTAssertTrue(plain.contains("\u{2026}"))
    }

    func testMoreMenuShowsForOverflowOrTemporaryTab() {
        let tabs = (1...5).map { ChannelTab(id: "t\($0)", name: "Tab \($0)", appID: "3p") }
        let layout = ChatTabLayout(kind: .group, tabs: tabs)
        let opened = ChatTabKey.pinned("t5")
        XCTAssertTrue(layout.isOverflowPinned(opened))
        let folds = layout.folds(selected: opened, opened: opened)
        let none = ChatTabLayout.Fold(segments: layout.all, more: [])
        XCTAssertFalse(ChatTabLayout.showsMore(fold: none, temporary: nil))
        XCTAssertTrue(ChatTabLayout.showsMore(fold: none, temporary: opened), "Close reachable with nothing overflowing")
        XCTAssertTrue(ChatTabLayout.showsMore(fold: try! XCTUnwrap(folds.last), temporary: nil), "overflow shows More")
    }

    // MARK: (d) hosted folder breadcrumb is a native path control

    func testFolderCrumbsHostsANativePathControl() throws {
        let store = SharedFilesStore()
        let host = NSHostingView(rootView: FolderCrumbs(store: store, root: "Files"))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 60)
        host.layoutSubtreeIfNeeded()
        let paths = GuardSupport.subviews(of: host).compactMap { $0 as? NSPathControl }
        let path = try XCTUnwrap(paths.first, "FolderCrumbs must host an NSPathControl")
        XCTAssertEqual(path.pathStyle, .standard)
        XCTAssertEqual(path.pathItems.count, 1 + store.crumbs.count)
        XCTAssertEqual(path.pathItems.first?.title, "Files")
    }
}
