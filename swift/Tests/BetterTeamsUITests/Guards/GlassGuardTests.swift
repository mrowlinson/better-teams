// GlassGuardTests — GLASS lane: Liquid Glass lives in one place
// (Shared/Chrome.swift), every glass site goes through `Chrome`, content
// never wears glass, and Settings ▸ Appearance ▸ Glass-free swaps every
// site to the plain standard look live. Nothing here shows a window.
import AppKit
import XCTest

import OstMacCore
@testable import BetterTeamsUI

enum GlassScanner {
    static let chromeFile = "Shared/Chrome.swift"
    /// Content surfaces (path suffix, or prefix + suffix for a family).
    static let contentFiles: [(prefix: String, suffix: String)] = [
        ("Timeline/MessageRowView", ".swift"),
        ("Sections/Chat/ChatRow", ".swift"),
        ("Sections/Calendar/Calendar", "Grid.swift"),
        ("Sections/Files/FileTable", ".swift"),
        ("Sections/Activity/ActivityRows", ".swift"),
    ]
    static let glassPattern =
        #"glassEffect|GlassEffect|\.glassProminent\b|buttonStyle\(\s*\.glass\b|bezelStyle\s*=\s*\.glass\b|GlassButtonStyle"#
    static let chromeCallPattern = #"\bchromeBackground\(|\bchromeButtonStyle\(|\bchromeBar\(|\bChromeBackgroundView\b"#

    /// Code part of each line (comments dropped), with 1-based numbers.
    static func codeLines(_ source: String) -> [(Int, String)] {
        source.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element.components(separatedBy: "//").first ?? "") }
    }

    static func matches(_ pattern: String, in source: String, path: String) -> [String] {
        codeLines(source).compactMap { n, code in
            code.range(of: pattern, options: .regularExpression) != nil ? "\(path):\(n): \(code.trimmingCharacters(in: .whitespaces))" : nil
        }
    }

    static func isContent(_ path: String) -> Bool {
        contentFiles.contains { path.hasPrefix($0.prefix) && path.hasSuffix($0.suffix) }
    }
}

@MainActor
final class GlassGuardTests: XCTestCase {
    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BetterTeamsUI")
    }

    /// Every BetterTeamsUI source as (path relative to BetterTeamsUI, text).
    private func sources() throws -> [(String, String)] {
        let root = sourcesDir.standardizedFileURL.path + "/"
        let e = try XCTUnwrap(FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil))
        var out: [(String, String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path.replacingOccurrences(of: root, with: "")
            out.append((path, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 100, "scanned the whole UI target")
        return out
    }

    override func tearDown() {
        // A fresh in-memory store: later tests see the Glass default.
        MainActor.assumeIsolated { AppSettings.useDemoStorage() }
        super.tearDown()
    }

    // (a) Glass APIs appear only in Chrome.swift.
    func testGlassAPIsOnlyInChrome() throws {
        XCTAssertFalse(GlassScanner.matches(GlassScanner.glassPattern, in: "x.glassEffect(.regular, in: s)", path: "p").isEmpty,
                       "positive control: the lint sees glassEffect")
        XCTAssertFalse(GlassScanner.matches(GlassScanner.glassPattern, in: "b.buttonStyle(.glass)", path: "p").isEmpty)
        let all = try sources()
        let chrome = try XCTUnwrap(all.first { $0.0 == GlassScanner.chromeFile }?.1)
        XCTAssertFalse(GlassScanner.matches(GlassScanner.glassPattern, in: chrome, path: GlassScanner.chromeFile).isEmpty,
                       "control: Chrome.swift itself holds the glass")
        let hits = all.filter { $0.0 != GlassScanner.chromeFile }
            .flatMap { GlassScanner.matches(GlassScanner.glassPattern, in: $0.1, path: $0.0) }
        XCTAssertEqual(hits, [], "glass outside Shared/Chrome.swift")
    }

    // (b) Every ChromeSite is wired at a real site.
    func testEverySiteIsUsed() throws {
        let others = try sources().filter { $0.0 != GlassScanner.chromeFile }
        for site in ChromeSite.allCases {
            let pattern = #"[Cc]hrome.*\.\#(site.rawValue)\b|site:\s*\.\#(site.rawValue)\b"#
            let uses = others.flatMap { GlassScanner.matches(pattern, in: $0.1, path: $0.0) }
            XCTAssertFalse(uses.isEmpty, "ChromeSite.\(site) has no site outside Chrome.swift")
        }
    }

    // (c) Content never wears chrome.
    func testContentNeverCallsChrome() throws {
        let all = try sources()
        for family in GlassScanner.contentFiles {
            XCTAssertTrue(all.contains { $0.0.hasPrefix(family.prefix) && $0.0.hasSuffix(family.suffix) },
                          "content file moved: \(family.prefix)*\(family.suffix)")
        }
        let hits = all.filter { GlassScanner.isContent($0.0) }
            .flatMap { GlassScanner.matches(GlassScanner.chromeCallPattern, in: $0.1, path: $0.0) }
        XCTAssertEqual(hits, [], "content surfaces must not wear glass chrome")
        XCTAssertFalse(GlassScanner.matches(GlassScanner.chromeCallPattern, in: ".chromeBackground(.rail, in: s) {}", path: "p").isEmpty,
                       "positive control")
    }

    // (d) Per-site mapping and the mode matrix.
    func testLookAndModeMatrix() {
        for site in ChromeSite.allCases {
            XCTAssertEqual(Chrome.look(site, glass: true), .glass, "\(site)")
            XCTAssertNotEqual(Chrome.look(site, glass: false), .glass, "\(site)")
        }
        // Only Glass-free switches glass off (Reduce Transparency is the
        // system's own frosted glass, not a Glass-free switch).
        XCTAssertTrue(Chrome.usesGlass(glassFree: false))
        XCTAssertFalse(Chrome.usesGlass(glassFree: true))
    }

    // (e) Live toggle: rail, AppKit bar and toolbar items swap in place.
    func testGlassFreeSwapsLive() throws {
        AppSettings.useDemoStorage()
        let settings = AppSettings.shared
        XCTAssertFalse(settings.glassFree, "Glass by default")

        let rail = RailContainerViewController(rail: NSViewController())
        let railView = rail.view
        func count<T>(_ type: T.Type) -> Int { GuardSupport.subviews(of: railView).filter { $0 is T }.count }
        XCTAssertTrue(railView is NSVisualEffectView)
        XCTAssertEqual(count(NSGlassEffectView.self), 1, "glass pane on the rail")
        XCTAssertEqual(count(NSVisualEffectView.self), 1, "one material view")

        let bar = ImageViewerChrome.makeBar(content: NSView())
        XCTAssertTrue(bar.isGlass)
        XCTAssertTrue(bar.subviews.first is NSGlassEffectView)

        let wc = ShellWindowController(graph: AppState(args: ["--demo"]), options: LaunchOptions(args: ["--demo", "--evidence"]))
        let tc = try XCTUnwrap(wc.toolbarController)
        let items = ShellToolbarController.layout(CommandCatalog.toolbarCommands).order
            .compactMap { tc.toolbar(tc.toolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: true) }
            .filter { type(of: $0) == NSToolbarItem.self && $0.view == nil && $0.style != .prominent }
        XCTAssertFalse(items.isEmpty, "control: plain toolbar buttons exist")
        XCTAssertTrue(items.allSatisfy(\.isBordered), "glass: bordered toolbar buttons")

        settings.glassFree = true

        XCTAssertEqual(count(NSGlassEffectView.self), 0, "Glass-free: no glass on the rail")
        XCTAssertEqual(count(NSVisualEffectView.self), 1, "rail directly on its one material view")
        XCTAssertFalse(bar.isGlass)
        XCTAssertEqual((bar.subviews.first as? NSVisualEffectView)?.material, .popover)
        XCTAssertTrue(items.allSatisfy { !$0.isBordered }, "Glass-free: plain toolbar buttons")

        settings.glassFree = false
        XCTAssertEqual(count(NSGlassEffectView.self), 1, "back to glass")
        XCTAssertTrue(bar.isGlass)
        XCTAssertTrue(items.allSatisfy(\.isBordered))
        withExtendedLifetime((rail, wc)) {}
    }

    // (f) Glass-free persists under its key and is off by default.
    func testGlassFreePersists() {
        let defaults = MemoryDefaults()
        XCTAssertFalse(AppSettings(defaults: defaults).glassFree)
        let s = AppSettings(defaults: defaults)
        s.glassFree = true
        XCTAssertEqual(defaults.object(forKey: "bt.settings.glassFree") as? Bool, true)
        XCTAssertTrue(AppSettings(defaults: defaults).glassFree)
    }

    // Settings ▸ Appearance sits right after General.
    func testAppearancePaneFollowsGeneral() {
        let ids = SettingsWindowController.panes.map(\.id)
        XCTAssertEqual(Array(ids.prefix(2)), ["general", "appearance"])
        XCTAssertEqual(SettingsWindowController.panes[1].label, "Appearance")
    }
}
